//! Process-facing atlas peer configuration and receiver ownership. Pointer
//! forwarding is explicit opt-in; dynamic discovery is separate integration.
use crate::{atlas_runtime::AtlasReceiverPolicy, atlas_session::AtlasSessionPlan};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
};
use viewflow_protocol::Id128;
use viewflow_transport::{
    AlphaInterpretation, CodecDescriptor, CodedPixelFormat, Colorimetry, VideoCodec, VideoPlaneRole,
};

pub const USAGE: &str = "vf-media-peer receive --config <JSON>\nvf-media-peer send --config <JSON>\nWindows native receiver / Linux native-gpu-nvenc source; explicit paired TLS identity required. Receiver pointer forwarding is opt-in.";

#[cfg(any(windows, test))]
async fn drain_media_after_input(
    media: impl std::future::Future<Output = Result<()>>,
    input: Result<()>,
) -> Result<()> {
    // Media retirement closes the input queue before its child has finished
    // shutting down. Do not cancel that cleanup and erase its original error.
    match (
        tokio::time::timeout(std::time::Duration::from_secs(3), media).await,
        input,
    ) {
        (Ok(Err(media)), Err(input)) => Err(media.context(format!("atlas input ended: {input:#}"))),
        (Ok(Err(error)), Ok(())) | (Ok(Ok(())), Err(error)) => Err(error),
        (Ok(Ok(())), Ok(())) => Ok(()),
        (Err(timeout), input) => Err(anyhow::anyhow!(
            "atlas media cleanup wait expired: {timeout}; input result: {input:?}"
        )),
    }
}

/// Color coding negotiated by both peers. Alpha remains independently lossless.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AtlasColorCodec {
    #[default]
    H264,
    Av1,
}
impl AtlasColorCodec {
    pub(crate) fn wire(self) -> VideoCodec {
        match self {
            Self::H264 => VideoCodec::H264,
            Self::Av1 => VideoCodec::Av1,
        }
    }
}

/// Identical wire policy for source and receiver, independent of native paths.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasMediaPolicyConfig {
    #[serde(default)]
    pub color_codec: AtlasColorCodec,
    pub stream_id: String,
    pub geometry_epoch: u64,
    pub config_generation: u64,
    pub width: u32,
    pub height: u32,
    pub max_tiles: usize,
    pub max_encoded_bytes: usize,
    pub max_decoded_bytes: u64,
    pub refresh_hz: u32,
}

/// Explicit local authorization for a captured, fully decorated window.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasSourceWindow {
    pub window_id: String,
    pub address: String,
    pub width: u32,
    pub height: u32,
    pub geometry_epoch: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasSourceConfig {
    #[serde(default)]
    pub reverse: Option<crate::reverse_bridge::ReverseBridgeConfig>,
    #[serde(default)]
    pub desktop: Option<crate::desktop_config::AtlasSourceDesktopConfig>,
    #[serde(default)]
    pub pointer: Option<AtlasSourcePointerConfig>,
    #[serde(default)]
    pub capture_provider: AtlasCaptureProvider,
    #[serde(default)]
    pub disposition_recovery: bool,
    pub bind: SocketAddr,
    pub remote: SocketAddr,
    pub server_name: String,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub certificate_authority: PathBuf,
    pub compositor_pid: u32,
    pub fps: u32,
    pub startup_timeout_ms: u64,
    pub media_idle_timeout_ms: u64,
    pub media: AtlasMediaPolicyConfig,
    pub windows: Vec<AtlasSourceWindow>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasSourcePointerConfig {
    /// Exact native owned remote-output ID. Omission disables cursor capture.
    #[serde(default)]
    pub cursor_monitor_id: Option<i64>,
    pub devices: AtlasPointerConfig,
    pub native_socket: PathBuf,
    /// Explicit local wheel authority. Old pointer configurations stay buttons-only.
    #[serde(default)]
    pub wheel: bool,
    /// Explicit direct-application keyboard authority; active source IME grabs
    /// remain unsupported. Requires the full wheel/button native capability.
    #[serde(default)]
    pub direct_keyboard: bool,
}

fn validate_input_capabilities(wheel: bool, direct_keyboard: bool) -> Result<()> {
    ensure!(
        !direct_keyboard || wheel,
        "direct keyboard requires wheel capability"
    );
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AtlasCaptureProvider {
    #[default]
    Viewflow,
    Hyprcapture,
}

impl AtlasSourceConfig {
    /// # Errors
    /// Rejects invalid configuration before starting capture or networking.
    pub fn load(path: &Path) -> Result<Self> {
        let config: Self = serde_json::from_slice(&read_bounded(path, 64 * 1024)?)
            .context("parse atlas source config")?;
        config.layout()?;
        Ok(config)
    }

    /// # Errors
    /// Validates authorized membership and deterministically packs capture pixels.
    pub fn layout(&self) -> Result<viewflow_core::AtlasSnapshot> {
        if let Some(reverse) = &self.reverse { reverse.validate()?; }
        use std::collections::BTreeSet;
        use viewflow_core::{AtlasConfig, StableAtlas};
        if let Some(pointer) = &self.pointer {
            pointer.devices.devices()?;
            validate_input_capabilities(pointer.wheel, pointer.direct_keyboard)?;
            if let Some(monitor_id) = pointer.cursor_monitor_id {
                ensure!(
                    monitor_id >= 0,
                    "cursor monitor ID must identify an owned native output"
                );
                ensure!(
                    self.desktop.is_some(),
                    "cursor handoff requires global desktop configuration"
                );
            }

            ensure!(
                self.disposition_recovery,
                "atlas source pointer requires disposition recovery"
            );
            ensure!(
                pointer.native_socket.is_absolute()
                    && pointer.native_socket.as_os_str().len() < 108,
                "invalid atlas native pointer socket path"
            );
        }
        let plan = self.media.plan()?;
        if let Some(desktop) = &self.desktop {
            desktop.validate(plan.policy.max_tiles)?;
            let pointer = self
                .pointer
                .as_ref()
                .context("desktop dragging requires source input")?;
            ensure!(
                self.disposition_recovery && pointer.wheel && pointer.direct_keyboard,
                "desktop dragging requires dispositions, wheel and direct keyboard"
            );
        }
        ensure!(self.compositor_pid > 0, "invalid compositor PID");
        ensure!((1..=1000).contains(&self.fps), "invalid capture frame rate");
        ensure!(
            self.remote.port() != 0
                && !self.remote.ip().is_unspecified()
                && !self.remote.ip().is_multicast(),
            "invalid remote atlas endpoint"
        );
        ensure!(
            !self.server_name.is_empty()
                && self.server_name.len() <= 253
                && self
                    .server_name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'),
            "invalid atlas TLS server name"
        );
        for timeout in [self.startup_timeout_ms, self.media_idle_timeout_ms] {
            ensure!(
                (1..=30_000).contains(&timeout),
                "atlas operation timeout out of range"
            );
        }
        for path in [
            &self.certificate,
            &self.private_key,
            &self.certificate_authority,
        ] {
            ensure!(path.is_absolute(), "atlas identity paths must be absolute");
        }
        ensure!(
            (!self.windows.is_empty() || self.desktop.as_ref().is_some_and(|desktop| desktop.auto_enroll)) && self.windows.len() <= self.media.max_tiles,
            "invalid atlas source membership count"
        );
        let mut ids = BTreeSet::new();
        let mut addresses = BTreeSet::new();
        let mut windows = Vec::new();
        for window in &self.windows {
            ensure!(
                window.window_id.len() == 32
                    && window
                        .window_id
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "window ID must be 32 lowercase hex digits"
            );
            let id = Id128(u128::from_str_radix(&window.window_id, 16)?);
            ensure!(
                id.0 != 0 && id != plan.policy.stream_id && ids.insert(id),
                "duplicate, zero or stream-alias window ID"
            );
            let address = window
                .address
                .strip_prefix("0x")
                .context("window address needs 0x prefix")?;
            ensure!(
                !address.is_empty()
                    && address.len() <= 16
                    && address.bytes().all(|b| b.is_ascii_hexdigit()),
                "invalid window address"
            );
            let address = u64::from_str_radix(address, 16)?;
            ensure!(
                address != 0 && addresses.insert(address),
                "duplicate or zero window address"
            );
            ensure!(window.geometry_epoch != 0, "invalid capture geometry epoch");
            windows.push((id, window));
        }
        windows.sort_by_key(|(id, _)| *id);
        let mut atlas = StableAtlas::new(AtlasConfig {
            width: self.media.width,
            height: self.media.height,
            alignment: 2,
            max_windows: self.media.max_tiles,
        })
        .map_err(|e| anyhow::anyhow!("invalid source atlas: {e:?}"))?;
        for (id, window) in windows {
            atlas
                .place(id, window.geometry_epoch, window.width, window.height)
                .map_err(|e| anyhow::anyhow!("source window does not fit atlas: {e:?}"))?;
        }
        Ok(atlas.snapshot())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasPointerConfig {
    pub owner_device: String,
    pub source_device: String,
}

impl AtlasPointerConfig {
    /// Paired receiver/source IDs, shared by both endpoints' configuration.
    /// # Errors
    /// IDs must be distinct, nonzero 128-bit hexadecimal values.
    pub fn devices(&self) -> Result<(viewflow_protocol::Id128, viewflow_protocol::Id128)> {
        let parse = |text: &str| -> Result<viewflow_protocol::Id128> {
            ensure!(
                text.len() == 32 && text.bytes().all(|b| b.is_ascii_hexdigit()),
                "invalid atlas pointer device ID"
            );
            let id = viewflow_protocol::Id128(u128::from_str_radix(text, 16)?);
            ensure!(id.0 != 0, "empty atlas pointer device ID");
            Ok(id)
        };
        let owner = parse(&self.owner_device)?;
        let source = parse(&self.source_device)?;
        ensure!(owner != source, "atlas pointer device IDs must differ");
        Ok((owner, source))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasReceiverPointerConfig {
    pub owner_device: String,
    pub source_device: String,
    #[serde(default)]
    pub wheel: bool,
    #[serde(default)]
    pub direct_keyboard: bool,
}

impl AtlasReceiverPointerConfig {
    /// # Errors
    /// Requires distinct, nonzero paired device IDs.
    pub fn devices(&self) -> Result<(viewflow_protocol::Id128, viewflow_protocol::Id128)> {
        AtlasPointerConfig {
            owner_device: self.owner_device.clone(),
            source_device: self.source_device.clone(),
        }
        .devices()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasReceiverConfig {
    #[serde(default)]
    pub reverse: Option<crate::reverse_bridge::ReverseBridgeConfig>,
    #[serde(default)]
    pub color_codec: AtlasColorCodec,
    #[serde(default)]
    pub desktop: Option<crate::desktop_config::AtlasReceiverDesktopConfig>,
    #[serde(default)]
    pub pointer: Option<AtlasReceiverPointerConfig>,
    #[serde(default)]
    pub disposition_recovery: bool,
    /// Enables the separately negotiated native cancellation/drain recovery
    /// route. This is deliberately off by default: normal direct keyboard
    /// input continues to use the established pointer child and never accepts
    /// recovery notices.
    #[serde(default)]
    pub input_recovery: bool,
    pub bind: SocketAddr,
    pub expected_peer_ip: IpAddr,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub certificate_authority: PathBuf,
    pub native_presenter: PathBuf,
    pub stream_id: String,
    pub geometry_epoch: u64,
    pub config_generation: u64,
    pub width: u32,
    pub height: u32,
    pub max_tiles: usize,
    pub max_encoded_bytes: usize,
    pub max_decoded_bytes: u64,
    pub refresh_hz: u32,
    pub startup_timeout_ms: u64,
    pub media_idle_timeout_ms: u64,
    pub clock_silence_timeout_ms: u64,
}

impl AtlasReceiverConfig {
    /// # Errors
    /// All policy is local and explicit; unknown keys and invalid bounds fail
    /// before opening a socket or launching a native process.
    pub fn load(path: &Path) -> Result<Self> {
        let bytes = read_bounded(path, 64 * 1024)?;
        let config: Self = serde_json::from_slice(&bytes).context("parse atlas receiver config")?;
        config.plan()?;
        Ok(config)
    }

    /// # Errors
    /// Establishes exactly two refresh periods as the live media age limit.
    pub fn plan(&self) -> Result<AtlasSessionPlan> {
        if let Some(reverse) = &self.reverse { reverse.validate()?; }
        ensure!(
            self.color_codec == AtlasColorCodec::H264 || self.desktop.is_some(),
            "AV1 native presentation currently requires desktop mode"
        );
        if let Some(desktop) = self.desktop {
            desktop.validate()?;
            ensure!(
                self.input_recovery,
                "desktop dragging requires input recovery capability"
            );
        }
        if let Some(pointer) = &self.pointer {
            pointer.devices()?;
            validate_input_capabilities(pointer.wheel, pointer.direct_keyboard)?;
            ensure!(
                self.disposition_recovery,
                "atlas pointer input requires disposition recovery"
            );
        }
        if self.input_recovery {
            let pointer = self
                .pointer
                .as_ref()
                .context("atlas input recovery requires pointer input")?;
            ensure!(
                self.disposition_recovery && pointer.wheel && pointer.direct_keyboard,
                "atlas input recovery requires dispositions, wheel and direct keyboard"
            );
        }
        for timeout in [
            self.startup_timeout_ms,
            self.media_idle_timeout_ms,
            self.clock_silence_timeout_ms,
        ] {
            ensure!(
                (1..=30_000).contains(&timeout),
                "atlas operation timeout out of range"
            );
        }
        ensure!(
            !self.expected_peer_ip.is_unspecified() && !self.expected_peer_ip.is_multicast(),
            "invalid expected atlas peer IP"
        );
        for path in [
            &self.certificate,
            &self.private_key,
            &self.certificate_authority,
            &self.native_presenter,
        ] {
            ensure!(
                path.is_absolute(),
                "atlas identity/presenter paths must be absolute"
            );
        }
        self.media_policy().plan()
    }

    #[must_use]
    pub fn media_policy(&self) -> AtlasMediaPolicyConfig {
        AtlasMediaPolicyConfig {
            color_codec: self.color_codec,
            stream_id: self.stream_id.clone(),
            geometry_epoch: self.geometry_epoch,
            config_generation: self.config_generation,
            width: self.width,
            height: self.height,
            max_tiles: self.max_tiles,
            max_encoded_bytes: self.max_encoded_bytes,
            max_decoded_bytes: self.max_decoded_bytes,
            refresh_hz: self.refresh_hz,
        }
    }
}

impl AtlasMediaPolicyConfig {
    /// # Errors
    /// Rejects invalid identities, descriptors and resource bounds before I/O.
    pub fn plan(&self) -> Result<AtlasSessionPlan> {
        ensure!(
            self.stream_id.len() == 32
                && self
                    .stream_id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "atlas stream ID must be 32 lowercase hex digits"
        );
        ensure!(
            (1..=1000).contains(&self.refresh_hz),
            "invalid atlas refresh rate"
        );
        let color = CodecDescriptor {
            codec: self.color_codec.wire(),
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            coded_width: self.width,
            coded_height: self.height,
            geometry_epoch: self.geometry_epoch,
            config_generation: self.config_generation,
        };
        let plan = AtlasSessionPlan {
            policy: AtlasReceiverPolicy {
                stream_id: Id128(u128::from_str_radix(&self.stream_id, 16)?),
                geometry_epoch: self.geometry_epoch,
                config_generation: self.config_generation,
                width: self.width,
                height: self.height,
                max_tiles: self.max_tiles,
                max_encoded_bytes: self.max_encoded_bytes,
                max_age_ns: 2_000_000_000 / u64::from(self.refresh_hz),
                max_future_ns: 0,
            },
            color,
            alpha: CodecDescriptor {
                codec: VideoCodec::LosslessAlpha,
                plane: VideoPlaneRole::Alpha,
                pixel_format: CodedPixelFormat::Gray8,
                colorimetry: Colorimetry::AlphaFullRange,
                alpha_interpretation: AlphaInterpretation::AlphaPlane,
                ..color
            },
            max_decoded_bytes: self.max_decoded_bytes,
        };
        plan.validate()?;
        crate::atlas_receiver_presenter::native_record_limit(plan)?;
        Ok(plan)
    }
}

pub(crate) fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>> {
    use std::io::Read;
    let file = std::fs::File::open(path).context("open atlas configuration/identity file")?;
    ensure!(
        file.metadata()?.is_file(),
        "atlas configuration/identity must be a regular file"
    );
    let mut bytes = Vec::new();
    file.take(u64::try_from(limit)? + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= limit,
        "atlas configuration/identity file too large"
    );
    Ok(bytes)
}

#[cfg(windows)]
mod receiver {
    use super::*;
    use crate::{
        atlas_clock::AtlasClockServer,
        atlas_receiver_presenter::{
            AtlasInputRecoveryFence, AtlasInputRecoveryRequest, AtlasReceiverDesktopInput,
            AtlasReceiverInput, AtlasReceiverPresenter, AtlasReceiverRecoveryInput,
            native_record_limit,
        },
    };
    use std::{future::Future, time::Duration};
    use tokio::{
        sync::mpsc,
        time::{Instant, timeout_at},
    };

    /// The same session-local clock feeds clock replies and media admission.
    /// Native QPC deadlines are derived independently from remaining duration.
    #[derive(Clone, Copy)]
    struct Clock(Instant);
    impl Clock {
        fn now(self) -> u64 {
            u64::try_from(self.0.elapsed().as_nanos()).unwrap_or(u64::MAX)
        }
    }

    struct ClockWorker(tokio::task::JoinHandle<Result<()>>);
    impl Drop for ClockWorker {
        fn drop(&mut self) {
            self.0.abort();
        }
    }

    enum ReceiverInput {
        Normal(AtlasReceiverInput),
        Recovery(AtlasReceiverRecoveryInput),
        Desktop(AtlasReceiverDesktopInput),
    }

    pub async fn run(config: AtlasReceiverConfig, stop: impl Future<Output = ()>) -> Result<()> {
        let _timer_resolution = crate::coded_peer::enable_windows_timer_resolution()?;
        let plan = config.plan()?;
        let identity = viewflow_transport::PeerIdentity::from_pem(
            &read_bounded(&config.certificate, 1 << 20)?,
            &read_bounded(&config.private_key, 1 << 20)?,
            &read_bounded(&config.certificate_authority, 1 << 20)?,
        )
        .map_err(|error| anyhow::anyhow!("parse paired atlas TLS identity: {error}"))?;
        let tls = viewflow_transport::build_server_config(&identity)
            .map_err(|error| anyhow::anyhow!("atlas server TLS configuration: {error}"))?;
        let socket = std::net::UdpSocket::bind(config.bind)?;
        let socket_ref = socket2::SockRef::from(&socket);
        let before_receive = socket_ref.recv_buffer_size()?;
        // Match the established native media receiver's bounded burst buffer.
        // The Windows default can be smaller than one fragmented alpha plane.
        socket_ref.set_recv_buffer_size(4 * 1024 * 1024)?;
        let after_receive = socket_ref.recv_buffer_size()?;
        let endpoint = quinn::Endpoint::new(
            Default::default(),
            Some(tls),
            socket,
            std::sync::Arc::new(quinn::TokioRuntime),
        )?;
        eprintln!(
            "atlas-peer-listening address={} input_enabled={}",
            endpoint.local_addr()?,
            config.pointer.is_some()
        );
        eprintln!(
            "atlas-receiver-udp-buffer before_bytes={before_receive} after_bytes={after_receive}"
        );
        let work = async {
            let incoming = endpoint.accept().await.context("atlas listener closed")?;
            let deadline = Instant::now() + Duration::from_millis(config.startup_timeout_ms);
            let connection = timeout_at(deadline, incoming).await??;
            if connection.remote_address().ip() != config.expected_peer_ip {
                connection.close(0_u32.into(), b"unexpected atlas peer");
                anyhow::bail!("authenticated atlas peer IP differs from local configuration");
            }
            run_connection(&config, plan, connection, deadline).await
        };
        tokio::pin!(work);
        tokio::pin!(stop);
        let result = tokio::select! {
            result = &mut work => result,
            () = &mut stop => {
                endpoint.close(0_u32.into(), b"local atlas receiver stop");
                // Do not drop an admitted handoff or a child startup. Its
                // original deadlines and explicit shutdown remain in force.
                work.await
            }
        };
        endpoint.close(0_u32.into(), b"atlas receiver retired");
        result
    }

    async fn run_connection(
        config: &AtlasReceiverConfig,
        plan: AtlasSessionPlan,
        connection: quinn::Connection,
        deadline: Instant,
    ) -> Result<()> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let clock = Clock(Instant::now());
        let mut clock_server = AtlasClockServer::accept(&connection, deadline).await?;
        clock_server.respond(|| Ok(clock.now()), deadline).await?;
        let silence = Duration::from_millis(config.clock_silence_timeout_ms);
        let mut clock_task = ClockWorker(tokio::spawn(async move {
            loop {
                clock_server
                    .respond(|| Ok(clock.now()), Instant::now() + silence)
                    .await?;
            }
            #[allow(unreachable_code)]
            Ok::<(), anyhow::Error>(())
        }));
        let work = async {
            let (mut owner, input) = if let Some(desktop) = config.desktop {
                let (owner, input) = AtlasReceiverPresenter::accept_warmed_desktop(
                    &connection,
                    plan,
                    &config.native_presenter,
                    desktop,
                    deadline,
                )
                .await?;
                (owner, Some(ReceiverInput::Desktop(input)))
            } else if config.input_recovery {
                let (owner, input) = AtlasReceiverPresenter::accept_warmed_input_recovery(
                    &connection,
                    plan,
                    &config.native_presenter,
                    deadline,
                )
                .await?;
                (owner, Some(ReceiverInput::Recovery(input)))
            } else if let Some(pointer) = &config.pointer {
                let (owner, input) = AtlasReceiverPresenter::accept_warmed_input_capabilities(
                    &connection, plan, &config.native_presenter, deadline, pointer.wheel, pointer.direct_keyboard).await?;
                (owner, Some(ReceiverInput::Normal(input)))
            } else if config.disposition_recovery {
                (
                AtlasReceiverPresenter::accept_warmed_dispositions(
                    &connection,
                    plan,
                    &config.native_presenter,
                    deadline,
                )
                .await?, None)
            } else {
                (AtlasReceiverPresenter::accept_warmed(
                    &connection,
                    plan,
                    &config.native_presenter,
                    deadline,
                )
                .await?, None)
            };
            eprintln!(
                "atlas-peer-ready input_enabled={} input_recovery={} physical_present_receipt=false",
                input.is_some(),
                config.input_recovery
            );
            let _reverse = config.reverse.as_ref()
                .map(|reverse| crate::reverse_bridge::ReverseBridge::start(&connection, reverse, true, None))
                .transpose()?;
            let reception = async {
                if let Some(input) = input {
                    let pointer = config.pointer.as_ref().context("atlas pointer config missing")?;
                    let (device, source) = pointer.devices()?;
                    let writer = crate::shared_control::SharedControlWriter::start(&connection)?;
                    match input {
                        ReceiverInput::Normal(input) => {
                            let preview = crate::atlas_preview_input::AtlasPreviewInput::new(
                                device, source, std::time::Instant::now(), input.native, input.committed,
                                || { let sample = crate::atlas_receiver_presenter::QpcSample::current()?; Ok((sample.ticks, sample.frequency)) })?.with_wheel(pointer.wheel);
                            let preview = if pointer.direct_keyboard { preview.with_direct_keyboard() } else { preview };
                            let receive = receive(
                                &mut owner,
                                clock,
                                plan,
                                Duration::from_millis(config.media_idle_timeout_ms),
                                config.disposition_recovery,
                            );
                            tokio::pin!(receive);
                            tokio::select! {
                                result = &mut receive => result,
                                result = preview.serve(&connection, input.controls, writer.sender(), deadline) => drain_media_after_input(&mut receive, result).await,
                            }
                        }
                        ReceiverInput::Recovery(input) => {
                            let (requests, request_receiver) = mpsc::channel(64);
                            let preview = crate::atlas_preview_input::AtlasPreviewInput::new(
                                device, source, std::time::Instant::now(), input.input.native, input.input.committed,
                                || { let sample = crate::atlas_receiver_presenter::QpcSample::current()?; Ok((sample.ticks, sample.frequency)) })?
                                .with_direct_keyboard()
                                .with_input_recovery(input.notices, requests, input.fence.clone())?;
                            let receive = receive_with_input_recovery(
                                &mut owner,
                                clock,
                                plan,
                                Duration::from_millis(config.media_idle_timeout_ms),
                                input.fence,
                                request_receiver,
                            );
                            tokio::pin!(receive);
                            tokio::select! {
                                result = &mut receive => result,
                                result = preview.serve(&connection, input.input.controls, writer.sender(), deadline) => drain_media_after_input(&mut receive, result).await,
                            }
                        }
                        ReceiverInput::Desktop(input) => {
                            let (requests, request_receiver) = mpsc::channel(64);
                            let preview = crate::atlas_preview_input::AtlasPreviewInput::new(
                                device, source, std::time::Instant::now(), input.input.native, input.input.committed,
                                || { let sample = crate::atlas_receiver_presenter::QpcSample::current()?; Ok((sample.ticks, sample.frequency)) })?
                                .with_direct_keyboard()
                                .with_input_recovery(input.notices, requests, input.fence.clone())?
                                .with_desktop_moves(input.moves)?
                                .with_desktop_cursor(config.desktop.context("desktop input requires display config")?)?;
                            let receive = receive_with_input_recovery(
                                &mut owner,
                                clock,
                                plan,
                                Duration::from_millis(config.media_idle_timeout_ms),
                                input.fence,
                                request_receiver,
                            );
                            tokio::pin!(receive);
                            tokio::select! {
                                result = &mut receive => result,
                                result = preview.serve(&connection, input.input.controls, writer.sender(), deadline) => drain_media_after_input(&mut receive, result).await,
                            }
                        }
                    }
                } else {
                    receive(
                        &mut owner,
                        clock,
                        plan,
                        Duration::from_millis(config.media_idle_timeout_ms),
                        config.disposition_recovery,
                    )
                    .await
                }
            }.await;
            let cleanup = owner.shutdown().await;
            match cleanup {
                Ok(()) => {
                    eprintln!("atlas-peer-retirement-finished");
                    reception
                }
                Err(error) => Err(anyhow::anyhow!(
                    "atlas receiver cleanup failed: {error:#}; media result: {reception:?}"
                )),
            }
        }
        .await;
        connection.close(0_u32.into(), b"atlas receiver attempt ended");
        let clock_result = (&mut clock_task.0)
            .await
            .context("atlas clock worker join failed")?;
        guard.0 = None;
        // The worker normally observes our connection close. Preserve the media
        // cause; a worker error never turns a failed attempt into success.
        match (work, clock_result) {
            (Err(media), Err(clock)) => {
                Err(media.context(format!("atlas clock worker ended: {clock:#}")))
            }
            (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    async fn receive(
        owner: &mut AtlasReceiverPresenter,
        clock: Clock,
        plan: AtlasSessionPlan,
        idle: Duration,
        dispositions: bool,
    ) -> Result<()> {
        let max_record = native_record_limit(plan)?;
        let mut submitted = 0_u64;
        let mut expired = 0_u64;
        loop {
            let result = if dispositions {
                owner
                    .forward_next_disposition_with_clock(
                        || clock.now(),
                        crate::atlas_receiver_presenter::QpcSample::current,
                        Instant::now() + idle,
                        max_record,
                    )
                    .await
            } else {
                owner
                    .forward_next(|| clock.now(), Instant::now() + idle, max_record)
                    .await
                    .map(|_| crate::atlas_feedback::AtlasFrameDisposition::Committed)
            };
            match result {
                Ok(crate::atlas_feedback::AtlasFrameDisposition::Committed) => submitted = submitted.saturating_add(1),
                Ok(crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound) => expired = expired.saturating_add(1),
                Err(error) if error.is::<crate::atlas_session::AtlasWaitExpired>() => continue,
                Err(error) => return Err(error.context(format!(
                    "atlas receiver stopped after {submitted} native visual submissions (not physical receipts), expired_unbound={expired}"
                ))),
            }
        }
    }

    /// The recovery request sender is deliberately not selected against an
    /// in-flight `forward_next_disposition_with_clock`: that future owns the
    /// native child after admission and must finish its original handoff.  The
    /// local fence is observed between forwards, at which point this same
    /// media owner serially performs the native END/BEGIN transaction.
    async fn receive_with_input_recovery(
        owner: &mut AtlasReceiverPresenter,
        clock: Clock,
        plan: AtlasSessionPlan,
        idle: Duration,
        fence: AtlasInputRecoveryFence,
        mut requests: mpsc::Receiver<AtlasInputRecoveryRequest>,
    ) -> Result<()> {
        let max_record = native_record_limit(plan)?;
        let mut submitted = 0_u64;
        let mut expired = 0_u64;
        loop {
            if fence.is_armed() {
                let Some(request) = owner
                    .wait_input_recovery_request(&mut requests, Instant::now() + idle)
                    .await?
                else {
                    continue;
                };
                owner
                    .handle_input_recovery_with_clock(request, || {
                        let sample = crate::atlas_receiver_presenter::QpcSample::current()?;
                        Ok((sample.ticks, sample.frequency))
                    })
                    .await?;
                continue;
            }
            match requests.try_recv() {
                Ok(request) => {
                    ensure!(
                        fence.is_armed(),
                        "atlas recovery request arrived before its media fence"
                    );
                    owner
                        .handle_input_recovery_with_clock(request, || {
                            let sample = crate::atlas_receiver_presenter::QpcSample::current()?;
                            Ok((sample.ticks, sample.frequency))
                        })
                        .await?;
                    continue;
                }
                Err(mpsc::error::TryRecvError::Empty) => {}
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    anyhow::bail!("atlas recovery input supervisor ended")
                }
            }
            // Do not put this future in `select!`: after it has admitted a
            // frame it is the only owner of the child pipe. A notice that arms
            // the fence during this await is served at the top of the next
            // iteration, after this handoff has completed.
            let result = owner
                .forward_next_disposition_with_clock(
                    || clock.now(),
                    crate::atlas_receiver_presenter::QpcSample::current,
                    Instant::now() + idle,
                    max_record,
                )
                .await;
            match result {
                Ok(crate::atlas_feedback::AtlasFrameDisposition::Committed) => {
                    submitted = submitted.saturating_add(1);
                }
                Ok(crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound) => {
                    expired = expired.saturating_add(1);
                }
                Err(error) if error.is::<crate::atlas_receiver_presenter::AtlasMediaFenced>() => {
                    // The fence won before frame admission; no child or
                    // transport state was consumed. Serve its request above.
                    continue;
                }
                Err(error) if error.is::<crate::atlas_session::AtlasWaitExpired>() => continue,
                Err(error) => {
                    return Err(error.context(format!(
                        "atlas recovery receiver stopped after {submitted} native visual submissions (not physical receipts), expired_unbound={expired}"
                    )));
                }
            }
        }
    }
}

/// Run on a Windows desktop session with native Composition access. One process
/// owns one peer attempt, clock worker and native presenter; input is disabled.
/// # Errors
/// Retains terminal media and cleanup errors even during requested shutdown.
#[cfg(windows)]
pub async fn run_receiver_until(
    config: AtlasReceiverConfig,
    stop: impl std::future::Future<Output = ()>,
) -> Result<()> {
    receiver::run(config, stop).await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn av1_policy_keeps_lossless_alpha_and_explicit_wire_identity() {
        let mut policy = config().media_policy();
        policy.color_codec = AtlasColorCodec::Av1;
        let encoded = serde_json::to_vec(&policy).unwrap();
        let decoded: AtlasMediaPolicyConfig = serde_json::from_slice(&encoded).unwrap();
        let plan = decoded.plan().unwrap();
        assert_eq!(plan.color.codec, VideoCodec::Av1);
        assert_eq!(plan.alpha.codec, VideoCodec::LosslessAlpha);
        assert_eq!(plan.color.coded_width, plan.alpha.coded_width);
        assert_eq!(config().plan().unwrap().color.codec, VideoCodec::H264);
    }

    fn config() -> AtlasReceiverConfig {
        let root = std::env::temp_dir();
        AtlasReceiverConfig {
            reverse: None,
            color_codec: Default::default(),
            desktop: None,
            pointer: None,
            disposition_recovery: false,
            input_recovery: false,
            bind: "127.0.0.1:0".parse().unwrap(),
            expected_peer_ip: "127.0.0.1".parse().unwrap(),
            certificate: root.join("atlas-test.pem"),
            private_key: root.join("atlas-test.key"),
            certificate_authority: root.join("atlas-ca.pem"),
            native_presenter: root.join("atlas-presenter.exe"),
            stream_id: format!("{:032x}", 99),
            geometry_epoch: 1,
            config_generation: 1,
            width: 64,
            height: 64,
            max_tiles: 4,
            max_encoded_bytes: 1024,
            max_decoded_bytes: 32768,
            refresh_hz: 60,
            startup_timeout_ms: 2000,
            media_idle_timeout_ms: 2000,
            clock_silence_timeout_ms: 2000,
        }
    }

    #[test]
    fn pointer_config_requires_paired_ids_and_dispositions() {
        let mut receiver = config();
        receiver.pointer = Some(AtlasReceiverPointerConfig {
            owner_device: format!("{:032x}", 1),
            source_device: format!("{:032x}", 2),
            wheel: false,
            direct_keyboard: false,
        });
        assert!(receiver.plan().is_err());
        receiver.disposition_recovery = true;
        assert!(receiver.plan().is_ok());
        receiver.pointer.as_mut().unwrap().direct_keyboard = true;
        assert!(receiver.plan().is_err());
        receiver.pointer.as_mut().unwrap().wheel = true;
        assert!(receiver.plan().is_ok());
        receiver.pointer.as_mut().unwrap().direct_keyboard = false;
        receiver.pointer.as_mut().unwrap().wheel = false;
        let mut json = serde_json::to_value(&receiver).unwrap();
        json["pointer"].as_object_mut().unwrap().remove("wheel");
        json["pointer"]
            .as_object_mut()
            .unwrap()
            .remove("direct_keyboard");
        assert!(
            !serde_json::from_value::<AtlasReceiverConfig>(json.clone())
                .unwrap()
                .pointer
                .unwrap()
                .direct_keyboard
        );
        assert!(
            !serde_json::from_value::<AtlasReceiverConfig>(json.clone())
                .unwrap()
                .pointer
                .unwrap()
                .wheel
        );
        json["pointer"]["wheel"] = serde_json::json!(true);
        let enabled = serde_json::from_value::<AtlasReceiverConfig>(json.clone()).unwrap();
        assert!(enabled.pointer.as_ref().unwrap().wheel);
        assert!(enabled.plan().is_ok());
        json["pointer"]["wheel"] = serde_json::json!("true");
        assert!(serde_json::from_value::<AtlasReceiverConfig>(json).is_err());
        for invalid in [
            "0".repeat(32),
            "1".to_owned(),
            "g".repeat(32),
            format!("{:032x}", 1),
        ] {
            receiver.pointer.as_mut().unwrap().source_device = invalid;
            assert!(receiver.plan().is_err());
        }
    }

    #[test]
    fn input_recovery_is_default_off_and_requires_the_exact_keyboard_route() {
        let original = serde_json::to_value(config()).unwrap();
        assert!(
            !serde_json::from_value::<AtlasReceiverConfig>(original.clone())
                .unwrap()
                .input_recovery
        );

        let mut receiver = config();
        receiver.input_recovery = true;
        assert!(receiver.plan().is_err());
        receiver.pointer = Some(AtlasReceiverPointerConfig {
            owner_device: format!("{:032x}", 1),
            source_device: format!("{:032x}", 2),
            wheel: false,
            direct_keyboard: false,
        });
        receiver.disposition_recovery = true;
        assert!(receiver.plan().is_err());
        receiver.pointer.as_mut().unwrap().wheel = true;
        assert!(receiver.plan().is_err());
        receiver.pointer.as_mut().unwrap().direct_keyboard = true;
        assert!(receiver.plan().is_ok());

        let mut unknown = original;
        unknown["input_recovery"] = serde_json::json!("true");
        assert!(serde_json::from_value::<AtlasReceiverConfig>(unknown).is_err());
    }

    #[tokio::test]
    async fn input_queue_closure_does_not_erase_pending_media_cleanup_error() {
        let cleaned = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observed = cleaned.clone();
        let media = async move {
            tokio::task::yield_now().await;
            cleaned.store(true, std::sync::atomic::Ordering::SeqCst);
            anyhow::bail!("original native disposition failure");
        };
        let error = drain_media_after_input(
            media,
            Err(anyhow::anyhow!("input control owner disappeared")),
        )
        .await
        .unwrap_err();
        assert!(observed.load(std::sync::atomic::Ordering::SeqCst));
        let chain = format!("{error:#}");
        assert!(chain.contains("original native disposition failure"));
        assert!(chain.contains("input control owner disappeared"));
    }

    #[test]
    fn source_layout_rejects_aliases_and_is_order_independent() {
        let receiver = config();
        let mut source = AtlasSourceConfig {
            reverse: None,
            desktop: None,
            pointer: None,
            capture_provider: AtlasCaptureProvider::Viewflow,
            disposition_recovery: false,
            bind: receiver.bind,
            remote: "127.0.0.1:9000".parse().unwrap(),
            server_name: "receiver.local".into(),
            certificate: receiver.certificate.clone(),
            private_key: receiver.private_key.clone(),
            certificate_authority: receiver.certificate_authority.clone(),
            compositor_pid: 1,
            fps: 60,
            startup_timeout_ms: 2000,
            media_idle_timeout_ms: 2000,
            media: receiver.media_policy(),
            windows: (1..=2)
                .map(|id| AtlasSourceWindow {
                    window_id: format!("{id:032x}"),
                    address: format!("0x{id:x}"),
                    width: 32,
                    height: 32,
                    geometry_epoch: 1,
                })
                .collect(),
        };
        let layout = source.layout().unwrap();
        source.pointer = Some(AtlasSourcePointerConfig {
            cursor_monitor_id: None,
            devices: AtlasPointerConfig {
                owner_device: format!("{:032x}", 10),
                source_device: format!("{:032x}", 11),
            },
            native_socket: std::env::temp_dir().join("atlas-input.sock"),
            wheel: false,
            direct_keyboard: false,
        });
        assert!(source.layout().is_err());
        source.disposition_recovery = true;
        assert_eq!(source.layout().unwrap(), layout);
        source.pointer.as_mut().unwrap().direct_keyboard = true;
        assert!(source.layout().is_err());
        source.pointer.as_mut().unwrap().wheel = true;
        assert!(source.layout().is_ok());
        source.pointer.as_mut().unwrap().direct_keyboard = false;
        source.pointer.as_mut().unwrap().wheel = false;
        let serialized = serde_json::to_vec(&source).unwrap();
        let mut old = serde_json::to_value(&source).unwrap();
        old["pointer"].as_object_mut().unwrap().remove("wheel");
        old["pointer"]
            .as_object_mut()
            .unwrap()
            .remove("direct_keyboard");
        assert!(
            !serde_json::from_value::<AtlasSourceConfig>(old.clone())
                .unwrap()
                .pointer
                .unwrap()
                .direct_keyboard
        );
        assert!(
            !serde_json::from_value::<AtlasSourceConfig>(old.clone())
                .unwrap()
                .pointer
                .unwrap()
                .wheel
        );
        old["pointer"]["wheel"] = serde_json::json!(true);
        assert!(
            serde_json::from_value::<AtlasSourceConfig>(old.clone())
                .unwrap()
                .pointer
                .unwrap()
                .wheel
        );
        old["pointer"]["wheel"] = serde_json::json!("true");
        assert!(serde_json::from_value::<AtlasSourceConfig>(old).is_err());
        assert!(
            serde_json::from_slice::<AtlasSourceConfig>(&serialized)
                .unwrap()
                .layout()
                .is_ok()
        );
        source.pointer.as_mut().unwrap().native_socket = "relative.sock".into();
        assert!(source.layout().is_err());
        source.pointer = None;
        source.windows.reverse();
        assert_eq!(layout, source.layout().unwrap());
        source.windows[0].address = "0x0001".into();
        assert!(source.layout().is_err());
        source.windows[0].address = "0x2".into();
        source.windows[0].window_id = source.media.stream_id.clone();
        assert!(source.layout().is_err());
        source.windows[0].window_id = format!("{:032x}", 2);
        source.windows[0].width = 65;
        assert!(source.layout().is_err());
    }

    #[test]
    fn shared_media_policy_preserves_receiver_wire_contract() {
        let config = config();
        let shared = config.media_policy();
        let receiver = config.plan().unwrap();
        let source = shared.plan().unwrap();
        assert_eq!(source.color, receiver.color);
        assert_eq!(source.alpha, receiver.alpha);
        assert_eq!(source.policy.max_age_ns, receiver.policy.max_age_ns);
        assert_eq!(source.policy.stream_id, receiver.policy.stream_id);
        assert_eq!(source.max_decoded_bytes, receiver.max_decoded_bytes);
        let mut value = serde_json::to_value(shared).unwrap();
        value["native_presenter"] = serde_json::json!("unused.exe");
        assert!(serde_json::from_value::<AtlasMediaPolicyConfig>(value).is_err());
    }

    #[test]
    fn receiver_config_has_two_frame_budget_and_explicit_native_limit() {
        let mut config = config();
        assert_eq!(config.plan().unwrap().policy.max_age_ns, 33_333_333);
        config.refresh_hz = 120;
        assert_eq!(config.plan().unwrap().policy.max_age_ns, 16_666_666);
        config.width = 6144;
        config.height = 3456;
        config.max_decoded_bytes = 128 << 20;
        let plan = config.plan().unwrap();
        assert_eq!(
            crate::atlas_receiver_presenter::native_record_limit(plan).unwrap(),
            128 << 20
        );
    }

    #[test]
    fn receiver_config_rejects_unknown_and_invalid_local_policy() {
        let original = serde_json::to_value(config()).unwrap();
        for (key, value) in [
            ("stream_id", serde_json::json!("0")),
            (
                "stream_id",
                serde_json::json!("00000000000000000000000000000000"),
            ),
            ("width", serde_json::json!(63)),
            ("refresh_hz", serde_json::json!(0)),
            ("max_encoded_bytes", serde_json::json!(0)),
            ("max_decoded_bytes", serde_json::json!(1)),
            ("startup_timeout_ms", serde_json::json!(0)),
            ("native_presenter", serde_json::json!("relative.exe")),
            ("input_enabled", serde_json::json!(true)),
        ] {
            let mut value_copy = original.clone();
            value_copy[key] = value;
            assert!(
                serde_json::from_value::<AtlasReceiverConfig>(value_copy)
                    .and_then(|v| v.plan().map_err(serde::de::Error::custom))
                    .is_err(),
                "accepted invalid {key}"
            );
        }
    }
}
