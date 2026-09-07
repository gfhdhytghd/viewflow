//! Native atlas pointer records. This is event decoding, not authorization.
use crate::window_preview_input::{PreviewPointerEvent, PreviewPointerSample};
use anyhow::{Context, Result, ensure};
use viewflow_protocol::{
    AtlasWindowSelection, Id128, InputSwitchState, PointerButton, PointerButtonEvent,
    PointerWheelEvent,
};

#[derive(Clone, Copy, Debug)]
pub struct AtlasNativePointer {
    /// Assigned only by the single stdout dispatcher. Direct parser tests and
    /// non-dispatched values deliberately retain zero.
    ingress_ordinal: u64,
    identity: AtlasWindowSelection,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    deadline_qpc: u64,
    frequency: u64,
    button: Option<PointerButtonEvent>,
    wheel: Option<PointerWheelEvent>,
    key: Option<viewflow_protocol::KeyboardHidUsage>,
    release: bool,
}

impl AtlasNativePointer {
    #[must_use]
    pub fn releases_input(&self) -> bool { self.release }
    pub fn focus_release_qpc(&self) -> u64 { self.deadline_qpc.saturating_sub(self.frequency.saturating_mul(5)) }

    pub fn ingress_ordinal(&self) -> u64 {
        self.ingress_ordinal
    }

    #[must_use]
    pub fn selection(&self) -> AtlasWindowSelection {
        self.identity
    }

    #[cfg(test)]
    pub(crate) fn fixture_ingress(self, ordinal: u64) -> Self {
        self.with_ingress_ordinal(ordinal).unwrap()
    }

    fn with_ingress_ordinal(mut self, ordinal: u64) -> Result<Self> {
        ensure!(ordinal > 0, "invalid atlas pointer ingress ordinal");
        self.ingress_ordinal = ordinal;
        Ok(self)
    }

    /// # Errors
    /// Rejects ambiguous, oversized, malformed and out-of-window native records.
    pub fn parse(line: &str) -> Result<Self> {
        ensure!(line.len() <= 1024, "atlas pointer record too large");
        let fields: Vec<_> = line.split(' ').collect();
        if fields.first() == Some(&"atlas-keyboard-v1") {
            return Self::parse_keyboard(&fields);
        }
        ensure!(
            matches!(fields.len(), 20 | 22) && fields[0] == "atlas-pointer-v1",
            "invalid atlas pointer envelope"
        );
        let number = |index: usize, name: &str| -> Result<u64> {
            let value = fields[index]
                .strip_prefix(name)
                .ok_or_else(|| anyhow::anyhow!("missing atlas pointer field {name}"))?;
            ensure!(
                !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()),
                "invalid atlas pointer integer"
            );
            Ok(value.parse()?)
        };
        let identity = AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: Id128(
                (u128::from(number(1, "stream_hi=")?) << 64) | u128::from(number(2, "stream_lo=")?),
            ),
            atlas_frame_id: number(3, "atlas_frame=")?,
            atlas_geometry_epoch: number(4, "atlas_epoch=")?,
            config_generation: number(5, "config_generation=")?,
            layout_revision: number(6, "layout_revision=")?,
            window_id: Id128(
                (u128::from(number(7, "window_hi=")?) << 64) | u128::from(number(8, "window_lo=")?),
            ),
            placement_generation: number(9, "placement_generation=")?,
            source_geometry_epoch: number(10, "source_epoch=")?,
            source_frame_id: number(11, "source_frame=")?,
            // Assigned from the receiver's ordered event stream during conversion.
            sequence: 1,
            sender_not_after_ns: 1,
        };
        identity
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid atlas pointer identity: {error:?}"))?;
        ensure!(
            number(13, "frame_identity=")? == identity.atlas_frame_id,
            "atlas pointer identity mismatch"
        );
        let (button, wheel) = match (fields[12], fields.len()) {
            ("kind=motion" | "kind=release", 20) => (None, None),
            ("kind=button", 22) => (
                Some(PointerButtonEvent {
                    button: match number(20, "button=")? {
                        1 => PointerButton::Left,
                        2 => PointerButton::Middle,
                        3 => PointerButton::Right,
                        4 => PointerButton::Back,
                        5 => PointerButton::Forward,
                        _ => anyhow::bail!("invalid atlas button"),
                    },
                    state: match number(21, "state=")? {
                        1 => InputSwitchState::Pressed,
                        2 => InputSwitchState::Released,
                        _ => anyhow::bail!("invalid atlas button transition"),
                    },
                }),
                None,
            ),
            ("kind=wheel", 22) => {
                let vertical = signed_wheel(fields[20], "wheel_vertical_120=")?;
                let horizontal = signed_wheel(fields[21], "wheel_horizontal_120=")?;
                ensure!(vertical != 0 || horizontal != 0, "empty atlas wheel event");
                (
                    None,
                    Some(PointerWheelEvent {
                        vertical_delta_detents: f64::from(vertical) / 120.0,
                        horizontal_delta_detents: f64::from(horizontal) / 120.0,
                    }),
                )
            }
            _ => anyhow::bail!("invalid atlas pointer kind"),
        };
        let result = Self {
            ingress_ordinal: 0,
            identity,
            button,
            wheel,
            key: None,
            release: fields[12] == "kind=release",
            x: u32::try_from(number(14, "x_pixels=")?)?,
            y: u32::try_from(number(15, "y_pixels=")?)?,
            width: u32::try_from(number(16, "viewport_width=")?)?,
            height: u32::try_from(number(17, "viewport_height=")?)?,
            deadline_qpc: number(18, "not_after_qpc=")?,
            frequency: number(19, "qpc_frequency=")?,
        };
        ensure!(
            result.x < result.width
                && result.y < result.height
                && result.deadline_qpc > 0
                && result.frequency > 0,
            "invalid atlas pointer geometry or clock"
        );
        Ok(result)
    }

    /// Sample the input process clock before sampling same-host QPC, so this
    /// conversion cannot extend the original OS event deadline. An expired
    /// motion may be dropped; an expired button or wheel retires the route.
    /// # Errors
    /// Rejects clock mismatch, future budgets, sequence/clock overflow.
    pub fn into_event(
        self,
        sequence: u64,
        local_sample_ns: u64,
        qpc_now: u64,
        frequency: u64,
    ) -> Result<Option<(AtlasWindowSelection, PreviewPointerEvent)>> {
        ensure!(
            sequence > 0 && frequency > 0 && frequency == self.frequency,
            "atlas pointer sequence or clock mismatch"
        );
        ensure!(!self.release, "input release must be routed as cleanup");
        let remaining = self.deadline_qpc.saturating_sub(qpc_now);
        let ns = u128::from(remaining) * 1_000_000_000 / u128::from(frequency);
        if ns == 0 {
            ensure!(
                self.button.is_none() && self.wheel.is_none() && self.key.is_none(),
                "atlas button or wheel expired; retire input route"
            );
            return Ok(None);
        }
        let event_budget_ns = if self.button.is_some() || self.wheel.is_some() || self.key.is_some()
        {
            crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS
        } else {
            33_333_334
        };
        ensure!(
            ns <= u128::from(event_budget_ns),
            "atlas pointer deadline exceeds event budget"
        );
        let deadline = local_sample_ns
            .checked_add(u64::try_from(ns)?)
            .ok_or_else(|| anyhow::anyhow!("atlas pointer deadline overflow"))?;
        let mut selection = self.identity;
        selection.activate_keyboard = self.key.is_some()
            || self
                .button
                .is_some_and(|button| button.state == InputSwitchState::Pressed);
        selection.sequence = sequence;
        selection.sender_not_after_ns = deadline;
        let sample = PreviewPointerSample {
            sample_sequence: sequence,
            presented: viewflow_core::PresentedInputIdentity {
                window: selection.window_id,
                frame: selection.source_frame_id,
                geometry_epoch: selection.source_geometry_epoch,
            },
            sender_not_after_ns: deadline,
            x_pixels: self.x,
            y_pixels: self.y,
            viewport_width: self.width,
            viewport_height: self.height,
        };
        Ok(Some((
            selection,
            PreviewPointerEvent {
                key: self.key,
                wheel: self.wheel,
                sample,
                button: self.button,
            },
        )))
    }
}

impl AtlasNativePointer {
    fn parse_keyboard(fields: &[&str]) -> Result<Self> {
        ensure!(fields.len() == 19, "invalid atlas keyboard envelope");
        let number = |index: usize, prefix: &str| -> Result<u64> {
            let value = fields[index]
                .strip_prefix(prefix)
                .ok_or_else(|| anyhow::anyhow!("missing atlas keyboard field {prefix}"))?;
            ensure!(
                !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()),
                "invalid atlas keyboard integer"
            );
            let parsed: u64 = value.parse()?;
            ensure!(
                parsed.to_string() == value,
                "noncanonical atlas keyboard integer"
            );
            Ok(parsed)
        };
        let identity = AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: Id128(
                (u128::from(number(1, "stream_hi=")?) << 64) | u128::from(number(2, "stream_lo=")?),
            ),
            atlas_frame_id: number(3, "atlas_frame=")?,
            atlas_geometry_epoch: number(4, "atlas_epoch=")?,
            config_generation: number(5, "config_generation=")?,
            layout_revision: number(6, "layout_revision=")?,
            window_id: Id128(
                (u128::from(number(7, "window_hi=")?) << 64) | u128::from(number(8, "window_lo=")?),
            ),
            placement_generation: number(9, "placement_generation=")?,
            source_geometry_epoch: number(10, "source_epoch=")?,
            source_frame_id: number(11, "source_frame=")?,
            sequence: 1,
            sender_not_after_ns: 1,
        };
        identity
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid keyboard visual identity: {error:?}"))?;
        ensure!(
            number(12, "frame_identity=")? == identity.atlas_frame_id,
            "keyboard visual identity mismatch"
        );
        let key = viewflow_protocol::KeyboardHidUsage {
            usage_page: u16::try_from(number(15, "usage_page=")?)?,
            usage_id: u16::try_from(number(16, "usage_id=")?)?,
            state: match number(17, "state=")? {
                1 => InputSwitchState::Pressed,
                2 => InputSwitchState::Released,
                _ => anyhow::bail!("invalid keyboard state"),
            },
            repeat: match number(18, "repeat=")? {
                0 => false,
                1 => true,
                _ => anyhow::bail!("invalid keyboard repeat"),
            },
        };
        ensure!(
            key.usage_page != 0
                && key.usage_id != 0
                && (!key.repeat || key.state == InputSwitchState::Pressed),
            "invalid physical keyboard usage"
        );
        let deadline_qpc = number(13, "not_after_qpc=")?;
        let frequency = number(14, "qpc_frequency=")?;
        ensure!(deadline_qpc > 0 && frequency > 0, "invalid keyboard clock");
        Ok(Self {
            ingress_ordinal: 0,
            identity,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            deadline_qpc,
            frequency,
            button: None,
            wheel: None,
            key: Some(key),
            release: false,
        })
    }
}

fn signed_wheel(field: &str, name: &str) -> Result<i16> {
    let value = field
        .strip_prefix(name)
        .ok_or_else(|| anyhow::anyhow!("missing atlas wheel field {name}"))?;
    let digits = value.strip_prefix('-').unwrap_or(value);
    ensure!(
        !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()),
        "invalid atlas wheel integer"
    );
    // Windows wheel messages carry a signed 16-bit delta in units of 120.
    let parsed: i16 = value.parse()?;
    ensure!(
        parsed.to_string() == value,
        "noncanonical atlas wheel integer"
    );
    Ok(parsed)
}

/// One continuously running stdout reader, including when no video is pending.
/// The owner must supervise this future and retire native/input on any failure.
/// Receipt bytes feed the existing pipe parser; pointer records cannot be
/// mistaken for completion receipts. All queues are bounded and loss is fatal.
/// # Errors
/// EOF, overflow, closed consumers or native input retirement end the reader.
pub async fn dispatch_stdout(
    reader: impl tokio::io::AsyncRead + Unpin,
    receipts: impl tokio::io::AsyncWrite + Unpin,
    pointers: tokio::sync::mpsc::Sender<AtlasNativePointer>,
) -> Result<()> {
    dispatch_stdout_with_recovery(reader, receipts, pointers, false).await
}

/// Recovery output is admitted only for an explicitly negotiated child. The
/// exclusive pending pipe transaction validates the complete receipt fields.
/// # Errors
/// As with `dispatch_stdout`, unknown records, EOF and queue failure are fatal.
pub async fn dispatch_stdout_with_recovery(
    reader: impl tokio::io::AsyncRead + Unpin,
    receipts: impl tokio::io::AsyncWrite + Unpin,
    pointers: tokio::sync::mpsc::Sender<AtlasNativePointer>,
    recovery: bool,
) -> Result<()> {
    dispatch_stdout_with_recovery_notices(reader, receipts, pointers, recovery, None).await
}

/// Recovery notices have their own bounded channel: a cancellation/drain
/// cannot be mistaken for an input event or a pipe receipt. A negotiated
/// recovery child must supply a consumer for this channel.
/// # Errors
/// EOF, an unknown record, queue overflow, or either consumer closing retires
/// the dispatcher so its owner can retire the native child.
pub async fn dispatch_stdout_with_recovery_notices(
    reader: impl tokio::io::AsyncRead + Unpin,
    receipts: impl tokio::io::AsyncWrite + Unpin,
    pointers: tokio::sync::mpsc::Sender<AtlasNativePointer>,
    recovery: bool,
    notices: Option<tokio::sync::mpsc::Sender<crate::atlas_input_recovery::NativeRecoveryNotice>>,
) -> Result<()> {
    dispatch_stdout_with_recovery_notices_and_desktop(
        reader, receipts, pointers, recovery, notices, None,
    )
    .await
}

fn native_queue_error<T>(
    lane: &str,
    capacity: usize,
    error: tokio::sync::mpsc::error::TrySendError<T>,
) -> anyhow::Error {
    // Never format the rejected record: keyboard records contain HID values.
    let reason = match error {
        tokio::sync::mpsc::error::TrySendError::Full(_) => "full",
        tokio::sync::mpsc::error::TrySendError::Closed(_) => "closed",
    };
    anyhow::anyhow!("atlas {lane} queue {reason}: capacity={capacity}")
}

/// Desktop move output is a third, independently supervised lane. It is only
/// enabled by the desktop/recovery child and cannot become a pointer event or
/// a picture/control receipt.
/// # Errors
/// EOF, an unexpected record, queue overflow, or any consumer closing retires
/// the dispatcher so its owner can retire the native child.
pub async fn dispatch_stdout_with_recovery_notices_and_desktop(
    reader: impl tokio::io::AsyncRead + Unpin,
    mut receipts: impl tokio::io::AsyncWrite + Unpin,
    pointers: tokio::sync::mpsc::Sender<AtlasNativePointer>,
    recovery: bool,
    notices: Option<tokio::sync::mpsc::Sender<crate::atlas_input_recovery::NativeRecoveryNotice>>,
    desktop_moves: Option<tokio::sync::mpsc::Sender<crate::desktop_pointer::AtlasDesktopMove>>,
) -> Result<()> {
    use tokio::io::AsyncWriteExt;
    ensure!(
        pointers.max_capacity() <= 64,
        "atlas pointer queue too large"
    );
    ensure!(
        notices.is_none() || recovery,
        "atlas recovery notice channel requires recovery capability"
    );
    if let Some(notices) = notices.as_ref() {
        ensure!(
            notices.max_capacity() <= 64,
            "atlas recovery notice queue too large"
        );
    }
    if let Some(desktop_moves) = desktop_moves.as_ref() {
        ensure!(
            recovery && notices.is_some() && desktop_moves.max_capacity() <= 64,
            "atlas desktop move queue capability or bound invalid"
        );
    }
    // Keep read-ahead across records: the bounded parser reads one byte at a
    // time, but a native pipe read must not be issued for every field byte.
    // This changes neither the line limit nor the bounded event queue.
    let mut reader = tokio::io::BufReader::with_capacity(4096, reader);
    let mut ingress_ordinal = 0_u64;
    let result = async {
    loop {
        let line = tokio::select! {
            line = crate::atlas_presenter::read_line_bounded(&mut reader, 1024) => line?,
            () = pointers.closed() => anyhow::bail!("atlas pointer consumer closed"),
            () = async {
                if let Some(notices) = notices.as_ref() {
                    notices.closed().await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => anyhow::bail!("atlas recovery notice consumer closed"),
            () = async {
                if let Some(desktop_moves) = desktop_moves.as_ref() {
                    desktop_moves.closed().await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => anyhow::bail!("atlas desktop move consumer closed"),
        };
        if line.starts_with("atlas-pointer") || line.starts_with("atlas-keyboard") {
            let pointer = AtlasNativePointer::parse(&line)?;
            ingress_ordinal = ingress_ordinal
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("atlas native ingress ordinal overflow"))?;
            pointers
                .try_send(pointer.with_ingress_ordinal(ingress_ordinal)?)
                .map_err(|error| native_queue_error("pointer", pointers.max_capacity(), error))?;
        } else if line.starts_with("atlas-input-suspended-v1") || line.starts_with("atlas-input-suspended-v2") {
            let notices = notices
                .as_ref()
                .context("atlas recovery notice without negotiated recovery")?;
            let mut notice = crate::atlas_input_recovery::NativeRecoveryNotice::parse(&line)?;
            if let Some(rejection) = notice.rejection.as_mut() {
                rejection.ingress_boundary = ingress_ordinal;
            }
            notices
                .try_send(notice)
                .map_err(|error| native_queue_error("recovery notice", notices.max_capacity(), error))?;
        } else if line.starts_with("desktop-move-v1") {
            let desktop_move = crate::desktop_pointer::AtlasDesktopMove::parse(&line)?;
            ingress_ordinal = ingress_ordinal
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("atlas native ingress ordinal overflow"))?;
            let desktop_moves = desktop_moves
                .as_ref()
                .context("atlas desktop move without negotiated desktop capability")?;
            desktop_moves
                .try_send(desktop_move.with_ingress_ordinal(ingress_ordinal)?)
                .map_err(|error| native_queue_error("desktop move", desktop_moves.max_capacity(), error))?;
        } else {
            ensure!(
                !line.starts_with("pointer-input-ended"),
                "native atlas input retired: {line}"
            );
            ensure!(
                line.starts_with("atlas-native-ready ")
                    || line.starts_with("atlas-warmup-completed ")
                    || line.starts_with("atlas-disposition-v1 ")
                    || (recovery && (line.starts_with("atlas-input-recovered-v1 ")
                        || line.starts_with("atlas-input-recovered-v2 ")
                        || line.starts_with("atlas-input-cancelled-v2 "))),
                // Recovery never enters the input queue or changes event sequence.
                "unexpected atlas native output"
            );
            tokio::select! {
                result = async { receipts.write_all(line.as_bytes()).await?; receipts.write_all(b"\n").await?; receipts.flush().await } => result?,
                () = pointers.closed() => anyhow::bail!("atlas pointer consumer closed"),
                () = async {
                    if let Some(notices) = notices.as_ref() {
                        notices.closed().await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                } => anyhow::bail!("atlas recovery notice consumer closed"),
                () = async {
                    if let Some(desktop_moves) = desktop_moves.as_ref() {
                        desktop_moves.closed().await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                } => anyhow::bail!("atlas desktop move consumer closed"),
            }
        }
    }
    }.await;
    // Keep the producer alive until its actual error is recorded. Dropping it
    // first can wake the input owner on another worker, which then aborts this
    // stdout task during teardown before an outer wrapper can log the cause.
    if let Err(error) = &result {
        eprintln!("atlas-native-output-ended: {error:#}");
    }
    drop(pointers);
    drop(notices);
    drop(desktop_moves);
    result
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;

    const KEYBOARD: &str = "atlas-keyboard-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 frame_identity=100 not_after_qpc=120 qpc_frequency=1000 usage_page=7 usage_id=4 state=1 repeat=0";

    #[test]
    fn native_ordered_operation_budget_survives_conversion_without_extension() {
        for (kind, suffix) in [
            ("button", " button=1 state=1"),
            ("button", " button=1 state=2"),
            ("wheel", " wheel_vertical_120=120 wheel_horizontal_120=0"),
        ] {
            let line = format!(
                "{}{}",
                MOTION
                    .replace("kind=motion", &format!("kind={kind}"))
                    .replace("not_after_qpc=120", "not_after_qpc=5100"),
                suffix
            );
            let event = AtlasNativePointer::parse(&line).unwrap();
            let (selection, converted) = event.into_event(9, 1_000, 140, 1000).unwrap().unwrap();
            assert_eq!(selection.sender_not_after_ns, 4_960_001_000);
            assert_eq!(
                converted.sample.sender_not_after_ns,
                selection.sender_not_after_ns
            );
            assert!(event.into_event(9, 1_000, 99, 1000).is_err());
        }
        let motion =
            AtlasNativePointer::parse(&MOTION.replace("not_after_qpc=120", "not_after_qpc=5100"))
                .unwrap();
        assert!(motion.into_event(9, 1_000, 140, 1000).is_err());
    }

    #[test]
    fn keyboard_record_has_no_pointer_coordinates_and_keeps_original_deadline() {
        let parsed = AtlasNativePointer::parse(KEYBOARD).unwrap();
        assert_eq!(parsed.ingress_ordinal(), 0);
        let (selection, event) = parsed.into_event(9, 1000, 110, 1000).unwrap().unwrap();
        assert_eq!(selection.window_id, Id128(8));
        assert!(selection.activate_keyboard);
        assert_eq!(event.sample.presented.frame, 19);
        assert_eq!(event.sample.sender_not_after_ns, 10_001_000);
        assert_eq!(event.sample.viewport_width, 0);
        assert!(event.button.is_none() && event.wheel.is_none() && !event.is_motion());
        assert_eq!(event.key.unwrap().usage_id, 4);
        assert!(parsed.into_event(9, 1000, 120, 1000).is_err());
        assert!(parsed.into_event(9, 1000, 110, 1001).is_err());
        assert!(parsed.into_event(9, 1000, 10, 1000).unwrap().is_some());
        let fields: Vec<_> = KEYBOARD.split(' ').collect();
        for length in 0..fields.len() {
            assert!(AtlasNativePointer::parse(&fields[..length].join(" ")).is_err());
        }
        for (from, to) in [
            ("atlas-keyboard-v1", "atlas-pointer-v1"),
            ("atlas-keyboard-v1", "atlas-keyboard-v2"),
            ("usage_page=7", "usage_page=0"),
            ("usage_id=4", "usage_id=65536"),
            ("usage_id=4", "usage_id=04"),
            ("state=1", "state=3"),
            ("repeat=0", "repeat=2"),
            ("state=1 repeat=0", "state=2 repeat=1"),
            ("frame_identity=100", "frame_identity=101"),
            ("not_after_qpc=120", "not_after_qpc=0"),
        ] {
            assert!(AtlasNativePointer::parse(&KEYBOARD.replace(from, to)).is_err());
        }
        assert!(AtlasNativePointer::parse(&format!("{KEYBOARD} x_pixels=1")).is_err());
    }
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    pub(crate) const MOTION: &str = "atlas-pointer-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 kind=motion frame_identity=100 x_pixels=2 y_pixels=3 viewport_width=64 viewport_height=64 not_after_qpc=120 qpc_frequency=1000";

    #[test]
    fn focus_release_is_cleanup_and_cannot_become_pointer_motion() {
        let event = AtlasNativePointer::parse(&MOTION.replace("kind=motion", "kind=release")).unwrap();
        assert!(event.releases_input());
        assert_eq!(event.selection().window_id, Id128(8));
        assert!(event.into_event(9, 1000, 110, 1000).is_err());
    }

    #[test]
    fn only_button_down_requests_keyboard_activation() {
        for (state, activates) in [(1, true), (2, false)] {
            let line = format!(
                "{} button=1 state={state}",
                MOTION.replace("kind=motion", "kind=button")
            );
            let (selection, _) = AtlasNativePointer::parse(&line)
                .unwrap()
                .into_event(9, 1000, 110, 1000)
                .unwrap()
                .unwrap();
            assert_eq!(selection.activate_keyboard, activates);
            assert_eq!(selection.sender_not_after_ns, 10_001_000);
        }
    }

    #[test]
    fn source_identity_and_original_deadline_survive_conversion() {
        let event = AtlasNativePointer::parse(MOTION).unwrap();
        assert_eq!(event.ingress_ordinal(), 0);
        let (selection, native) = event.into_event(9, 1000, 110, 1000).unwrap().unwrap();
        assert_eq!(selection.atlas_frame_id, 100);
        assert!(!selection.activate_keyboard);
        assert_eq!(native.sample.presented.frame, 19);
        assert_eq!(native.sample.presented.window, Id128(8));
        assert_eq!(native.sample.presented.geometry_epoch, 7);
        assert_eq!(selection.sequence, native.sample.sample_sequence);
        assert_eq!(selection.sender_not_after_ns, 10_001_000);
        assert_eq!(
            selection.sender_not_after_ns,
            native.sample.sender_not_after_ns
        );
        assert!(event.into_event(10, 1000, 120, 1000).unwrap().is_none());
        assert!(event.into_event(10, 1000, 121, 1000).unwrap().is_none());
        assert!(event.into_event(10, 1000, 110, 1001).is_err());
        assert!(event.into_event(10, 1000, 10, 1000).is_err());
        assert!(event.into_event(0, 1000, 110, 1000).is_err());
        let button = format!(
            "{} button=1 state=1",
            MOTION.replace("kind=motion", "kind=button")
        );
        let event = AtlasNativePointer::parse(&button).unwrap();
        assert!(event.into_event(10, 1000, 120, 1000).is_err());
        assert_eq!(
            event
                .into_event(10, 1000, 110, 1000)
                .unwrap()
                .unwrap()
                .1
                .button
                .unwrap()
                .button,
            PointerButton::Left
        );
    }

    #[test]
    fn wheel_retains_fractional_axes_identity_and_original_deadline() {
        let line = format!(
            "{} wheel_vertical_120=30 wheel_horizontal_120=-60",
            MOTION.replace("kind=motion", "kind=wheel")
        );
        let parsed = AtlasNativePointer::parse(&line).unwrap();
        let (selection, event) = parsed.into_event(9, 1000, 110, 1000).unwrap().unwrap();
        assert_eq!(selection.atlas_frame_id, 100);
        assert_eq!(event.sample.presented.frame, 19);
        assert_eq!(event.sample.sample_sequence, 9);
        assert_eq!(event.sample.sender_not_after_ns, 10_001_000);
        assert_eq!(
            selection.sender_not_after_ns,
            event.sample.sender_not_after_ns
        );
        assert!(event.button.is_none());
        assert!(!event.is_motion());
        assert_eq!(
            event.wheel.unwrap(),
            PointerWheelEvent {
                vertical_delta_detents: 0.25,
                horizontal_delta_detents: -0.5,
            }
        );
        assert!(parsed.into_event(10, 1000, 120, 1000).is_err());
        assert!(parsed.into_event(10, 1000, 121, 1000).is_err());
        for invalid in ["+30", "030", "-0", "", "1.5", "32768", "-32769", "NaN"] {
            assert!(
                AtlasNativePointer::parse(&line.replace("=30", &format!("={invalid}"))).is_err(),
                "{invalid}"
            );
        }
        assert!(
            AtlasNativePointer::parse(&line.replace("=30", "=0").replace("=-60", "=0")).is_err()
        );
        assert!(AtlasNativePointer::parse(&line.replace("kind=wheel", "kind=motion")).is_err());
        assert!(AtlasNativePointer::parse(&line.replace("kind=wheel", "kind=button")).is_err());
        for delta in ["-32768", "32767", "1", "-1"] {
            assert!(AtlasNativePointer::parse(&line.replace("=30", &format!("={delta}"))).is_ok());
        }
    }

    #[test]
    fn malformed_records_never_become_events() {
        for (from, to) in [
            ("frame_identity=100", "frame_identity=19"),
            ("source_frame=19", "source_frame=0"),
            ("x_pixels=2", "x_pixels=-1"),
            ("x_pixels=2", "x_pixels=64"),
            ("source_epoch=7", "source_epoch=+7"),
            ("window_lo=8", "window_lo=99"),
            ("stream_hi=0", "stream_hi=18446744073709551616"),
            ("kind=motion", "kind=button"),
            ("qpc_frequency=1000", "qpc_frequency=0"),
            ("placement_generation=4", "placement_generation=5"),
            (" window_hi", "  window_hi"),
        ] {
            assert!(
                AtlasNativePointer::parse(&MOTION.replace(from, to)).is_err(),
                "{to}"
            );
        }
        assert!(AtlasNativePointer::parse(&format!("{MOTION} extra=1")).is_err());
    }

    #[tokio::test]
    async fn recovery_receipts_require_opt_in_and_never_enter_input_queue() {
        for enabled in [false, true] {
            let (mut native, read) = tokio::io::duplex(4096);
            let (mut receipts, write) = tokio::io::duplex(4096);
            let (send, mut pointers) = tokio::sync::mpsc::channel(2);
            let worker = tokio::spawn(dispatch_stdout_with_recovery(read, write, send, enabled));
            // The pending exclusive transaction performs complete binding checks.
            let reply = b"atlas-input-recovered-v1 sequence=1\n";
            native.write_all(reply).await.unwrap();
            if enabled {
                let mut actual = vec![0; reply.len()];
                receipts.read_exact(&mut actual).await.unwrap();
                assert_eq!(actual, reply);
                assert!(matches!(
                    pointers.try_recv(),
                    Err(tokio::sync::mpsc::error::TryRecvError::Empty)
                ));
                drop(pointers);
            }
            assert!(
                tokio::time::timeout(std::time::Duration::from_secs(1), worker)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
            assert_eq!(
                receipts.read_u8().await.unwrap_err().kind(),
                std::io::ErrorKind::UnexpectedEof
            );
        }
    }

    const RECOVERY_NOTICE: &str = "atlas-input-suspended-v1 phase=cancelled stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 layout_revision=11 previous_epoch=6 previous_atlas_frame=8 previous_source_frame=9 geometry_epoch=7 atlas_frame=10 source_frame=12 placement_generation=11 observed_qpc=110 frequency=1000";

    #[tokio::test]
    async fn recovery_notice_is_opt_in_typed_and_never_a_receipt_or_input() {
        let (mut native, read) = tokio::io::duplex(4096);
        let (mut receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, mut pointers) = tokio::sync::mpsc::channel(2);
        let (notice_sender, mut notices) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
        ));
        native
            .write_all(format!("{RECOVERY_NOTICE}\n").as_bytes())
            .await
            .unwrap();
        let notice = tokio::time::timeout(Duration::from_secs(1), notices.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(!notice.physical_drained);
        assert_eq!(notice.selection.atlas_frame_id, 10);
        assert!(matches!(
            pointers.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        assert!(matches!(
            tokio::time::timeout(Duration::from_millis(20), receipts.read_u8()).await,
            Err(_)
        ));
        drop(notices);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        assert_eq!(
            receipts.read_u8().await.unwrap_err().kind(),
            std::io::ErrorKind::UnexpectedEof
        );

        let (mut native, read) = tokio::io::duplex(4096);
        let (receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, _pointers) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout_with_recovery(
            read,
            write,
            pointer_sender,
            false,
        ));
        native
            .write_all(format!("{RECOVERY_NOTICE}\n").as_bytes())
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        drop(receipts);
    }

    #[tokio::test]
    async fn recovery_notice_overflow_or_consumer_close_is_fatal_while_idle() {
        let (native, read) = tokio::io::duplex(4096);
        let (_receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, _pointers) = tokio::sync::mpsc::channel(2);
        let (notice_sender, notices) = tokio::sync::mpsc::channel(1);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
        ));
        drop(notices);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        drop(native);

        let (mut native, read) = tokio::io::duplex(4096);
        let (_receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, _pointers) = tokio::sync::mpsc::channel(2);
        let (notice_sender, _notices) = tokio::sync::mpsc::channel(1);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
        ));
        native
            .write_all(format!("{RECOVERY_NOTICE}\n{RECOVERY_NOTICE}\n").as_bytes())
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
    }

    const DESKTOP_MOVE: &str = "desktop-move-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 topology_generation=5 drag_id=6 sequence=9 phase=update deadline_qpc=120 qpc_frequency=1000 x_millidip=-100 y_millidip=200 width_millidip=640 height_millidip=480";

    #[tokio::test]
    async fn desktop_moves_require_opt_in_and_never_enter_other_native_lanes() {
        let (mut native, read) = tokio::io::duplex(4096);
        let (mut receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, mut pointers) = tokio::sync::mpsc::channel(2);
        let (notice_sender, _notices) = tokio::sync::mpsc::channel(2);
        let (move_sender, mut moves) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices_and_desktop(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
            Some(move_sender),
        ));
        native
            .write_all(format!("{DESKTOP_MOVE}\n").as_bytes())
            .await
            .unwrap();
        let move_event = tokio::time::timeout(Duration::from_secs(1), moves.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(move_event.selection.window_id, Id128(8));
        assert_eq!(move_event.ingress_ordinal(), 1);
        assert!(matches!(
            pointers.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        assert!(matches!(
            tokio::time::timeout(Duration::from_millis(20), receipts.read_u8()).await,
            Err(_)
        ));
        drop(moves);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );

        let (mut native, read) = tokio::io::duplex(4096);
        let (_receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, _pointers) = tokio::sync::mpsc::channel(2);
        let (notice_sender, _notices) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
        ));
        native
            .write_all(format!("{DESKTOP_MOVE}\n").as_bytes())
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
    }

    #[tokio::test]
    async fn desktop_and_pointer_lanes_retain_their_shared_stdout_arrival_order() {
        let (mut native, read) = tokio::io::duplex(4096);
        let (_receipts, write) = tokio::io::duplex(4096);
        let (pointer_sender, mut pointers) = tokio::sync::mpsc::channel(4);
        let (notice_sender, _notices) = tokio::sync::mpsc::channel(2);
        let (move_sender, mut moves) = tokio::sync::mpsc::channel(4);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices_and_desktop(
            read,
            write,
            pointer_sender,
            true,
            Some(notice_sender),
            Some(move_sender),
        ));

        native
            .write_all(
                format!(
                    "{MOTION}\n{DESKTOP_MOVE}\n{KEYBOARD}\n{}\n",
                    DESKTOP_MOVE.replace("phase=update", "phase=end")
                )
                .as_bytes(),
            )
            .await
            .unwrap();

        assert_eq!(pointers.recv().await.unwrap().ingress_ordinal(), 1);
        assert_eq!(moves.recv().await.unwrap().ingress_ordinal(), 2);
        assert_eq!(pointers.recv().await.unwrap().ingress_ordinal(), 3);
        assert_eq!(moves.recv().await.unwrap().ingress_ordinal(), 4);

        drop(moves);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
    }

    #[tokio::test]
    async fn stdout_separates_idle_events_receipts_and_closure() {
        let (mut native, read) = tokio::io::duplex(4096);
        let (mut receipts, write) = tokio::io::duplex(4096);
        let (send, mut pointers) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout(read, write, send));
        let ready = b"atlas-native-ready disposition=v1 input_enabled=true pointer=v1\n";
        native.write_all(ready).await.unwrap();
        native
            .write_all(format!("{MOTION}\n").as_bytes())
            .await
            .unwrap();
        let mut ready_received = vec![0; ready.len()];
        receipts.read_exact(&mut ready_received).await.unwrap();
        assert_eq!(ready_received, ready);
        let event = pointers.recv().await.unwrap();
        assert_eq!(event.identity.source_frame_id, 19);
        native
            .write_all(format!("{KEYBOARD}\n").as_bytes())
            .await
            .unwrap();
        let event = pointers.recv().await.unwrap();
        assert_eq!(event.key.unwrap().usage_id, 4);
        assert!(event.button.is_none() && event.wheel.is_none());
        // No pending video read is necessary to receive this event.
        drop(pointers);
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(1), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        assert_eq!(
            receipts.read_u8().await.unwrap_err().kind(),
            std::io::ErrorKind::UnexpectedEof
        );
    }

    #[tokio::test]
    async fn stdout_batches_pipe_reads_without_reordering_records() {
        use std::{
            pin::Pin,
            sync::{
                Arc,
                atomic::{AtomicUsize, Ordering},
            },
            task::{Context, Poll},
        };
        struct CountedRead {
            bytes: std::io::Cursor<Vec<u8>>,
            reads: Arc<AtomicUsize>,
        }
        impl tokio::io::AsyncRead for CountedRead {
            fn poll_read(
                mut self: Pin<&mut Self>,
                cx: &mut Context<'_>,
                buf: &mut tokio::io::ReadBuf<'_>,
            ) -> Poll<std::io::Result<()>> {
                self.reads.fetch_add(1, Ordering::Relaxed);
                Pin::new(&mut self.bytes).poll_read(cx, buf)
            }
        }
        let ready = "atlas-native-ready disposition=v1 input_enabled=true pointer=v1\n";
        let second = MOTION.replace("source_frame=19", "source_frame=20");
        let bytes = format!("{ready}{MOTION}\n{second}\n").into_bytes();
        assert!(bytes.len() < 4096);
        let reads = Arc::new(AtomicUsize::new(0));
        let reader = CountedRead {
            bytes: std::io::Cursor::new(bytes),
            reads: reads.clone(),
        };
        let (mut receipts, write) = tokio::io::duplex(4096);
        let (send, mut pointers) = tokio::sync::mpsc::channel(2);
        // EOF still retires the reader after delivering all complete records.
        assert!(dispatch_stdout(reader, write, send).await.is_err());
        assert_eq!(reads.load(Ordering::Relaxed), 2); // One batch plus EOF.
        assert_eq!(pointers.recv().await.unwrap().identity.source_frame_id, 19);
        assert_eq!(pointers.recv().await.unwrap().identity.source_frame_id, 20);
        assert!(pointers.recv().await.is_none());
        let mut received = String::new();
        receipts.read_to_string(&mut received).await.unwrap();
        assert_eq!(received, ready);
    }

    #[test]
    fn bounded_native_queue_distinguishes_full_from_closed_without_record_contents() {
        let (send, receive) = tokio::sync::mpsc::channel(1);
        send.try_send("private-key-record").unwrap();
        let full = native_queue_error(
            "pointer",
            send.max_capacity(),
            send.try_send("private-key-record").unwrap_err(),
        );
        assert_eq!(full.to_string(), "atlas pointer queue full: capacity=1");
        drop(receive);
        let closed = native_queue_error(
            "pointer",
            send.max_capacity(),
            send.try_send("private-key-record").unwrap_err(),
        );
        assert_eq!(closed.to_string(), "atlas pointer queue closed: capacity=1");
    }

    #[tokio::test]
    async fn stdout_overflow_and_native_retirement_are_terminal() {
        for output in [
            format!("{MOTION}\n{MOTION}\n"),
            format!("atlas-pointer{}\n", "x".repeat(1024)),
            "pointer-input-ended reason=atlas-focus-or-capture-lost\n".to_owned(),
        ] {
            let (mut native, read) = tokio::io::duplex(4096);
            let (_receipts, write) = tokio::io::duplex(4096);
            let (send, _pointers) = tokio::sync::mpsc::channel(1);
            let worker = tokio::spawn(dispatch_stdout(read, write, send));
            native.write_all(output.as_bytes()).await.unwrap();
            assert!(
                tokio::time::timeout(std::time::Duration::from_secs(1), worker)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
        }
    }
    #[tokio::test]
    async fn rejected_notice_boundary_comes_only_from_prior_dispatched_input() {
        let (mut native, read) = tokio::io::duplex(4096);
        let (mut receipts, write) = tokio::io::duplex(4096);
        let (send, mut pointers) = tokio::sync::mpsc::channel(4);
        let (notice_send, mut notices) = tokio::sync::mpsc::channel(2);
        let worker = tokio::spawn(dispatch_stdout_with_recovery_notices(
            read,
            write,
            send,
            true,
            Some(notice_send),
        ));
        let notice = RECOVERY_NOTICE.replace("suspended-v1", "suspended-v2")
            + " cause=rejected cancel_sequence=2";
        native
            .write_all(
                format!("{MOTION}\n{notice}\n{MOTION}\natlas-input-cancelled-v2 sequence=2\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let first = pointers.recv().await.unwrap();
        let cancelled = notices.recv().await.unwrap();
        let second = pointers.recv().await.unwrap();
        assert_eq!(first.ingress_ordinal(), 1);
        assert_eq!(cancelled.rejection.unwrap().ingress_boundary, 1);
        assert_eq!(second.ingress_ordinal(), 2);
        assert_eq!(
            first.selection().window_id,
            AtlasNativePointer::parse(MOTION)
                .unwrap()
                .selection()
                .window_id
        );
        let mut reply = vec![0; b"atlas-input-cancelled-v2 sequence=2\n".len()];
        receipts.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, b"atlas-input-cancelled-v2 sequence=2\n");
        drop(pointers);
        assert!(worker.await.unwrap().is_err());
    }
}
