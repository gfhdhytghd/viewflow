//! Trusted-local VFGP v6 resize and v9 rejected-gesture recovery records.
//! Encoding is not authorization: cancellation requires confirmed source END;
//! resume requires a fresh source grant and an exact committed tile binding.
use anyhow::{Result, ensure};

pub const RECORD_BYTES: usize = 152;
pub const REJECTION_RECORD_BYTES: usize = 176;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputRejectionKind {
    Cancel,
    Resume,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InputRejectionControl {
    pub kind: InputRejectionKind,
    pub cancel_sequence: u64,
    pub previous_atlas_frame: u64,
    pub previous_source_frame: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeRejectedGesture {
    pub cancel_sequence: u64,
    /// Assigned by the sole stdout dispatcher, never accepted from the wire.
    pub ingress_boundary: u64,
}

/// A local cancellation/drain notification, never an injectable input event or
/// evidence that the source has released its held-input lease.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeRecoveryNotice {
    pub rejection: Option<NativeRejectedGesture>,
    pub selection: viewflow_protocol::AtlasWindowSelection,
    pub previous_epoch: u64,
    pub previous_atlas_frame: u64,
    pub previous_source_frame: u64,
    pub physical_drained: bool,
    pub observed_qpc: u64,
    pub frequency: u64,
}

impl NativeRecoveryNotice {
    /// # Errors
    /// Rejects ambiguous/noncanonical records and non-advancing geometry.
    pub fn parse(line: &str) -> Result<Self> {
        ensure!(line.len() <= 1024, "recovery notice too large");
        let fields: Vec<_> = line.split(' ').collect();
        let rejected = fields.first() == Some(&"atlas-input-suspended-v2");
        ensure!(
            (rejected && fields.len() == 20)
                || (!rejected && fields.len() == 18 && fields[0] == "atlas-input-suspended-v1"),
            "invalid recovery notice envelope"
        );
        let physical_drained = match fields[1] {
            "phase=cancelled" => false,
            "phase=drained" => true,
            _ => anyhow::bail!("invalid recovery notice phase"),
        };
        let number = |index: usize, name: &str| -> Result<u64> {
            let (key, raw) = fields[index]
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("missing recovery notice field"))?;
            ensure!(key == name, "unexpected recovery notice field");
            let value: u64 = raw.parse()?;
            ensure!(
                raw == value.to_string(),
                "noncanonical recovery notice integer"
            );
            Ok(value)
        };
        let selection = viewflow_protocol::AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: viewflow_protocol::Id128(
                (u128::from(number(2, "stream_hi")?) << 64) | u128::from(number(3, "stream_lo")?),
            ),
            window_id: viewflow_protocol::Id128(
                (u128::from(number(4, "window_hi")?) << 64) | u128::from(number(5, "window_lo")?),
            ),
            atlas_geometry_epoch: number(6, "atlas_epoch")?,
            config_generation: number(7, "config_generation")?,
            layout_revision: number(8, "layout_revision")?,
            source_geometry_epoch: number(12, "geometry_epoch")?,
            atlas_frame_id: number(13, "atlas_frame")?,
            source_frame_id: number(14, "source_frame")?,
            placement_generation: number(15, "placement_generation")?,
            // The owner must assign its ordered control sequence and a bounded
            // clock-converted deadline before making any source request.
            sequence: 1,
            sender_not_after_ns: 1,
        };
        selection
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid recovery selection: {error:?}"))?;
        let rejection = if rejected {
            ensure!(fields[18] == "cause=rejected", "invalid rejection cause");
            let cancel_sequence = number(19, "cancel_sequence")?;
            ensure!(cancel_sequence > 0, "invalid rejection cancel sequence");
            Some(NativeRejectedGesture {
                cancel_sequence,
                ingress_boundary: 0,
            })
        } else {
            None
        };
        let notice = Self {
            rejection,
            selection,
            previous_epoch: number(9, "previous_epoch")?,
            previous_atlas_frame: number(10, "previous_atlas_frame")?,
            previous_source_frame: number(11, "previous_source_frame")?,
            physical_drained,
            observed_qpc: number(16, "observed_qpc")?,
            frequency: number(17, "frequency")?,
        };
        ensure!(
            notice.previous_epoch > 0
                && notice.previous_atlas_frame > 0
                && notice.previous_source_frame > 0
                && if rejected {
                    selection.source_geometry_epoch >= notice.previous_epoch
                        && selection.atlas_frame_id >= notice.previous_atlas_frame
                        && selection.source_frame_id >= notice.previous_source_frame
                } else {
                    selection.source_geometry_epoch > notice.previous_epoch
                        && selection.atlas_frame_id > notice.previous_atlas_frame
                        && selection.source_frame_id > notice.previous_source_frame
                }
                && notice.observed_qpc > 0
                && notice.frequency > 0,
            "invalid recovery notice lineage or clock"
        );
        Ok(notice)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InputRecoveryConfirmation {
    pub rejection: Option<InputRejectionControl>,
    pub sequence: u64,
    pub stream: u128,
    pub window: u128,
    pub atlas_epoch: u64,
    pub config_generation: u64,
    pub previous_epoch: u64,
    pub geometry_epoch: u64,
    pub grant_generation: u64,
    pub atlas_frame: u64,
    pub source_frame: u64,
    pub placement_generation: u64,
    pub deadline_qpc: u64,
    pub frequency: u64,
}

impl InputRecoveryConfirmation {
    /// Validate the native receipt against this exact pending control. QPC
    /// bounds must be sampled on the native child's host, before writing and
    /// after reading. A receipt never substitutes for source authorization.
    /// # Errors
    /// Rejects noncanonical fields, cross-control replies and invalid timing.
    pub fn validate_receipt(self, line: &str, sent_qpc: u64, observed_qpc: u64) -> Result<u64> {
        self.encode()?;
        ensure!(line.len() <= 1024, "recovery receipt too large");
        let fields: Vec<_> = line.split(' ').collect();
        let (prefix, field_count) = match self.rejection.map(|r| r.kind) {
            None => ("atlas-input-recovered-v1", 17),
            Some(InputRejectionKind::Cancel) => ("atlas-input-cancelled-v2", 19),
            Some(InputRejectionKind::Resume) => ("atlas-input-recovered-v2", 19),
        };
        ensure!(
            fields.len() == field_count && fields[0] == prefix,
            "invalid recovery receipt envelope"
        );
        if let Some(rejection) = self.rejection {
            ensure!(
                fields[17] == "cause=rejected"
                    && fields[18] == format!("cancel_sequence={}", rejection.cancel_sequence),
                "recovery receipt rejection binding mismatch"
            );
        }
        let (stream_hi, stream_lo) = split_id(self.stream);
        let (window_hi, window_lo) = split_id(self.window);
        let expected = [
            ("sequence", self.sequence),
            ("stream_hi", stream_hi),
            ("stream_lo", stream_lo),
            ("window_hi", window_hi),
            ("window_lo", window_lo),
            ("atlas_epoch", self.atlas_epoch),
            ("config_generation", self.config_generation),
            ("previous_epoch", self.previous_epoch),
            ("geometry_epoch", self.geometry_epoch),
            ("grant_generation", self.grant_generation),
            ("atlas_frame", self.atlas_frame),
            ("source_frame", self.source_frame),
            ("placement_generation", self.placement_generation),
            ("deadline_qpc", self.deadline_qpc),
            ("frequency", self.frequency),
        ];
        for (field, (name, value)) in fields[1..16].iter().zip(expected) {
            ensure!(
                *field == format!("{name}={value}"),
                "recovery receipt binding mismatch"
            );
        }
        let raw = fields[16]
            .strip_prefix("recovered_qpc=")
            .ok_or_else(|| anyhow::anyhow!("missing recovery receipt timestamp"))?;
        let recovered: u64 = raw.parse()?;
        ensure!(
            raw == recovered.to_string(),
            "noncanonical recovery timestamp"
        );
        ensure!(
            sent_qpc > 0
                && recovered >= sent_qpc
                && recovered <= observed_qpc
                && recovered < self.deadline_qpc,
            "recovery receipt clock bounds"
        );
        Ok(recovered)
    }

    /// # Errors
    /// Rejects missing lineage or a geometry epoch that does not advance.
    pub fn encode(self) -> Result<Vec<u8>> {
        ensure!(
            self.stream != 0 && self.window != 0 && self.stream != self.window,
            "invalid recovery target"
        );
        let fields = [
            self.atlas_epoch,
            self.config_generation,
            self.previous_epoch,
            self.geometry_epoch,
            self.grant_generation,
            self.atlas_frame,
            self.source_frame,
            self.placement_generation,
            self.deadline_qpc,
            self.frequency,
        ];
        ensure!(
            self.sequence != 0
                && fields
                    .iter()
                    .enumerate()
                    .all(|(i, field)| i == 4 || *field != 0),
            "invalid recovery lineage"
        );
        let length = if let Some(rejection) = self.rejection {
            ensure!(
                rejection.cancel_sequence > 0
                    && rejection.previous_atlas_frame > 0
                    && rejection.previous_source_frame > 0,
                "invalid rejection lineage"
            );
            match rejection.kind {
                InputRejectionKind::Cancel => ensure!(
                    rejection.cancel_sequence == self.sequence
                        && self.grant_generation == 0
                        && self.geometry_epoch == self.previous_epoch
                        && self.atlas_frame == rejection.previous_atlas_frame
                        && self.source_frame == rejection.previous_source_frame,
                    "invalid rejection cancellation binding"
                ),
                InputRejectionKind::Resume => ensure!(
                    rejection.cancel_sequence < self.sequence
                        && self.grant_generation > 0
                        && self.geometry_epoch >= self.previous_epoch
                        && self.atlas_frame >= rejection.previous_atlas_frame
                        && self.source_frame >= rejection.previous_source_frame,
                    "invalid rejection resume binding"
                ),
            }
            REJECTION_RECORD_BYTES
        } else {
            ensure!(
                self.grant_generation > 0 && self.geometry_epoch > self.previous_epoch,
                "invalid recovery lineage"
            );
            RECORD_BYTES
        };
        let mut bytes = vec![0; length];
        bytes[..4].copy_from_slice(b"VFGP");
        bytes[4] = if self.rejection.is_some() { 9 } else { 6 };
        if let Some(rejection) = self.rejection {
            bytes[5] = match rejection.kind {
                InputRejectionKind::Cancel => 1,
                InputRejectionKind::Resume => 2,
            };
            bytes[6] = 1;
            bytes[152..160].copy_from_slice(&rejection.cancel_sequence.to_be_bytes());
            bytes[160..168].copy_from_slice(&rejection.previous_atlas_frame.to_be_bytes());
            bytes[168..176].copy_from_slice(&rejection.previous_source_frame.to_be_bytes());
        }
        bytes[8..12].copy_from_slice(&u32::try_from(length)?.to_be_bytes());
        bytes[16..24].copy_from_slice(&self.sequence.to_be_bytes());
        bytes[40..56].copy_from_slice(&self.stream.to_be_bytes());
        bytes[56..72].copy_from_slice(&self.window.to_be_bytes());
        for (index, field) in fields.iter().enumerate() {
            let offset = 72 + index * 8;
            bytes[offset..offset + 8].copy_from_slice(&field.to_be_bytes());
        }
        Ok(bytes)
    }
}

fn split_id(value: u128) -> (u64, u64) {
    let high = u64::try_from(value >> 64).expect("a shifted u128 identifier fits u64");
    let low =
        u64::try_from(value & u128::from(u64::MAX)).expect("a masked u128 identifier fits u64");
    (high, low)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUSPENDED: &str = "atlas-input-suspended-v1 phase=drained stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 layout_revision=11 previous_epoch=6 previous_atlas_frame=8 previous_source_frame=9 geometry_epoch=7 atlas_frame=10 source_frame=12 placement_generation=11 observed_qpc=110 frequency=1000";

    #[test]
    fn suspended_notice_is_exact_typed_lineage_not_input() {
        let notice = NativeRecoveryNotice::parse(SUSPENDED).unwrap();
        assert!(notice.physical_drained);
        assert_eq!(notice.selection.stream_id.0, 2);
        assert_eq!(notice.selection.window_id.0, 3);
        assert_eq!(notice.selection.atlas_frame_id, 10);
        assert_eq!(notice.selection.source_frame_id, 12);
        assert_eq!(notice.previous_epoch, 6);
        assert_eq!(notice.observed_qpc, 110);
        assert_eq!(
            NativeRecoveryNotice::parse(&SUSPENDED.replace("phase=drained", "phase=cancelled"))
                .unwrap()
                .physical_drained,
            false
        );
        for (from, to) in [
            ("phase=drained", "phase=resume"),
            ("stream_lo=2", "stream_lo=02"),
            ("layout_revision=11", "layout_revision=10"),
            ("previous_epoch=6", "previous_epoch=0"),
            ("geometry_epoch=7", "geometry_epoch=6"),
            ("atlas_frame=10", "atlas_frame=8"),
            ("source_frame=12", "source_frame=9"),
            ("placement_generation=11", "placement_generation=12"),
            ("observed_qpc=110", "observed_qpc=0"),
            ("frequency=1000", "frequency=0"),
            ("stream_hi=0", "stream_hi=+0"),
        ] {
            assert!(
                NativeRecoveryNotice::parse(&SUSPENDED.replace(from, to)).is_err(),
                "{to}"
            );
        }
        for length in 0..SUSPENDED.split(' ').count() {
            assert!(
                NativeRecoveryNotice::parse(
                    &SUSPENDED
                        .split(' ')
                        .take(length)
                        .collect::<Vec<_>>()
                        .join(" ")
                )
                .is_err()
            );
        }
        assert!(NativeRecoveryNotice::parse(&format!("{SUSPENDED} extra=1")).is_err());
        assert!(NativeRecoveryNotice::parse(&format!("{SUSPENDED}\n")).is_err());
    }

    #[test]
    fn receipt_is_exact_control_bound_and_not_a_picture_receipt() {
        let c = InputRecoveryConfirmation {
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
        };
        let line = "atlas-input-recovered-v1 sequence=1 stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 previous_epoch=6 geometry_epoch=7 grant_generation=8 atlas_frame=9 source_frame=10 placement_generation=11 deadline_qpc=120 frequency=1000 recovered_qpc=110";
        assert_eq!(c.validate_receipt(line, 100, 115).unwrap(), 110);
        // A late observer is acceptable only because the exact native receipt
        // proves recovery happened before expiry; write deadlines stay separate.
        assert_eq!(c.validate_receipt(line, 100, 130).unwrap(), 110);
        for index in 1..17 {
            let mut fields: Vec<_> = line.split(' ').map(str::to_owned).collect();
            let (name, raw) = fields[index].split_once('=').unwrap();
            fields[index] = format!("{name}={}", raw.parse::<u64>().unwrap() + 100);
            assert!(c.validate_receipt(&fields.join(" "), 100, 115).is_err());
        }
        for invalid in [
            line.replace("sequence=1 ", "sequence=01 "),
            line.replace("recovered_qpc=110", "recovered_qpc=0110"),
            line.replace("recovered_qpc=110", "recovered_qpc=+110"),
            line.replace("recovered_qpc=110", "recovered_qpc=120"),
            line.replace("atlas-input-recovered-v1", "atlas-disposition-v1"),
            format!("{line} extra=1"),
            format!("{line}\n"),
            line.replace("sequence=1 ", "sequence=1  "),
        ] {
            assert!(c.validate_receipt(&invalid, 100, 130).is_err());
        }
        assert!(c.validate_receipt(line, 111, 115).is_err());
        assert!(c.validate_receipt(line, 100, 109).is_err());
        assert!(c.validate_receipt(line, 0, 115).is_err());
    }
    #[test]
    fn fixed_control_layout_never_claims_picture_payload() {
        let record = InputRecoveryConfirmation {
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
            deadline_qpc: 12,
            frequency: 13,
        };
        let bytes = record.encode().unwrap();
        assert_eq!(&bytes[..8], b"VFGP\x06\0\0\0");
        assert_eq!(&bytes[12..16], &[0; 4]);
        assert_eq!(&bytes[24..40], &[0; 16]);
        for (offset, expected) in [
            (16, 1_u64),
            (48, 2),
            (64, 3),
            (72, 4),
            (80, 5),
            (88, 6),
            (96, 7),
            (104, 8),
            (112, 9),
            (120, 10),
            (128, 11),
            (136, 12),
            (144, 13),
        ] {
            assert_eq!(
                u64::from_be_bytes(bytes[offset..offset + 8].try_into().unwrap()),
                expected
            );
        }
        for field in 0..13 {
            let mut invalid = record;
            match field {
                0 => invalid.sequence = 0,
                1 => invalid.stream = 0,
                2 => invalid.window = 0,
                3 => invalid.atlas_epoch = 0,
                4 => invalid.config_generation = 0,
                5 => invalid.previous_epoch = 0,
                6 => invalid.geometry_epoch = 0,
                7 => invalid.grant_generation = 0,
                8 => invalid.atlas_frame = 0,
                9 => invalid.source_frame = 0,
                10 => invalid.placement_generation = 0,
                11 => invalid.deadline_qpc = 0,
                _ => invalid.frequency = 0,
            }
            assert!(invalid.encode().is_err());
        }
        assert!(
            InputRecoveryConfirmation {
                window: record.stream,
                ..record
            }
            .encode()
            .is_err()
        );
        assert!(
            InputRecoveryConfirmation {
                geometry_epoch: record.previous_epoch,
                ..record
            }
            .encode()
            .is_err()
        );
    }
    fn rejected_control(kind: InputRejectionKind) -> InputRecoveryConfirmation {
        InputRecoveryConfirmation {
            rejection: Some(InputRejectionControl {
                kind,
                cancel_sequence: 1,
                previous_atlas_frame: 9,
                previous_source_frame: 10,
            }),
            sequence: if kind == InputRejectionKind::Cancel {
                1
            } else {
                2
            },
            stream: 2,
            window: 3,
            atlas_epoch: 4,
            config_generation: 5,
            previous_epoch: 6,
            geometry_epoch: 6,
            grant_generation: if kind == InputRejectionKind::Cancel {
                0
            } else {
                8
            },
            atlas_frame: 9,
            source_frame: 10,
            placement_generation: 11,
            deadline_qpc: 120,
            frequency: 1000,
        }
    }

    #[test]
    fn rejected_gesture_controls_are_explicit_and_cannot_weaken_legacy_recovery() {
        for kind in [InputRejectionKind::Cancel, InputRejectionKind::Resume] {
            let c = rejected_control(kind);
            let encoded = c.encode().unwrap();
            assert_eq!(encoded.len(), 176);
            assert_eq!(
                &encoded[..8],
                &[
                    86,
                    70,
                    71,
                    80,
                    9,
                    if kind == InputRejectionKind::Cancel {
                        1
                    } else {
                        2
                    },
                    1,
                    0
                ]
            );
            assert_eq!(u32::from_be_bytes(encoded[8..12].try_into().unwrap()), 176);
            for (offset, value) in [(152, 1_u64), (160, 9), (168, 10)] {
                assert_eq!(
                    u64::from_be_bytes(encoded[offset..offset + 8].try_into().unwrap()),
                    value
                );
            }
            assert!(
                InputRecoveryConfirmation {
                    rejection: None,
                    ..c
                }
                .encode()
                .is_err()
            );
            let prefix = if kind == InputRejectionKind::Cancel {
                "atlas-input-cancelled-v2"
            } else {
                "atlas-input-recovered-v2"
            };
            let line = format!(
                "{prefix} sequence={} stream_hi=0 stream_lo=2 window_hi=0 window_lo=3 atlas_epoch=4 config_generation=5 previous_epoch=6 geometry_epoch=6 grant_generation={} atlas_frame=9 source_frame=10 placement_generation=11 deadline_qpc=120 frequency=1000 recovered_qpc=110 cause=rejected cancel_sequence=1",
                c.sequence, c.grant_generation
            );
            assert_eq!(c.validate_receipt(&line, 100, 115).unwrap(), 110);
            for invalid in [
                line.replace("cause=rejected", "cause=resize"),
                line.replace("cancel_sequence=1", "cancel_sequence=2"),
                line.replace("cancel_sequence=1", "cancel_sequence=01"),
                line.replace("recovered_qpc=110", "recovered_qpc=120"),
                line.replace(prefix, "atlas-input-recovered-v1"),
            ] {
                assert!(c.validate_receipt(&invalid, 100, 130).is_err());
            }
        }
        let c = rejected_control(InputRejectionKind::Cancel);
        for invalid in [
            InputRecoveryConfirmation {
                grant_generation: 1,
                ..c
            },
            InputRecoveryConfirmation { sequence: 2, ..c },
            InputRecoveryConfirmation {
                geometry_epoch: 7,
                ..c
            },
            InputRecoveryConfirmation {
                atlas_frame: 10,
                ..c
            },
            InputRecoveryConfirmation {
                source_frame: 11,
                ..c
            },
        ] {
            assert!(invalid.encode().is_err());
        }
        let r = rejected_control(InputRejectionKind::Resume);
        for invalid in [
            InputRecoveryConfirmation {
                grant_generation: 0,
                ..r
            },
            InputRecoveryConfirmation { sequence: 1, ..r },
            InputRecoveryConfirmation {
                geometry_epoch: 5,
                ..r
            },
            InputRecoveryConfirmation {
                atlas_frame: 8,
                ..r
            },
            InputRecoveryConfirmation {
                source_frame: 9,
                ..r
            },
        ] {
            assert!(invalid.encode().is_err());
        }
    }

    #[test]
    fn rejected_notice_allows_same_geometry_only_with_exact_explicit_cause() {
        let line = SUSPENDED
            .replace("suspended-v1", "suspended-v2")
            .replace("geometry_epoch=7", "geometry_epoch=6")
            .replace("atlas_frame=10 ", "atlas_frame=8 ")
            .replace("source_frame=12 ", "source_frame=9 ")
            + " cause=rejected cancel_sequence=3";
        let notice = NativeRecoveryNotice::parse(&line).unwrap();
        assert_eq!(
            notice.rejection,
            Some(NativeRejectedGesture {
                cancel_sequence: 3,
                ingress_boundary: 0
            })
        );
        for invalid in [
            line.replace("cause=rejected", "cause=resize"),
            line.replace("cancel_sequence=3", "cancel_sequence=0"),
            line.replace("cancel_sequence=3", "cancel_sequence=03"),
            line.replace("geometry_epoch=6", "geometry_epoch=5"),
            line.replace(" atlas_frame=8 ", " atlas_frame=7 "),
            line.replace(" source_frame=9 ", " source_frame=8 "),
            line.replace("suspended-v2", "suspended-v1"),
        ] {
            assert!(NativeRecoveryNotice::parse(&invalid).is_err(), "{invalid}");
        }
    }
}
