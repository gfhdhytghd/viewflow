//! Trusted-local desktop move intents emitted by the native v7 presenter.
//! These records are never pointer input and never authorize a local HWND move.
use anyhow::{Result, ensure};
use viewflow_protocol::{AtlasWindowSelection, DesktopRect, DesktopWindowMovePhase, Id128};

/// A native desktop move intent bound to one exact committed atlas tile.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AtlasDesktopMove {
    /// Assigned only by the single native stdout dispatcher. Parsed fixtures
    /// retain zero until they enter that ordered ingress point.
    ingress_ordinal: u64,
    /// A source-owned control sequence/deadline must be assigned separately.
    pub selection: AtlasWindowSelection,
    pub topology_generation: u64,
    pub drag_id: u64,
    pub phase: DesktopWindowMovePhase,
    pub deadline_qpc: u64,
    pub frequency: u64,
    pub desired_bounds: DesktopRect,
}

impl AtlasDesktopMove {
    #[must_use]
    pub fn ingress_ordinal(&self) -> u64 {
        self.ingress_ordinal
    }

    pub(crate) fn with_ingress_ordinal(mut self, ordinal: u64) -> Result<Self> {
        ensure!(ordinal > 0, "invalid desktop move ingress ordinal");
        self.ingress_ordinal = ordinal;
        Ok(self)
    }

    /// # Errors
    /// Rejects oversized, reordered, noncanonical, stale-shape, or otherwise
    /// ambiguous native lines before they can reach the desktop control lane.
    pub fn parse(line: &str) -> Result<Self> {
        ensure!(line.len() <= 1024, "desktop move record too large");
        let fields: Vec<_> = line.split(' ').collect();
        ensure!(
            fields.len() == 22 && fields[0] == "desktop-move-v1",
            "invalid desktop move envelope"
        );
        let number = |index: usize, name: &str| -> Result<u64> {
            let (key, raw) = fields[index]
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("missing desktop move field"))?;
            ensure!(key == name, "unexpected desktop move field");
            let value: u64 = raw.parse()?;
            ensure!(
                raw == value.to_string(),
                "noncanonical desktop move integer"
            );
            Ok(value)
        };
        let signed = |index: usize, name: &str| -> Result<i64> {
            let (key, raw) = fields[index]
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("missing desktop move field"))?;
            ensure!(key == name, "unexpected desktop move field");
            let value: i64 = raw.parse()?;
            ensure!(
                raw == value.to_string(),
                "noncanonical desktop move integer"
            );
            Ok(value)
        };
        let selection = AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: Id128(
                (u128::from(number(1, "stream_hi")?) << 64) | u128::from(number(2, "stream_lo")?),
            ),
            atlas_frame_id: number(3, "atlas_frame")?,
            atlas_geometry_epoch: number(4, "atlas_epoch")?,
            config_generation: number(5, "config_generation")?,
            layout_revision: number(6, "layout_revision")?,
            window_id: Id128(
                (u128::from(number(7, "window_hi")?) << 64) | u128::from(number(8, "window_lo")?),
            ),
            placement_generation: number(9, "placement_generation")?,
            source_geometry_epoch: number(10, "source_epoch")?,
            source_frame_id: number(11, "source_frame")?,
            sequence: number(14, "sequence")?,
            // `sender_not_after_ns` has a different receiver-local clock. The
            // owner derives it from the native QPC deadline below.
            sender_not_after_ns: 1,
        };
        selection
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid desktop move selection: {error:?}"))?;
        let phase = match fields[15] {
            "phase=begin" => DesktopWindowMovePhase::Begin,
            "phase=update" => DesktopWindowMovePhase::Update,
            "phase=end" => DesktopWindowMovePhase::End,
            "phase=cancel" => DesktopWindowMovePhase::Cancel,
            _ => anyhow::bail!("invalid desktop move phase"),
        };
        let result = Self {
            ingress_ordinal: 0,
            selection,
            topology_generation: number(12, "topology_generation")?,
            drag_id: number(13, "drag_id")?,
            phase,
            deadline_qpc: number(16, "deadline_qpc")?,
            frequency: number(17, "qpc_frequency")?,
            desired_bounds: DesktopRect {
                x_millidip: signed(18, "x_millidip")?,
                y_millidip: signed(19, "y_millidip")?,
                width_millidip: number(20, "width_millidip")?,
                height_millidip: number(21, "height_millidip")?,
            },
        };
        ensure!(
            result.topology_generation > 0
                && result.drag_id > 0
                && result.deadline_qpc > 0
                && result.frequency > 0,
            "invalid desktop move lineage or clock"
        );
        result
            .desired_bounds
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid desktop move bounds: {error:?}"))?;
        Ok(result)
    }

    /// Convert the original native QPC deadline without extending it. The
    /// caller supplies a same-process QPC sample taken before `receiver_now_ns`.
    /// # Errors
    /// Rejects a stale/mismatched QPC sample or conversion overflow.
    pub fn sender_not_after_ns(
        self,
        sample_qpc: u64,
        frequency: u64,
        receiver_now_ns: u64,
    ) -> Result<u64> {
        ensure!(
            sample_qpc > 0 && frequency == self.frequency && sample_qpc < self.deadline_qpc,
            "desktop move deadline clock mismatch or expiry"
        );
        let remaining_ns =
            u128::from(self.deadline_qpc - sample_qpc) * 1_000_000_000 / u128::from(frequency);
        ensure!(
            remaining_ns > 0,
            "desktop move deadline has no whole-nanosecond budget"
        );
        ensure!(
            remaining_ns <= u128::from(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS),
            "desktop move deadline exceeds event budget"
        );
        receiver_now_ns
            .checked_add(u64::try_from(remaining_ns)?)
            .ok_or_else(|| anyhow::anyhow!("desktop move deadline overflow"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOVE: &str = "desktop-move-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 topology_generation=5 drag_id=6 sequence=9 phase=update deadline_qpc=120 qpc_frequency=1000 x_millidip=-100 y_millidip=200 width_millidip=640 height_millidip=480";

    #[test]
    fn native_wm_operation_budget_converts_without_extension() {
        let ordered =
            AtlasDesktopMove::parse(&MOVE.replace("deadline_qpc=120", "deadline_qpc=5100"))
                .unwrap();
        assert_eq!(
            ordered.sender_not_after_ns(100, 1000, 1_000).unwrap(),
            5_000_001_000
        );
        assert!(ordered.sender_not_after_ns(99, 1000, 1_000).is_err());
        let event =
            AtlasDesktopMove::parse(&MOVE.replace("deadline_qpc=120", "deadline_qpc=350")).unwrap();
        assert_eq!(
            event.sender_not_after_ns(100, 1000, 1_000).unwrap(),
            250_001_000
        );
        assert_eq!(
            event.sender_not_after_ns(140, 1000, 1_000).unwrap(),
            210_001_000
        );
        assert_eq!(
            event.sender_not_after_ns(99, 1000, 1_000).unwrap(),
            251_001_000
        );
    }

    #[test]
    fn desktop_move_is_exact_typed_deadline_bound_intent() {
        let move_event = AtlasDesktopMove::parse(MOVE).unwrap();
        assert_eq!(move_event.ingress_ordinal(), 0);
        assert_eq!(move_event.selection.stream_id, Id128(99));
        assert_eq!(move_event.selection.window_id, Id128(8));
        assert_eq!(move_event.selection.sequence, 9);
        assert_eq!(move_event.phase, DesktopWindowMovePhase::Update);
        assert_eq!(move_event.desired_bounds.x_millidip, -100);
        assert_eq!(
            move_event.sender_not_after_ns(110, 1000, 1_000).unwrap(),
            10_001_000
        );
        assert!(move_event.sender_not_after_ns(120, 1000, 1_000).is_err());
        assert!(move_event.sender_not_after_ns(110, 999, 1_000).is_err());
        assert_eq!(
            move_event.sender_not_after_ns(80, 1000, 1_000).unwrap(),
            40_001_000
        );
        for (from, to) in [
            ("phase=update", "phase=move"),
            ("stream_lo=99", "stream_lo=099"),
            ("drag_id=6", "drag_id=0"),
            ("sequence=9", "sequence=0"),
            ("deadline_qpc=120", "deadline_qpc=0"),
            ("x_millidip=-100", "x_millidip=-0"),
            ("width_millidip=640", "width_millidip=0"),
            ("placement_generation=4", "placement_generation=5"),
        ] {
            assert!(
                AtlasDesktopMove::parse(&MOVE.replace(from, to)).is_err(),
                "{to}"
            );
        }
        for length in 0..MOVE.split(' ').count() {
            assert!(
                AtlasDesktopMove::parse(
                    &MOVE.split(' ').take(length).collect::<Vec<_>>().join(" ")
                )
                .is_err()
            );
        }
        assert!(AtlasDesktopMove::parse(&format!("{MOVE} extra=1")).is_err());
    }
}
