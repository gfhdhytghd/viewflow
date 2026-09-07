//! Deadline-bound V5 native pipe handoff. Visual submission is not scanout or
//! input authorization. The application still owns and supervises the child.
use anyhow::{Context, Result, ensure};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::{Instant, timeout_at};

use crate::{
    atlas_runtime::AdmittedAtlas,
    gpu_presenter_pipe::{NativePresentationDeadline, encode_atlas_record},
};

#[derive(Debug, PartialEq, Eq)]
pub struct AtlasVisualSubmission {
    pub frame_id: u64,
    pub tile_count: usize,
}

/// A capability-gated disposition, not a scanout receipt or input authorization.
/// This contract is deliberately separate from legacy `atlas-submitted`.
#[derive(Debug, PartialEq, Eq)]
pub enum AtlasDisposition {
    ExpiredUnbound,
    CommittedWithinDeadline { commit_ticks: u64 },
    CommittedLate { commit_ticks: u64 },
}

impl AtlasDisposition {
    /// Validate against the exact pending frame and same-host clock interval.
    /// The caller must separately negotiate this protocol and bound receipt wait.
    /// Native code must prove unbound state before emitting `expired-unbound`.
    ///
    /// # Errors
    /// Rejects legacy responses, mismatched identities/clocks, malformed fields,
    /// and commits outside the observed clock interval. Late commits remain
    /// valid visual submissions and are reported as performance misses.
    pub fn parse(
        line: &str,
        frame_id: u64,
        tile_count: usize,
        start_ticks: u64,
        receipt_ticks: u64,
        deadline: NativePresentationDeadline,
    ) -> Result<Self> {
        ensure!(frame_id > 0 && tile_count <= 4096, "invalid pending frame");
        ensure!(
            deadline.frequency > 0 && deadline.ticks > 0 && receipt_ticks >= start_ticks,
            "invalid disposition clock interval"
        );
        let fields: Vec<_> = line.split(' ').collect();
        ensure!(
            fields.len() == 8
                && fields[0] == "atlas-disposition-v1"
                && fields[7] == "physical_present_receipt=false",
            "invalid disposition envelope"
        );
        let number = |index: usize, prefix: &str| -> Result<u64> {
            let value = fields[index]
                .strip_prefix(prefix)
                .ok_or_else(|| anyhow::anyhow!("missing disposition field"))?;
            ensure!(
                !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()),
                "invalid disposition integer"
            );
            Ok(value.parse()?)
        };
        ensure!(
            number(1, "frame_identity=")? == frame_id
                && number(2, "tile_count=")? == tile_count as u64
                && number(4, "deadline_ticks=")? == deadline.ticks
                && number(5, "frequency=")? == deadline.frequency,
            "disposition does not match pending frame or clock"
        );
        let ticks = number(6, "commit_ticks=")?;
        match fields[3] {
            "outcome=expired-unbound" => {
                ensure!(
                    ticks == 0 && receipt_ticks >= deadline.ticks,
                    "invalid expired-unbound disposition"
                );
                Ok(Self::ExpiredUnbound)
            }
            "outcome=committed" => {
                ensure!(
                    ticks >= start_ticks && ticks <= receipt_ticks,
                    "commit outside observed native clock interval"
                );
                if ticks >= deadline.ticks {
                    return Ok(Self::CommittedLate {
                        commit_ticks: ticks,
                    });
                }
                Ok(Self::CommittedWithinDeadline {
                    commit_ticks: ticks,
                })
            }
            _ => anyhow::bail!("unknown atlas disposition"),
        }
    }
}

#[cfg(test)]
mod disposition_tests {
    use super::*;

    fn parse(line: &str, receipt: u64) -> Result<AtlasDisposition> {
        AtlasDisposition::parse(
            line,
            9,
            2,
            100,
            receipt,
            NativePresentationDeadline {
                ticks: 200,
                frequency: 10_000_000,
            },
        )
    }

    const COMMIT: &str = "atlas-disposition-v1 frame_identity=9 tile_count=2 outcome=committed deadline_ticks=200 frequency=10000000 commit_ticks=199 physical_present_receipt=false";

    #[test]
    fn on_time_commit_may_have_late_receipt_without_becoming_scanout() {
        assert_eq!(
            parse(COMMIT, 250).unwrap(),
            AtlasDisposition::CommittedWithinDeadline { commit_ticks: 199 }
        );
        assert!(parse(COMMIT, 198).is_err());
        for ticks in [200, 201, 250] {
            assert_eq!(
                parse(
                    &COMMIT.replace("commit_ticks=199", &format!("commit_ticks={ticks}")),
                    250
                )
                .unwrap(),
                AtlasDisposition::CommittedLate {
                    commit_ticks: ticks
                }
            );
        }
        for ticks in [0, 99, 251, u64::MAX] {
            assert!(
                parse(
                    &COMMIT.replace("commit_ticks=199", &format!("commit_ticks={ticks}")),
                    250
                )
                .is_err()
            );
        }
    }

    #[test]
    fn expired_requires_no_commit_and_elapsed_deadline() {
        let expired = COMMIT
            .replace("outcome=committed", "outcome=expired-unbound")
            .replace("commit_ticks=199", "commit_ticks=0");
        assert_eq!(
            parse(&expired, 200).unwrap(),
            AtlasDisposition::ExpiredUnbound
        );
        assert!(parse(&expired, 199).is_err());
        assert!(parse(&expired.replace("commit_ticks=0", "commit_ticks=1"), 250).is_err());
    }

    #[test]
    fn disposition_rejects_identity_clock_and_wire_ambiguity() {
        for (from, to) in [
            ("frame_identity=9", "frame_identity=8"),
            ("tile_count=2", "tile_count=3"),
            ("deadline_ticks=200", "deadline_ticks=201"),
            ("frequency=10000000", "frequency=10000001"),
            ("outcome=committed", "outcome=submitted"),
            ("commit_ticks=199", "commit_ticks=+199"),
            (
                "physical_present_receipt=false",
                "physical_present_receipt=true",
            ),
            (" frame_identity", "  frame_identity"),
        ] {
            assert!(parse(&COMMIT.replace(from, to), 250).is_err(), "{to}");
        }
        assert!(parse(&format!("{COMMIT} extra=true"), 250).is_err());
        assert!(
            parse(
                "atlas-submitted frame_identity=9 tile_count=2 physical_present_receipt=false",
                250
            )
            .is_err()
        );
        assert!(submission(COMMIT).is_err());
        assert!(parse(COMMIT, 99).is_err());
    }
}

#[derive(Clone)]
pub struct AtlasWarmupFrame {
    pub width: u32,
    pub height: u32,
    pub color: bytes::Bytes,
    pub alpha: bytes::Bytes,
}

fn submission(line: &str) -> Result<AtlasVisualSubmission> {
    let fields: Vec<_> = line.split(' ').collect();
    ensure!(
        fields.len() == 4
            && fields[0] == "atlas-submitted"
            && fields[3] == "physical_present_receipt=false",
        "not an atlas visual submission"
    );
    let frame_id = fields[1]
        .strip_prefix("frame_identity=")
        .ok_or_else(|| anyhow::anyhow!("missing atlas frame identity"))?
        .parse::<u64>()?;
    let tile_count = fields[2]
        .strip_prefix("tile_count=")
        .ok_or_else(|| anyhow::anyhow!("missing atlas tile count"))?
        .parse::<usize>()?;
    ensure!(
        frame_id > 0 && tile_count <= 4096,
        "invalid atlas submission identity or count"
    );
    Ok(AtlasVisualSubmission {
        frame_id,
        tile_count,
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ReceiptMode {
    Legacy,
    Disposition,
    DispositionNeedsKeyframe,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum NativeInputMode {
    Disabled,
    Pointer,
    PointerWheel,
    DirectKeyboard,
    RecoverableKeyboard,
    RecoverableDesktop,
}

pub struct AtlasPresenterPipe<W, R> {
    io: Option<(W, R)>,
    ready: bool,
    poisoned: bool,
    last_frame: u64,
    // ExpiredUnbound advances the decoder/replay floor, not the visual that
    // V9 recovery can bind. Keep those identities separate across a gap.
    last_committed_frame: u64,
    warmup_shape: Option<(u32, u32)>,
    receipt_mode: ReceiptMode,
    input_mode: NativeInputMode,
    last_recovery: u64,
}

impl<W: AsyncWrite + Unpin, R: AsyncRead + Unpin> AtlasPresenterPipe<W, R> {
    pub fn new(writer: W, reader: R) -> Self {
        Self {
            io: Some((writer, reader)),
            ready: false,
            poisoned: false,
            last_frame: 0,
            last_committed_frame: 0,
            warmup_shape: None,
            receipt_mode: ReceiptMode::Legacy,
            input_mode: NativeInputMode::Disabled,
            last_recovery: 0,
        }
    }

    /// Requires a child explicitly launched with `--atlas-disposition-v1`.
    pub fn with_dispositions(writer: W, reader: R) -> Self {
        Self {
            receipt_mode: ReceiptMode::Disposition,
            ..Self::new(writer, reader)
        }
    }

    /// Requires a continuously supervised stdout demultiplexer and a child
    /// explicitly launched with both disposition and atlas-pointer-v1 flags.
    pub fn with_pointer_events(writer: W, reader: R) -> Self {
        Self {
            input_mode: NativeInputMode::Pointer,
            ..Self::with_dispositions(writer, reader)
        }
    }

    /// Requires an explicitly launched wheel-capable native pointer producer.
    pub fn with_wheel_events(writer: W, reader: R) -> Self {
        Self {
            input_mode: NativeInputMode::PointerWheel,
            ..Self::with_pointer_events(writer, reader)
        }
    }

    /// Requires explicit keyboard, wheel, pointer and disposition capabilities.
    pub fn with_keyboard_events(writer: W, reader: R) -> Self {
        Self {
            input_mode: NativeInputMode::DirectKeyboard,
            ..Self::with_wheel_events(writer, reader)
        }
    }

    /// Requires the explicit native recovery flag and a recovery-aware stdout
    /// demultiplexer. This constructor alone does not authorize source input.
    pub fn with_input_recovery(writer: W, reader: R) -> Self {
        Self {
            input_mode: NativeInputMode::RecoverableKeyboard,
            ..Self::with_keyboard_events(writer, reader)
        }
    }

    /// Requires every recovery capability plus the separately negotiated
    /// desktop viewport/move lane. It never silently accepts recovery-only
    /// readiness because v7 records and desktop move output are coupled.
    pub fn with_desktop(writer: W, reader: R) -> Self {
        Self {
            input_mode: NativeInputMode::RecoverableDesktop,
            ..Self::with_input_recovery(writer, reader)
        }
    }

    /// Send a source-post-cleanup confirmation and consume its exact native
    /// receipt as one exclusive pipe transaction. The caller must first verify
    /// the source lease and the committed tile; this pipe knows only frame IDs.
    /// # Errors
    /// Any attempted recovery failure/cancellation permanently retires the pipe.
    pub async fn recover_input(
        &mut self,
        confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation,
        deadline: Instant,
        mut clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<u64> {
        ensure!(
            self.ready && !self.poisoned,
            "recovery presenter not ready or retired"
        );
        self.poisoned = true;
        let mut io = self.io.take().context("atlas recovery pipe missing")?;
        ensure!(
            matches!(
                self.input_mode,
                NativeInputMode::RecoverableKeyboard | NativeInputMode::RecoverableDesktop
            ) && (self.receipt_mode == ReceiptMode::Disposition
                || (confirmation.rejection.is_some()
                    && self.receipt_mode == ReceiptMode::DispositionNeedsKeyframe)),
            "atlas recovery capability or committed disposition unavailable"
        );
        // V9 changes input authority only. A clean decode gap must survive
        // Cancel/Resume, and its expired frame is never a committed identity.
        // V6 keeps its existing strict no-gap/latest-frame requirement.
        let recovery_frame = if confirmation.rejection.is_some() {
            self.last_committed_frame
        } else {
            self.last_frame
        };
        ensure!(
            recovery_frame != 0
                && if confirmation.rejection.is_some_and(
                    |r| r.kind == crate::atlas_input_recovery::InputRejectionKind::Cancel
                ) {
                    confirmation.atlas_frame <= recovery_frame
                } else {
                    confirmation.atlas_frame == recovery_frame
                }
                && confirmation.sequence > self.last_recovery,
            "atlas recovery frame mismatch or replay"
        );
        let record = confirmation.encode()?;
        let local_before = Instant::now();
        let (sent, frequency) = clock()?;
        ensure!(
            sent > 0
                && sent < confirmation.deadline_qpc
                && frequency == confirmation.frequency
                && Instant::now() < deadline,
            "atlas recovery expired before write or clock mismatch"
        );
        let remaining_ns =
            u128::from(confirmation.deadline_qpc - sent) * 1_000_000_000 / u128::from(frequency);
        let budget = std::time::Duration::from_nanos(u64::try_from(remaining_ns)?);
        ensure!(
            !budget.is_zero(),
            "atlas recovery has no complete clock budget"
        );
        let deadline = deadline.min(
            local_before
                .checked_add(budget)
                .context("atlas recovery deadline overflow")?,
        );
        let line = timeout_at(deadline, async {
            io.0.write_all(&record).await?;
            io.0.flush().await?;
            read_line_bounded(&mut io.1, 1024).await
        })
        .await
        .context("atlas recovery transaction deadline expired")??;
        let (observed, frequency) = clock()?;
        ensure!(
            Instant::now() < deadline
                && frequency == confirmation.frequency
                && observed < confirmation.deadline_qpc,
            "atlas recovery receipt expired or clock mismatch"
        );
        let recovered = confirmation.validate_receipt(&line, sent, observed)?;
        self.last_recovery = confirmation.sequence;
        self.io = Some(io);
        self.poisoned = false;
        Ok(recovered)
    }

    /// # Errors
    /// Requires the atlas-specific ready line. Any failure/cancellation poisons
    /// this pipe; its owning child must be retired rather than retried.
    pub async fn wait_ready(&mut self, deadline: Instant) -> Result<()> {
        ensure!(
            !self.ready && !self.poisoned,
            "atlas presenter is already ready or retired"
        );
        self.poisoned = true;
        let mut io = self
            .io
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas pipe missing"))?;
        let line = timeout_at(deadline, read_line(&mut io.1)).await??;
        ensure!(
            line == if self.input_mode == NativeInputMode::RecoverableDesktop {
                "atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1 desktop=v1 move_mode=win"
            } else if self.input_mode == NativeInputMode::RecoverableKeyboard {
                "atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1"
            } else if self.input_mode == NativeInputMode::DirectKeyboard {
                "atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1"
            } else if self.input_mode == NativeInputMode::PointerWheel {
                "atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1"
            } else if self.input_mode == NativeInputMode::Pointer {
                "atlas-native-ready disposition=v1 input_enabled=true pointer=v1"
            } else if self.receipt_mode == ReceiptMode::Legacy {
                "atlas-native-ready input_enabled=false"
            } else {
                "atlas-native-ready disposition=v1 input_enabled=false"
            },
            "unexpected atlas presenter readiness"
        );
        ensure!(
            Instant::now() < deadline,
            "atlas readiness deadline expired"
        );
        self.ready = true;
        self.io = Some(io);
        self.poisoned = false;
        Ok(())
    }

    /// Submit exactly three startup-only records, each followed by its own
    /// unbound-copy completion. IDs 1..3 belong to the warmup namespace, not the
    /// live atlas frame namespace. No visual-submission result is produced.
    /// # Errors
    /// Rejects repeat/late warmup, shape drift, invalid records or expiry. Any
    /// failure closes the pipe, including partially completed startup sequences.
    pub async fn warmup(
        &mut self,
        frames: &[AtlasWarmupFrame; 3],
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<()> {
        ensure!(
            self.ready && !self.poisoned && self.last_frame == 0 && self.warmup_shape.is_none(),
            "atlas startup warmup is unavailable"
        );
        self.poisoned = true;
        let mut io = self
            .io
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas pipe missing"))?;
        let shape = (frames[0].width, frames[0].height);
        for (index, frame) in frames.iter().enumerate() {
            ensure!(
                (frame.width, frame.height) == shape,
                "atlas warmup geometry changed"
            );
            let identity = u64::try_from(index)? + 1;
            let record = crate::gpu_presenter_pipe::encode_compressed_alpha_decode_only_record(
                identity,
                frame.width,
                frame.height,
                &frame.color,
                &frame.alpha,
                max_record_bytes,
            )?;
            ensure!(Instant::now() < deadline, "atlas warmup deadline expired");
            let line = timeout_at(deadline, async {
                io.0.write_all(&record).await?;
                io.0.flush().await?;
                read_line(&mut io.1).await
            })
            .await??;
            ensure!(
                line == format!(
                    "atlas-warmup-completed identity={identity} width={} height={}",
                    frame.width, frame.height
                ),
                "atlas warmup completion mismatch"
            );
        }
        ensure!(Instant::now() < deadline, "atlas warmup completion expired");
        self.warmup_shape = Some(shape);
        self.io = Some(io);
        self.poisoned = false;
        Ok(())
    }

    /// # Errors
    /// An exact visual-submission response must arrive under the caller's
    /// original source deadline. Errors/cancellation permanently poison the
    /// pipe, including partially written records and partly read responses.
    pub async fn submit(
        &mut self,
        frame: &AdmittedAtlas,
        native_deadline: NativePresentationDeadline,
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<AtlasVisualSubmission> {
        ensure!(
            self.receipt_mode == ReceiptMode::Legacy,
            "legacy submission on disposition pipe"
        );
        ensure!(
            self.ready && !self.poisoned,
            "atlas presenter is not ready or retired"
        );
        ensure!(
            frame.layout.frame_id > self.last_frame,
            "atlas presenter frame replay"
        );
        // AdmittedAtlas already passed negotiated capacity, layout revision,
        // and paired-keyframe checks. Warmup dimensions only describe startup;
        // the native decoder may rebuild for an admitted canvas growth.
        ensure!(
            frame.layout.desktop.is_some()
                == (self.input_mode == NativeInputMode::RecoverableDesktop),
            "atlas desktop layout capability mismatch"
        );
        self.poisoned = true;
        let mut io = self
            .io
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas pipe missing"))?;
        let record = encode_atlas_record(frame, native_deadline, max_record_bytes)?;
        ensure!(
            Instant::now() < deadline,
            "atlas source deadline expired before pipe write"
        );
        let result = timeout_at(deadline, async {
            io.0.write_all(&record).await?;
            io.0.flush().await?;
            submission(&read_line(&mut io.1).await?)
        })
        .await??;
        ensure!(
            Instant::now() < deadline,
            "atlas source deadline expired during submission"
        );
        ensure!(
            result.frame_id == frame.layout.frame_id
                && result.tile_count == frame.layout.tiles.len(),
            "atlas native submission does not match the admitted frame"
        );
        self.last_frame = result.frame_id;
        self.last_committed_frame = result.frame_id;
        self.io = Some(io);
        self.poisoned = false;
        Ok(result)
    }

    /// Submit with a separately bounded disposition receipt interval. `clock`
    /// must sample the native child's same-host QPC counter and frequency.
    /// A late receipt never grants fresh-input or physical-scanout authority.
    ///
    /// # Errors
    /// Failure or cancellation retires the pipe, including incomplete writes.
    /// An expired-unbound result requires a fresh paired IDR before reuse.
    pub async fn submit_disposition(
        &mut self,
        frame: &AdmittedAtlas,
        native_deadline: NativePresentationDeadline,
        deadline: Instant,
        max_record_bytes: usize,
        mut clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<AtlasDisposition> {
        ensure!(
            self.receipt_mode != ReceiptMode::Legacy && self.ready && !self.poisoned,
            "disposition presenter is not ready or retired"
        );
        ensure!(
            frame.layout.frame_id > self.last_frame,
            "atlas presenter frame replay"
        );
        ensure!(
            self.receipt_mode != ReceiptMode::DispositionNeedsKeyframe
                || (frame.layout.color_keyframe && frame.layout.alpha_keyframe),
            "expired atlas requires fresh paired keyframe"
        );
        // AdmittedAtlas already passed negotiated capacity, layout revision,
        // and paired-keyframe checks. Warmup dimensions only describe startup;
        // the native decoder may rebuild for an admitted canvas growth.
        ensure!(
            frame.layout.desktop.is_some()
                == (self.input_mode == NativeInputMode::RecoverableDesktop),
            "atlas desktop layout capability mismatch"
        );
        self.poisoned = true;
        let mut io = self
            .io
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas pipe missing"))?;
        let encode_started = Instant::now();
        let record = encode_atlas_record(frame, native_deadline, max_record_bytes)?;
        let record_encoded = Instant::now();
        let (start, frequency) = clock()?;
        ensure!(
            frequency != 0 && frequency == native_deadline.frequency,
            "atlas disposition clock frequency mismatch"
        );
        // No byte has been written for this exact identity. Unlike an expired
        // partial write, this is a local proof of unbound disposition. Require
        // a fresh paired IDR because the native decoder never saw this frame.
        if Instant::now() >= deadline {
            self.last_frame = frame.layout.frame_id;
            self.receipt_mode = ReceiptMode::DispositionNeedsKeyframe;
            self.io = Some(io);
            self.poisoned = false;
            return Ok(AtlasDisposition::ExpiredUnbound);
        }
        timeout_at(deadline, async {
            io.0.write_all(&record).await?;
            io.0.flush().await
        })
        .await
        .context("atlas disposition pipe write deadline expired")?
        .context("atlas disposition pipe write failed")?;
        // A completed write may resume after the deadline. Its exact native
        // disposition can still prove an on-time commit or an unbound expiry.
        // A partial/timed-out write above remains terminal; neither this grace
        // nor the receipt can extend the native frame's original QPC deadline.
        let record_written = Instant::now();
        let receipt_deadline = deadline + std::time::Duration::from_millis(100);
        let line = timeout_at(receipt_deadline, read_line_bounded(&mut io.1, 320))
            .await
            .context("atlas disposition receipt deadline expired")?
            .context("atlas disposition receipt read failed")?;
        let (receipt, frequency) = clock()?;
        ensure!(
            Instant::now() < receipt_deadline && frequency == native_deadline.frequency,
            "atlas disposition receipt expired or clock changed"
        );
        let result = AtlasDisposition::parse(
            &line,
            frame.layout.frame_id,
            frame.layout.tiles.len(),
            start,
            receipt,
            native_deadline,
        )?;
        if frame.layout.frame_id % 60 == 0 {
            use std::io::Write;
            let line = format!(
                "atlas-receiver-timing frame={} record_bytes={} color_bytes={} alpha_bytes={} record_us={} write_us={} receipt_us={}\n",
                frame.layout.frame_id,
                record.len(),
                frame.media.color.len(),
                frame.media.alpha.as_ref().map_or(0, |a| a.len()),
                record_encoded.duration_since(encode_started).as_micros(),
                record_written.duration_since(record_encoded).as_micros(),
                Instant::now().duration_since(record_written).as_micros()
            );
            let _ = std::io::stderr().lock().write_all(line.as_bytes());
        }
        self.last_frame = frame.layout.frame_id;
        self.receipt_mode = if result == AtlasDisposition::ExpiredUnbound {
            ReceiptMode::DispositionNeedsKeyframe
        } else {
            self.last_committed_frame = frame.layout.frame_id;
            ReceiptMode::Disposition
        };
        self.io = Some(io);
        self.poisoned = false;
        Ok(result)
    }
}

async fn read_line(reader: &mut (impl AsyncRead + Unpin)) -> Result<String> {
    read_line_bounded(reader, 160).await
}

pub(crate) async fn read_line_bounded(
    reader: &mut (impl AsyncRead + Unpin),
    limit: usize,
) -> Result<String> {
    let mut bytes = Vec::new();
    loop {
        let byte = reader.read_u8().await?;
        if byte == b'\n' {
            break;
        }
        ensure!(
            bytes.len() < limit,
            "atlas native response line limit exceeded"
        );
        bytes.push(byte);
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    Ok(String::from_utf8(bytes)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    const RECOVERY_READY: &[u8] = b"atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1\n";
    const DESKTOP_READY: &[u8] = b"atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1 desktop=v1 move_mode=win\n";
    const RECOVERY_RECEIPT: &[u8] = b"atlas-input-recovered-v1 sequence=1 stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 previous_epoch=6 geometry_epoch=7 grant_generation=8 atlas_frame=9 source_frame=10 placement_generation=11 deadline_qpc=120 frequency=1000 recovered_qpc=110\n";
    fn recovery_control() -> crate::atlas_input_recovery::InputRecoveryConfirmation {
        crate::atlas_input_recovery::InputRecoveryConfirmation {
            rejection: None,
            sequence: 1,
            stream: 2,
            window: 3,
            atlas_epoch: 4,
            config_generation: 5,
            previous_epoch: 6,
            geometry_epoch: 7,
            grant_generation: 8,
            atlas_frame: 9,
            source_frame: 10,
            placement_generation: 11,
            deadline_qpc: 120,
            frequency: 1000,
        }
    }
    #[tokio::test]
    async fn recovery_readiness_is_exact_and_never_silently_upgrades_or_downgrades() {
        for recovery in [false, true] {
            let (client, mut native) = tokio::io::duplex(2048);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = if recovery {
                AtlasPresenterPipe::with_input_recovery(writer, reader)
            } else {
                AtlasPresenterPipe::with_keyboard_events(writer, reader)
            };
            native.write_all(if recovery {
                b"atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1\n"
            } else { RECOVERY_READY }).await.unwrap();
            assert!(
                pipe.wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                    .await
                    .is_err()
            );
            assert!(pipe.poisoned && pipe.io.is_none());
        }
    }

    #[tokio::test]
    async fn desktop_readiness_is_exact_and_never_downgrades_to_recovery() {
        let legacy_f8: &[u8] = b"atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1 desktop=v1 move_mode=f8\n";
        for ready in [RECOVERY_READY, legacy_f8, DESKTOP_READY] {
            let (client, mut native) = tokio::io::duplex(2048);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = AtlasPresenterPipe::with_desktop(writer, reader);
            native.write_all(ready).await.unwrap();
            let result = pipe
                .wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                .await;
            assert_eq!(result.is_ok(), ready == DESKTOP_READY);
            if ready != DESKTOP_READY {
                assert!(pipe.poisoned && pipe.io.is_none());
            }
        }
    }

    #[tokio::test]
    async fn recovery_transaction_requires_exact_receipt_and_preserves_picture_floor() {
        let (client, mut native) = tokio::io::duplex(2048);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
        native.write_all(RECOVERY_READY).await.unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        pipe.wait_ready(deadline).await.unwrap();
        // Isolate the control transaction after an already committed picture.
        pipe.last_frame = 9;
        native.write_all(RECOVERY_RECEIPT).await.unwrap();
        let mut samples = [(100, 1000), (115, 1000)].into_iter();
        assert_eq!(
            pipe.recover_input(recovery_control(), deadline, || Ok(samples.next().unwrap()))
                .await
                .unwrap(),
            110
        );
        let mut actual = [0; 152];
        native.read_exact(&mut actual).await.unwrap();
        assert_eq!(actual.as_slice(), recovery_control().encode().unwrap());
        assert_eq!(pipe.last_frame, 9);
        assert_eq!(pipe.last_recovery, 1);
        assert!(!pipe.poisoned);
        assert!(
            pipe.recover_input(recovery_control(), deadline, || Ok((115, 1000)))
                .await
                .is_err()
        );
        assert!(pipe.poisoned && pipe.io.is_none());
    }
    #[tokio::test]
    async fn recovery_failures_close_the_pipe_without_retry() {
        for case in 0..8 {
            let (client, mut native) = tokio::io::duplex(2048);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
            native.write_all(RECOVERY_READY).await.unwrap();
            let deadline = Instant::now() + std::time::Duration::from_secs(1);
            pipe.wait_ready(deadline).await.unwrap();
            pipe.last_frame = 9;
            match case {
                0 => pipe.last_frame = 8,
                1 => pipe.receipt_mode = ReceiptMode::DispositionNeedsKeyframe,
                2 => pipe.input_mode = NativeInputMode::DirectKeyboard,
                _ => (),
            }
            let receipt = if case == 6 {
                b"atlas-disposition-v1 frame_identity=9\n".as_slice()
            } else {
                RECOVERY_RECEIPT
            };
            native.write_all(receipt).await.unwrap();
            let mut calls = 0;
            let result = pipe
                .recover_input(recovery_control(), deadline, || {
                    calls += 1;
                    Ok(match (case, calls) {
                        (3, 1) => (120, 1000),
                        (4, 1) => (100, 999),
                        (5, 2) => (120, 1000),
                        (7, 2) => (115, 999),
                        (_, 1) => (100, 1000),
                        _ => (115, 1000),
                    })
                })
                .await;
            assert!(result.is_err(), "case {case}");
            assert!(pipe.poisoned && pipe.io.is_none());
            let mut emitted = Vec::new();
            native.read_to_end(&mut emitted).await.unwrap();
            assert_eq!(emitted.len(), if case <= 4 { 0 } else { 152 });
        }
    }
    #[tokio::test]
    async fn recovery_partial_write_and_cancel_drop_native_io() {
        for cancelled in [false, true] {
            let (writer, mut native_bytes) = tokio::io::duplex(1);
            let (reader, mut native_receipts) = tokio::io::duplex(1024);
            let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
            native_receipts.write_all(RECOVERY_READY).await.unwrap();
            pipe.wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                .await
                .unwrap();
            pipe.last_frame = 9;
            let deadline = Instant::now()
                + std::time::Duration::from_millis(if cancelled { 1000 } else { 10 });
            if cancelled {
                let mut pending =
                    Box::pin(pipe.recover_input(recovery_control(), deadline, || Ok((100, 1000))));
                tokio::select! {
                    _ = &mut pending => panic!("partial write completed unexpectedly"),
                    _ = tokio::time::sleep(std::time::Duration::from_millis(10)) => (),
                }
                drop(pending);
            } else {
                assert!(
                    pipe.recover_input(recovery_control(), deadline, || Ok((100, 1000)))
                        .await
                        .is_err()
                );
            }
            assert!(pipe.poisoned && pipe.io.is_none());
            let mut partial = Vec::new();
            native_bytes.read_to_end(&mut partial).await.unwrap();
            assert_eq!(partial, b"V");
        }
    }

    #[tokio::test]
    async fn wheel_readiness_requires_exact_capability_without_fallback() {
        let pointer = "atlas-native-ready disposition=v1 input_enabled=true pointer=v1";
        let wheel = format!("{pointer} wheel=v1");
        for enabled in [false, true] {
            for ready in [pointer, wheel.as_str()] {
                let (writer, _read) = tokio::io::duplex(1024);
                let reader = std::io::Cursor::new(format!("{ready}\n").into_bytes());
                let mut pipe = if enabled {
                    AtlasPresenterPipe::with_wheel_events(writer, reader)
                } else {
                    AtlasPresenterPipe::with_pointer_events(writer, reader)
                };
                let result = pipe
                    .wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                    .await;
                assert_eq!(result.is_ok(), enabled == (ready == wheel));
                if result.is_err() {
                    assert!(pipe.poisoned);
                    assert!(pipe.io.is_none());
                }
            }
        }
    }

    #[tokio::test]
    async fn keyboard_readiness_requires_exact_capability_without_fallback() {
        let base = "atlas-native-ready disposition=v1 input_enabled=true pointer=v1";
        for suffix in [
            "",
            " wheel=v1",
            " keyboard=v1",
            " wheel=v1 keyboard=v1",
            " wheel=v1 keyboard=v2",
        ] {
            let (writer, _read) = tokio::io::duplex(1024);
            let reader = std::io::Cursor::new(format!("{base}{suffix}\n").into_bytes());
            let mut pipe = AtlasPresenterPipe::with_keyboard_events(writer, reader);
            let result = pipe
                .wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                .await;
            assert_eq!(result.is_ok(), suffix == " wheel=v1 keyboard=v1");
            if result.is_err() {
                assert!(pipe.poisoned && pipe.io.is_none());
            }
        }
    }

    fn test_frame() -> AdmittedAtlas {
        use viewflow_protocol::{AtlasFrame, FrameManifest, Id128};
        AdmittedAtlas {
            layout: AtlasFrame {
            patches: None,
                stream_id: Id128(99),
                frame_id: 1,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 2,
                height: 2,
                source_submitted_ns: 100,
                tiles: vec![],
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
            },
            media: crate::media_runtime::EncodedFrame {
                manifest: FrameManifest {
                    window_id: Id128(99),
                    frame_id: 1,
                    geometry_epoch: 1,
                    source_submitted_ns: 100,
                    received_ns: 110,
                },
                color: bytes::Bytes::from_static(&[0, 0, 1, 0x65]),
                alpha: Some(viewflow_transport::encode_alpha_rle(2, 2, &[7; 4]).unwrap()),
            },
        }
    }

    #[tokio::test]
    async fn late_commit_keeps_pipe_and_decode_reference_for_next_frame() {
        let (client, mut native) = tokio::io::duplex(4096);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
        native
            .write_all(b"atlas-native-ready disposition=v1 input_enabled=false\n")
            .await
            .unwrap();
        let watchdog = Instant::now() + std::time::Duration::from_secs(1);
        pipe.wait_ready(watchdog).await.unwrap();
        let mut frame = test_frame();
        for id in 1..=2 {
            frame.layout.frame_id = id;
            frame.media.manifest.frame_id = id;
            frame.layout.color_keyframe = id == 1;
            frame.layout.alpha_keyframe = id == 1;
            let target = id * 200;
            native.write_all(format!("atlas-disposition-v1 frame_identity={id} tile_count=0 outcome=committed deadline_ticks={target} frequency=1000 commit_ticks={} physical_present_receipt=false\n", target + 50).as_bytes()).await.unwrap();
            let mut clock =
                [if id == 1 { target - 100 } else { target + 1 }, target + 60].into_iter();
            assert_eq!(
                pipe.submit_disposition(
                    &frame,
                    NativePresentationDeadline {
                        ticks: target,
                        frequency: 1000
                    },
                    watchdog,
                    4096,
                    || Ok((clock.next().unwrap(), 1000))
                )
                .await
                .unwrap(),
                AtlasDisposition::CommittedLate {
                    commit_ticks: target + 50
                }
            );
            assert!(!pipe.poisoned);
            assert_eq!(pipe.last_committed_frame, id);
            assert!(pipe.receipt_mode == ReceiptMode::Disposition);
        }
    }

    #[tokio::test]
    async fn disposition_handoff_requires_negotiation_and_recovers_exact_expiry() {
        let (client, mut native) = tokio::io::duplex(4096);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
        native
            .write_all(b"atlas-native-ready disposition=v1 input_enabled=false\n")
            .await
            .unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        pipe.wait_ready(deadline).await.unwrap();
        let mut frame = test_frame();
        let native_deadline = NativePresentationDeadline {
            ticks: 200,
            frequency: 1000,
        };
        native.write_all(b"atlas-disposition-v1 frame_identity=1 tile_count=0 outcome=expired-unbound deadline_ticks=200 frequency=1000 commit_ticks=0 physical_present_receipt=false\n").await.unwrap();
        let mut ticks = [100, 250].into_iter();
        assert_eq!(
            pipe.submit_disposition(&frame, native_deadline, deadline, 4096, || Ok((
                ticks.next().unwrap(),
                1000
            )))
            .await
            .unwrap(),
            AtlasDisposition::ExpiredUnbound
        );
        assert!(pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe && !pipe.poisoned);
        assert!(
            pipe.submit(&frame, native_deadline, deadline, 4096)
                .await
                .is_err()
        );
        frame.layout.frame_id = 2;
        frame.media.manifest.frame_id = 2;
        frame.layout.color_keyframe = false;
        assert!(
            pipe.submit_disposition(&frame, native_deadline, deadline, 4096, || Ok((100, 1000)))
                .await
                .is_err()
        );
        frame.layout.color_keyframe = true;
        native.write_all(b"atlas-disposition-v1 frame_identity=2 tile_count=0 outcome=committed deadline_ticks=200 frequency=1000 commit_ticks=199 physical_present_receipt=false\n").await.unwrap();
        let mut ticks = [100, 250].into_iter();
        assert_eq!(
            pipe.submit_disposition(&frame, native_deadline, deadline, 4096, || Ok((
                ticks.next().unwrap(),
                1000
            )))
            .await
            .unwrap(),
            AtlasDisposition::CommittedWithinDeadline { commit_ticks: 199 }
        );
        assert!(pipe.receipt_mode == ReceiptMode::Disposition && !pipe.poisoned);
    }

    #[tokio::test]
    async fn disposition_does_not_fall_back_to_legacy_readiness() {
        let (client, mut native) = tokio::io::duplex(256);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
        native
            .write_all(b"atlas-native-ready input_enabled=false\n")
            .await
            .unwrap();
        assert!(
            pipe.wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                .await
                .is_err()
        );
        assert!(pipe.poisoned && pipe.io.is_none());
    }

    #[tokio::test]
    async fn disposition_failure_and_cancel_retire_pipe() {
        for response in [
            "atlas-submitted frame_identity=1 tile_count=0 physical_present_receipt=false\n",
            "atlas-disposition-v1 frame_identity=2 tile_count=0 outcome=committed deadline_ticks=200 frequency=1000 commit_ticks=199 physical_present_receipt=false\n",
            "",
        ] {
            let (client, mut native) = tokio::io::duplex(4096);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
            native
                .write_all(b"atlas-native-ready disposition=v1 input_enabled=false\n")
                .await
                .unwrap();
            let deadline = Instant::now() + std::time::Duration::from_secs(1);
            pipe.wait_ready(deadline).await.unwrap();
            native.write_all(response.as_bytes()).await.unwrap();
            let mut ticks = [100, 250].into_iter();
            let result = tokio::time::timeout(
                std::time::Duration::from_millis(10),
                pipe.submit_disposition(
                    &test_frame(),
                    NativePresentationDeadline {
                        ticks: 200,
                        frequency: 1000,
                    },
                    deadline,
                    4096,
                    || Ok((ticks.next().unwrap(), 1000)),
                ),
            )
            .await;
            assert!(result.is_err() || result.unwrap().is_err());
            assert!(pipe.poisoned && pipe.io.is_none());
        }
    }

    #[tokio::test]
    async fn completed_write_resumption_uses_exact_native_disposition() {
        struct DelayedFlush(Vec<u8>);
        impl tokio::io::AsyncWrite for DelayedFlush {
            fn poll_write(
                mut self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
                bytes: &[u8],
            ) -> std::task::Poll<std::io::Result<usize>> {
                self.0.extend_from_slice(bytes);
                std::task::Poll::Ready(Ok(bytes.len()))
            }
            fn poll_flush(
                self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
            ) -> std::task::Poll<std::io::Result<()>> {
                // Model a completed write whose poll returns after scheduling
                // delay. All bytes are present; this is not a partial write.
                std::thread::sleep(std::time::Duration::from_millis(20));
                std::task::Poll::Ready(Ok(()))
            }
            fn poll_shutdown(
                self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
            ) -> std::task::Poll<std::io::Result<()>> {
                std::task::Poll::Ready(Ok(()))
            }
        }
        for (outcome, commit_ticks, accepted) in [
            ("committed", 199, true),
            ("expired-unbound", 0, true),
            ("committed", 200, true),
        ] {
            let response = format!(
                "atlas-native-ready disposition=v1 input_enabled=false\natlas-disposition-v1 frame_identity=1 tile_count=0 outcome={outcome} deadline_ticks=200 frequency=1000 commit_ticks={commit_ticks} physical_present_receipt=false\n"
            );
            let mut pipe = AtlasPresenterPipe::with_dispositions(
                DelayedFlush(Vec::new()),
                response.as_bytes(),
            );
            pipe.wait_ready(Instant::now() + std::time::Duration::from_secs(1))
                .await
                .unwrap();
            let mut ticks = [100, 250].into_iter();
            let result = pipe
                .submit_disposition(
                    &test_frame(),
                    NativePresentationDeadline {
                        ticks: 200,
                        frequency: 1000,
                    },
                    Instant::now() + std::time::Duration::from_millis(10),
                    4096,
                    || Ok((ticks.next().unwrap(), 1000)),
                )
                .await;
            assert_eq!(result.is_ok(), accepted, "{result:?}");
            if accepted {
                assert!(!pipe.poisoned);
                assert!(!pipe.io.as_ref().unwrap().0.0.is_empty());
            } else {
                assert!(pipe.poisoned && pipe.io.is_none());
            }
        }
    }

    #[tokio::test]
    async fn disposition_partial_write_cannot_use_receipt_grace() {
        let (client, mut native) = tokio::io::duplex(64);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
        native
            .write_all(b"atlas-native-ready disposition=v1 input_enabled=false\n")
            .await
            .unwrap();
        pipe.wait_ready(Instant::now() + std::time::Duration::from_secs(1))
            .await
            .unwrap();
        // The native end never drains the record, so only a partial write fits.
        assert!(
            pipe.submit_disposition(
                &test_frame(),
                NativePresentationDeadline {
                    ticks: 200,
                    frequency: 1000
                },
                Instant::now() + std::time::Duration::from_millis(10),
                4096,
                || Ok((100, 1000))
            )
            .await
            .is_err()
        );
        assert!(pipe.poisoned && pipe.io.is_none());
    }

    #[tokio::test]
    async fn disposition_prewrite_expiry_writes_no_native_bytes() {
        let (client, mut native) = tokio::io::duplex(256);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_dispositions(writer, reader);
        native
            .write_all(b"atlas-native-ready disposition=v1 input_enabled=false\n")
            .await
            .unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        pipe.wait_ready(deadline).await.unwrap();
        let result = pipe
            .submit_disposition(
                &test_frame(),
                NativePresentationDeadline {
                    ticks: 200,
                    frequency: 1000,
                },
                Instant::now(),
                4096,
                || Ok((200, 1000)),
            )
            .await
            .unwrap();
        assert_eq!(result, AtlasDisposition::ExpiredUnbound);
        assert!(pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe && !pipe.poisoned);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(1), native.read_u8())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn warmed_pipe_accepts_growing_admitted_frames_in_both_receipt_modes() {
        for dispositions in [false, true] {
            let (client, mut native) = tokio::io::duplex(4096);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = if dispositions {
                AtlasPresenterPipe::with_dispositions(writer, reader)
            } else {
                AtlasPresenterPipe::new(writer, reader)
            };
            let deadline = Instant::now() + std::time::Duration::from_secs(10);
            let native_side = async {
                let ready = if dispositions {
                    "atlas-native-ready disposition=v1 input_enabled=false\n"
                } else {
                    "atlas-native-ready input_enabled=false\n"
                };
                native.write_all(ready.as_bytes()).await.unwrap();
                for identity in 1..=3 {
                    let mut header = [0; 40];
                    native.read_exact(&mut header).await.unwrap();
                    let count = u32::from_be_bytes(header[12..16].try_into().unwrap());
                    let mut payload = vec![0; count as usize];
                    native.read_exact(&mut payload).await.unwrap();
                    native.write_all(format!("atlas-warmup-completed identity={identity} width=1024 height=1024\n").as_bytes()).await.unwrap();
                }
                for identity in 1..=3 {
                    let mut header = [0; 112];
                    native.read_exact(&mut header).await.unwrap();
                    assert_eq!(header[4], 5);
                    let count = u32::from_be_bytes(header[12..16].try_into().unwrap());
                    let mut payload = vec![0; count as usize];
                    native.read_exact(&mut payload).await.unwrap();
                    let response = if dispositions {
                        format!(
                            "atlas-disposition-v1 frame_identity={identity} tile_count=0 outcome=committed deadline_ticks=200 frequency=1000 commit_ticks=199 physical_present_receipt=false\n"
                        )
                    } else {
                        format!(
                            "atlas-submitted frame_identity={identity} tile_count=0 physical_present_receipt=false\n"
                        )
                    };
                    native.write_all(response.as_bytes()).await.unwrap();
                }
            };
            let rust_side = async {
                pipe.wait_ready(deadline).await.unwrap();
                let warmup = AtlasWarmupFrame {
                    width: 1024,
                    height: 1024,
                    color: test_frame().media.color,
                    alpha: viewflow_transport::encode_alpha_rle(1024, 1024, &vec![0; 1024 * 1024])
                        .unwrap(),
                };
                pipe.warmup(&[warmup.clone(), warmup.clone(), warmup], deadline, 128 << 20)
                    .await
                    .unwrap();
                for (index, (width, height)) in [(1024, 1024), (2048, 2048), (8192, 4096)]
                    .into_iter()
                    .enumerate()
                {
                    let mut frame = test_frame();
                    frame.layout.frame_id = index as u64 + 1;
                    frame.media.manifest.frame_id = frame.layout.frame_id;
                    frame.layout.layout_revision = index as u64;
                    frame.layout.width = width;
                    frame.layout.height = height;
                    frame.media.alpha = Some(
                        viewflow_transport::encode_alpha_rle(
                            width,
                            height,
                            &vec![0; (width * height) as usize],
                        )
                        .unwrap(),
                    );
                    let native_deadline = NativePresentationDeadline {
                        ticks: 200,
                        frequency: 1000,
                    };
                    if dispositions {
                        let mut ticks = [100, 250].into_iter();
                        assert_eq!(
                            pipe.submit_disposition(
                                &frame,
                                native_deadline,
                                deadline,
                                128 << 20,
                                || Ok((ticks.next().unwrap(), 1000))
                            )
                            .await
                            .unwrap(),
                            AtlasDisposition::CommittedWithinDeadline { commit_ticks: 199 }
                        );
                    } else {
                        pipe.submit(&frame, native_deadline, deadline, 128 << 20)
                            .await
                            .unwrap();
                    }
                }
                assert!(!pipe.poisoned);
                assert_eq!(pipe.last_committed_frame, 3);
            };
            tokio::join!(native_side, rust_side);
        }
    }

    #[tokio::test]
    async fn duplex_handoff_matches_atlas_frame_not_physical_receipt() {
        let frame = test_frame();
        let (client, mut native) = tokio::io::duplex(16);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::new(writer, reader);
        let deadline = Instant::now() + std::time::Duration::from_secs(2);
        let native_side = async {
            native
                .write_all(b"atlas-native-ready input_enabled=false\r\n")
                .await
                .unwrap();
            for identity in 1_u64..=3 {
                let mut header = [0; 40];
                native.read_exact(&mut header).await.unwrap();
                assert_eq!(header[4], 3);
                assert_eq!(&header[16..24], &identity.to_be_bytes());
                let count = u32::from_be_bytes(header[12..16].try_into().unwrap());
                let mut payload = vec![0; count as usize];
                native.read_exact(&mut payload).await.unwrap();
                native
                    .write_all(
                        format!("atlas-warmup-completed identity={identity} width=2 height=2\n")
                            .as_bytes(),
                    )
                    .await
                    .unwrap();
            }
            let mut header = [0; 112];
            native.read_exact(&mut header).await.unwrap();
            assert_eq!(header[4], 5);
            assert_eq!(&header[40..48], &1000_u64.to_be_bytes());
            let count = u32::from_be_bytes(header[12..16].try_into().unwrap());
            let mut payload = vec![0; count as usize];
            native.read_exact(&mut payload).await.unwrap();
            native.write_all(b"atlas-submitted frame_identity=1 tile_count=0 physical_present_receipt=false\n").await.unwrap();
        };
        let rust_side = async {
            pipe.wait_ready(deadline).await.unwrap();
            let warmup = AtlasWarmupFrame {
                width: 2,
                height: 2,
                color: frame.media.color.clone(),
                alpha: frame.media.alpha.clone().unwrap(),
            };
            let frames = [warmup.clone(), warmup.clone(), warmup];
            pipe.warmup(&frames, deadline, 4096).await.unwrap();
            assert!(pipe.warmup(&frames, deadline, 4096).await.is_err());
            pipe.submit(
                &frame,
                NativePresentationDeadline {
                    ticks: 1000,
                    frequency: 10_000_000,
                },
                deadline,
                4096,
            )
            .await
            .unwrap()
        };
        let (_, submitted) = tokio::time::timeout(std::time::Duration::from_secs(3), async {
            tokio::join!(native_side, rust_side)
        })
        .await
        .unwrap();
        assert_eq!(
            submitted,
            AtlasVisualSubmission {
                frame_id: 1,
                tile_count: 0
            }
        );
    }

    #[test]
    fn visual_submission_never_accepts_physical_or_legacy_ack() {
        assert_eq!(
            submission(
                "atlas-submitted frame_identity=9 tile_count=2 physical_present_receipt=false"
            )
            .unwrap(),
            AtlasVisualSubmission {
                frame_id: 9,
                tile_count: 2
            }
        );
        for line in [
            "submitted frame_identity=9 submitted_frames=1 width=4 height=2",
            "atlas-submitted frame_identity=9 tile_count=2 physical_present_receipt=true",
            "atlas-submitted frame_identity=0 tile_count=2 physical_present_receipt=false",
            "atlas-submitted frame_identity=9 tile_count=4097 physical_present_receipt=false",
        ] {
            assert!(submission(line).is_err());
        }
    }
    #[tokio::test]
    async fn cancelled_readiness_retires_partial_reader() {
        let (reader, mut native) = tokio::io::duplex(256);
        let mut pipe = AtlasPresenterPipe::new(tokio::io::sink(), reader);
        native.write_all(b"atlas-native-ready ").await.unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(10),
                pipe.wait_ready(deadline)
            )
            .await
            .is_err()
        );
        assert!(native.write_all(b"input_enabled=false\n").await.is_err());
        assert!(pipe.wait_ready(deadline).await.is_err());
    }
    #[tokio::test]
    async fn rejected_recovery_preserves_expired_gap_and_requires_next_paired_keyframe() {
        use crate::atlas_input_recovery::{InputRejectionControl, InputRejectionKind};
        // Both local prewrite expiry and a native unbound receipt leave the
        // same reference gap. Neither makes frame 10 a visible recovery target.
        for local_expiry in [false, true] {
            let (client, mut native) = tokio::io::duplex(4096);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
            native.write_all(RECOVERY_READY).await.unwrap();
            let deadline = Instant::now() + std::time::Duration::from_secs(1);
            pipe.wait_ready(deadline).await.unwrap();
            let mut frame = test_frame();
            frame.layout.frame_id = 9;
            frame.media.manifest.frame_id = 9;
            let native_deadline = NativePresentationDeadline {
                ticks: 500,
                frequency: 1000,
            };
            native.write_all(b"atlas-disposition-v1 frame_identity=9 tile_count=0 outcome=committed deadline_ticks=500 frequency=1000 commit_ticks=140 physical_present_receipt=false\n").await.unwrap();
            let mut ticks = [100, 150].into_iter();
            assert_eq!(
                pipe.submit_disposition(
                    &frame,
                    native_deadline,
                    if local_expiry && frame.layout.frame_id == 10 {
                        Instant::now()
                    } else {
                        deadline
                    },
                    4096,
                    || Ok((ticks.next().unwrap(), 1000))
                )
                .await
                .unwrap(),
                AtlasDisposition::CommittedWithinDeadline { commit_ticks: 140 }
            );
            assert_eq!(pipe.last_committed_frame, 9);
            frame.layout.frame_id = 10;
            frame.media.manifest.frame_id = 10;
            if !local_expiry {
                native.write_all(b"atlas-disposition-v1 frame_identity=10 tile_count=0 outcome=expired-unbound deadline_ticks=500 frequency=1000 commit_ticks=0 physical_present_receipt=false\n").await.unwrap();
            }
            let mut ticks = if local_expiry { [500, 510] } else { [200, 510] }.into_iter();
            assert_eq!(
                pipe.submit_disposition(
                    &frame,
                    native_deadline,
                    if local_expiry && frame.layout.frame_id == 10 {
                        Instant::now()
                    } else {
                        deadline
                    },
                    4096,
                    || Ok((ticks.next().unwrap(), 1000))
                )
                .await
                .unwrap(),
                AtlasDisposition::ExpiredUnbound
            );
            assert_eq!(pipe.last_frame, 10);
            assert_eq!(pipe.last_committed_frame, 9);
            assert!(pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe);

            // The owner independently checks the tile lineage. This pipe test
            // exercises the picture identity and decoder gap across V9 only.
            let mut c = recovery_control();
            c.geometry_epoch = c.previous_epoch;
            c.grant_generation = 0;
            c.deadline_qpc = 1000;
            c.rejection = Some(InputRejectionControl {
                kind: InputRejectionKind::Cancel,
                cancel_sequence: 1,
                previous_atlas_frame: 9,
                previous_source_frame: 10,
            });
            native.write_all(b"atlas-input-cancelled-v2 sequence=1 stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 previous_epoch=6 geometry_epoch=6 grant_generation=0 atlas_frame=9 source_frame=10 placement_generation=11 deadline_qpc=1000 frequency=1000 recovered_qpc=640 cause=rejected cancel_sequence=1\n").await.unwrap();
            let mut ticks = [600, 650].into_iter();
            assert_eq!(
                pipe.recover_input(c, deadline, || Ok((ticks.next().unwrap(), 1000)))
                    .await
                    .unwrap(),
                640
            );
            assert!(pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe);
            c.sequence = 2;
            c.grant_generation = 8;
            c.rejection.as_mut().unwrap().kind = InputRejectionKind::Resume;
            native.write_all(b"atlas-input-recovered-v2 sequence=2 stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 previous_epoch=6 geometry_epoch=6 grant_generation=8 atlas_frame=9 source_frame=10 placement_generation=11 deadline_qpc=1000 frequency=1000 recovered_qpc=740 cause=rejected cancel_sequence=1\n").await.unwrap();
            let mut ticks = [700, 750].into_iter();
            assert_eq!(
                pipe.recover_input(c, deadline, || Ok((ticks.next().unwrap(), 1000)))
                    .await
                    .unwrap(),
                740
            );
            assert_eq!(pipe.last_frame, 10);
            assert_eq!(pipe.last_committed_frame, 9);
            assert!(pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe && !pipe.poisoned);

            frame.layout.frame_id = 11;
            frame.media.manifest.frame_id = 11;
            let fresh_deadline = NativePresentationDeadline {
                ticks: 1000,
                frequency: 1000,
            };
            for (color, alpha) in [(false, true), (true, false)] {
                frame.layout.color_keyframe = color;
                frame.layout.alpha_keyframe = alpha;
                assert!(
                    pipe.submit_disposition(&frame, fresh_deadline, deadline, 4096, || Ok((
                        800, 1000
                    )))
                    .await
                    .is_err()
                );
                assert!(
                    pipe.receipt_mode == ReceiptMode::DispositionNeedsKeyframe && !pipe.poisoned
                );
            }
            frame.layout.color_keyframe = true;
            frame.layout.alpha_keyframe = true;
            native.write_all(b"atlas-disposition-v1 frame_identity=11 tile_count=0 outcome=committed deadline_ticks=1000 frequency=1000 commit_ticks=840 physical_present_receipt=false\n").await.unwrap();
            let mut ticks = [800, 850].into_iter();
            assert_eq!(
                pipe.submit_disposition(&frame, fresh_deadline, deadline, 4096, || Ok((
                    ticks.next().unwrap(),
                    1000
                )))
                .await
                .unwrap(),
                AtlasDisposition::CommittedWithinDeadline { commit_ticks: 840 }
            );
            assert_eq!(pipe.last_frame, 11);
            assert_eq!(pipe.last_committed_frame, 11);
            assert!(pipe.receipt_mode == ReceiptMode::Disposition && !pipe.poisoned);
        }
    }

    #[tokio::test]
    async fn rejected_controls_cannot_name_the_unbound_frame() {
        use crate::atlas_input_recovery::{InputRejectionControl, InputRejectionKind};
        for kind in [InputRejectionKind::Cancel, InputRejectionKind::Resume] {
            let (client, mut native) = tokio::io::duplex(4096);
            let (reader, writer) = tokio::io::split(client);
            let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
            native.write_all(RECOVERY_READY).await.unwrap();
            let deadline = Instant::now() + std::time::Duration::from_secs(1);
            pipe.wait_ready(deadline).await.unwrap();
            pipe.last_frame = 10;
            pipe.last_committed_frame = 9;
            pipe.receipt_mode = ReceiptMode::DispositionNeedsKeyframe;
            let mut c = recovery_control();
            c.geometry_epoch = c.previous_epoch;
            c.atlas_frame = 10;
            c.sequence = if kind == InputRejectionKind::Cancel {
                1
            } else {
                2
            };
            c.grant_generation = if kind == InputRejectionKind::Cancel {
                0
            } else {
                8
            };
            c.rejection = Some(InputRejectionControl {
                kind,
                cancel_sequence: 1,
                previous_atlas_frame: if kind == InputRejectionKind::Cancel {
                    10
                } else {
                    9
                },
                previous_source_frame: c.source_frame,
            });
            assert!(c.encode().is_ok());
            let error = pipe
                .recover_input(c, deadline, || {
                    panic!("invalid target must fail before writing")
                })
                .await
                .unwrap_err();
            assert!(error.to_string().contains("frame mismatch"));
            assert!(pipe.poisoned && pipe.io.is_none());
        }
    }

    #[tokio::test]
    async fn rejected_cancel_and_fresh_resume_share_ordered_pipe_without_picture_payload() {
        use crate::atlas_input_recovery::{InputRejectionControl, InputRejectionKind};
        let (client, mut native) = tokio::io::duplex(4096);
        let (reader, writer) = tokio::io::split(client);
        let mut pipe = AtlasPresenterPipe::with_input_recovery(writer, reader);
        native.write_all(RECOVERY_READY).await.unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        pipe.wait_ready(deadline).await.unwrap();
        pipe.last_frame = 10;
        pipe.last_committed_frame = 10;
        let mut c = recovery_control();
        c.geometry_epoch = c.previous_epoch;
        c.grant_generation = 0;
        c.rejection = Some(InputRejectionControl {
            kind: InputRejectionKind::Cancel,
            cancel_sequence: 1,
            previous_atlas_frame: 9,
            previous_source_frame: 10,
        });
        let cancel = String::from_utf8(RECOVERY_RECEIPT.to_vec())
            .unwrap()
            .trim_end()
            .replace("recovered-v1", "cancelled-v2")
            .replace("geometry_epoch=7", "geometry_epoch=6")
            .replace("grant_generation=8", "grant_generation=0")
            + " cause=rejected cancel_sequence=1\n";
        native.write_all(cancel.as_bytes()).await.unwrap();
        let mut ticks = [(100, 1000), (115, 1000)].into_iter();
        assert_eq!(
            pipe.recover_input(c, deadline, || Ok(ticks.next().unwrap()))
                .await
                .unwrap(),
            110
        );
        let mut bytes = vec![0; 176];
        native.read_exact(&mut bytes).await.unwrap();
        assert_eq!(bytes, c.encode().unwrap());
        assert_eq!(pipe.last_frame, 10);
        assert_eq!(pipe.last_recovery, 1);
        assert!(!pipe.poisoned);
        c.sequence = 2;
        c.grant_generation = 8;
        c.atlas_frame = 10;
        c.source_frame = 11;
        c.rejection.as_mut().unwrap().kind = InputRejectionKind::Resume;
        let resume = cancel
            .replace("cancelled-v2", "recovered-v2")
            .replace("sequence=1 ", "sequence=2 ")
            .replace("grant_generation=0", "grant_generation=8")
            .replace("atlas_frame=9 ", "atlas_frame=10 ")
            .replace("source_frame=10 ", "source_frame=11 ");
        native.write_all(resume.as_bytes()).await.unwrap();
        let mut ticks = [(100, 1000), (115, 1000)].into_iter();
        assert_eq!(
            pipe.recover_input(c, deadline, || Ok(ticks.next().unwrap()))
                .await
                .unwrap(),
            110
        );
        native.read_exact(&mut bytes).await.unwrap();
        assert_eq!(bytes, c.encode().unwrap());
        assert_eq!(pipe.last_recovery, 2);
        assert!(!pipe.poisoned);
    }
}
