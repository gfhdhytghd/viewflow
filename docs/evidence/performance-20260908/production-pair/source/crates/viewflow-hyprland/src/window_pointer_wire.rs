//! Native VFHY window-pointer IPC codec, not remote input authorization.
//! Deadlines must already be converted to Linux `CLOCK_MONOTONIC` nanoseconds.

const HEADER: usize = 20;
const RESULT: u16 = 53;
/// Largest value120 whose 15-unit detent fits Wayland's signed 24.8 axis value.
pub const MAX_WHEEL_120: i32 = 67_108_863;

fn field<const N: usize>(packet: &[u8], offset: usize) -> Result<[u8; N], WireError> {
    packet
        .get(offset..offset.checked_add(N).ok_or(WireError::InvalidPacket)?)
        .ok_or(WireError::InvalidPacket)?
        .try_into()
        .map_err(|_| WireError::InvalidPacket)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireError {
    InvalidRequest,
    InvalidPacket,
    WrongIdentity,
    WrongResult,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Rejected,
    Begun,
    MotionSent,
    ButtonSent,
    WheelSent,
    KeySent,
    Ended,
}

/// One pending command. Completion consumes it, including on rejection/error.
/// Connection ownership and incoming envelope sequencing remain caller duties.
#[derive(Debug)]
pub struct Request {
    bytes: Vec<u8>,
    generation: u64,
    sequence: u64,
    expected: Outcome,
}

impl Request {
    /// Explicit local reauthorization after a native resize-only suspension.
    /// The native peer requires a still-live exact-target guard, a strictly
    /// newer generation, and inherits capabilities from the retired session.
    /// This codec does not authorize a remote selection or fresh geometry.
    /// # Errors
    /// Rejects the same invalid binding and lifetime fields as `begin`.
    pub fn rebind_resized(
        sequence: u64,
        generation: u64,
        address: u64,
        pid: u32,
        deadline_ns: u64,
        extent: [f64; 2],
        surface: u64,
    ) -> Result<Self, WireError> {
        let mut request = Self::begin(
            sequence,
            generation,
            address,
            pid,
            deadline_ns,
            extent,
            surface,
        )?;
        request.bytes[6..8].copy_from_slice(&61_u16.to_le_bytes());
        Ok(request)
    }

    /// Explicit direct-application keyboard capability in addition to pointer,
    /// buttons and wheel. Native v1 rejects active Wayland IME grabs; it is not
    /// a claim of full source input-method support.
    /// # Errors
    /// Rejects the same invalid binding and lifetime fields as `begin`.
    pub fn begin_direct_keyboard(
        sequence: u64,
        generation: u64,
        address: u64,
        pid: u32,
        deadline_ns: u64,
        extent: [f64; 2],
        surface: u64,
    ) -> Result<Self, WireError> {
        let mut request = Self::begin(
            sequence,
            generation,
            address,
            pid,
            deadline_ns,
            extent,
            surface,
        )?;
        request.bytes[6..8].copy_from_slice(&59_u16.to_le_bytes());
        Ok(request)
    }

    /// Physical key transition without pointer coordinates; the native session
    /// must already own explicit direct-keyboard authority for this generation.
    /// # Errors
    /// Rejects invalid identities, deadline, usage or repeat-on-release.
    pub fn key(
        sequence: u64,
        generation: u64,
        deadline_ns: u64,
        usage: [u16; 2],
        state: u32,
        repeat: bool,
    ) -> Result<Self, WireError> {
        if deadline_ns == 0
            || usage.contains(&0)
            || !(1..=2).contains(&state)
            || (repeat && state != 1)
        {
            return Err(WireError::InvalidRequest);
        }
        Self::new(
            60,
            sequence,
            generation,
            Outcome::KeySent,
            &[
                deadline_ns,
                u64::from(usage[0]) | (u64::from(usage[1]) << 32),
                u64::from(state) | (u64::from(repeat) << 32),
            ],
        )
    }

    fn new(
        tag: u16,
        sequence: u64,
        generation: u64,
        expected: Outcome,
        fields: &[u64],
    ) -> Result<Self, WireError> {
        if sequence == 0 || generation == 0 {
            return Err(WireError::InvalidRequest);
        }
        let mut bytes = Vec::with_capacity(HEADER + 8 + fields.len() * 8);
        bytes.extend_from_slice(b"VFHY");
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&tag.to_le_bytes());
        bytes.extend_from_slice(
            &u32::try_from(8 + fields.len() * 8)
                .map_err(|_| WireError::InvalidRequest)?
                .to_le_bytes(),
        );
        bytes.extend_from_slice(&sequence.to_le_bytes());
        bytes.extend_from_slice(&generation.to_le_bytes());
        for field in fields {
            bytes.extend_from_slice(&field.to_le_bytes());
        }
        Ok(Self {
            bytes,
            generation,
            sequence,
            expected,
        })
    }

    /// # Errors
    /// Rejects zero identities/deadline, invalid PID or nonpositive/nonfinite extent.
    pub fn begin(
        sequence: u64,
        generation: u64,
        address: u64,
        pid: u32,
        deadline_ns: u64,
        extent: [f64; 2],
        surface: u64,
    ) -> Result<Self, WireError> {
        if address == 0
            || surface == 0
            || pid == 0
            || pid > i32::MAX as u32
            || deadline_ns == 0
            || extent.iter().any(|v| !v.is_finite() || *v <= 0.0)
        {
            return Err(WireError::InvalidRequest);
        }
        Self::new(
            50,
            sequence,
            generation,
            Outcome::Begun,
            &[
                address,
                u64::from(pid),
                deadline_ns,
                extent[0].to_bits(),
                extent[1].to_bits(),
                surface,
            ],
        )
    }

    /// # Errors
    /// Rejects zero sequence/generation/deadline or negative/nonfinite points.
    pub fn motion(
        sequence: u64,
        generation: u64,
        deadline_ns: u64,
        point: [f64; 2],
    ) -> Result<Self, WireError> {
        if deadline_ns == 0 || point.iter().any(|v| !v.is_finite() || *v < 0.0) {
            return Err(WireError::InvalidRequest);
        }
        Self::new(
            51,
            sequence,
            generation,
            Outcome::MotionSent,
            &[deadline_ns, point[0].to_bits(), point[1].to_bits()],
        )
    }

    /// Explicit local button authority; ordinary BEGIN stays motion-only.
    /// # Errors
    /// Rejects the same invalid binding and lifetime fields as `begin`.
    pub fn begin_buttons(
        sequence: u64,
        generation: u64,
        address: u64,
        pid: u32,
        deadline_ns: u64,
        extent: [f64; 2],
        surface: u64,
    ) -> Result<Self, WireError> {
        let mut request = Self::begin(
            sequence,
            generation,
            address,
            pid,
            deadline_ns,
            extent,
            surface,
        )?;
        request.bytes[6..8].copy_from_slice(&56_u16.to_le_bytes());
        Ok(request)
    }

    /// Explicit local button and wheel authority; older begins do not grant wheel.
    /// # Errors
    /// Rejects the same invalid native binding and lifetime as `begin`.
    pub fn begin_buttons_wheel(
        sequence: u64,
        generation: u64,
        address: u64,
        pid: u32,
        deadline_ns: u64,
        extent: [f64; 2],
        surface: u64,
    ) -> Result<Self, WireError> {
        let mut request = Self::begin(
            sequence,
            generation,
            address,
            pid,
            deadline_ns,
            extent,
            surface,
        )?;
        request.bytes[6..8].copy_from_slice(&58_u16.to_le_bytes());
        Ok(request)
    }

    /// Window-local point plus signed [up, right] wheel units (120 per detent).
    /// # Errors
    /// Rejects invalid identity/deadline/point, zero scroll or unrepresentable axes.
    pub fn wheel(
        sequence: u64,
        generation: u64,
        deadline_ns: u64,
        point: [f64; 2],
        delta120: [i32; 2],
    ) -> Result<Self, WireError> {
        if deadline_ns == 0
            || point.iter().any(|v| !v.is_finite() || *v < 0.0)
            || delta120 == [0, 0]
            || delta120
                .iter()
                .any(|v| !(-MAX_WHEEL_120..=MAX_WHEEL_120).contains(v))
        {
            return Err(WireError::InvalidRequest);
        }
        let low = u64::from(u32::from_le_bytes(delta120[0].to_le_bytes()));
        let high = u64::from(u32::from_le_bytes(delta120[1].to_le_bytes()));
        Self::new(
            57,
            sequence,
            generation,
            Outcome::WheelSent,
            &[
                deadline_ns,
                point[0].to_bits(),
                point[1].to_bits(),
                low | (high << 32),
            ],
        )
    }

    /// # Errors
    /// Rejects a zero sequence or generation.
    pub fn end(sequence: u64, generation: u64) -> Result<Self, WireError> {
        Self::new(52, sequence, generation, Outcome::Ended, &[])
    }

    /// Retire the exact generation and release all recorded keys/buttons while
    /// leaving current focus installed, for temporary selection replacement.
    /// This retains no input authority. Ordinary `end` restores prior focus.
    /// # Errors
    /// Rejects zero sequence or generation, like `end`.
    pub fn end_preserving_focus(sequence: u64, generation: u64) -> Result<Self, WireError> {
        Self::new(62, sequence, generation, Outcome::Ended, &[])
    }

    /// # Errors
    /// Rejects invalid identity/deadline/point or noncanonical button/transition.
    pub fn button(
        sequence: u64,
        generation: u64,
        deadline_ns: u64,
        point: [f64; 2],
        button: u32,
        state: u32,
    ) -> Result<Self, WireError> {
        if deadline_ns == 0
            || point.iter().any(|v| !v.is_finite() || *v < 0.0)
            || !(1..=5).contains(&button)
            || !(1..=2).contains(&state)
        {
            return Err(WireError::InvalidRequest);
        }
        Self::new(
            55,
            sequence,
            generation,
            Outcome::ButtonSent,
            &[
                deadline_ns,
                point[0].to_bits(),
                point[1].to_bits(),
                u64::from(button) | (u64::from(state) << 32),
            ],
        )
    }

    #[must_use]
    pub fn packet(&self) -> &[u8] {
        &self.bytes
    }

    /// Returns the native envelope sequence separately; it is not the request
    /// sequence echoed in the payload. A transport write alone is no outcome.
    ///
    /// # Errors
    /// Rejects malformed packets, mismatched request identities and wrong result kinds.
    pub fn complete(self, packet: &[u8]) -> Result<(u64, Outcome), WireError> {
        if packet.len() != HEADER + 24
            || &packet[..4] != b"VFHY"
            || u16::from_le_bytes(field(packet, 4)?) != 1
            || u16::from_le_bytes(field(packet, 6)?) != RESULT
            || u32::from_le_bytes(field(packet, 8)?) != 24
            || packet[40..44] != [0; 4]
        {
            return Err(WireError::InvalidPacket);
        }
        let read = |offset| field(packet, offset).map(u64::from_le_bytes);
        let envelope_sequence = read(12)?;
        if envelope_sequence == 0 {
            return Err(WireError::InvalidPacket);
        }
        if read(20)? != self.generation || read(28)? != self.sequence {
            return Err(WireError::WrongIdentity);
        }
        let outcome = match u32::from_le_bytes(field(packet, 36)?) {
            0 => Outcome::Rejected,
            1 => Outcome::Begun,
            2 => Outcome::MotionSent,
            3 => Outcome::Ended,
            4 => Outcome::ButtonSent,
            5 => Outcome::WheelSent,
            6 => Outcome::KeySent,
            _ => return Err(WireError::WrongResult),
        };
        if outcome != Outcome::Rejected && outcome != self.expected {
            return Err(WireError::WrongResult);
        }
        Ok((envelope_sequence, outcome))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn preserve_focus_end_has_distinct_opcode_and_exact_cleanup_receipt() {
        let make = || Request::end_preserving_focus(8, 7).unwrap();
        let ordinary = Request::end(8, 7).unwrap();
        let mut expected = ordinary.packet().to_vec();
        expected[6..8].copy_from_slice(&62_u16.to_le_bytes());
        assert_eq!(make().packet(), expected);
        assert_eq!(make().complete(&reply(3)), Ok((9, Outcome::Ended)));
        assert_eq!(make().complete(&reply(0)), Ok((9, Outcome::Rejected)));
        for wrong in [1, 2, 4, 5, 6] {
            assert_eq!(make().complete(&reply(wrong)), Err(WireError::WrongResult));
        }
        assert!(Request::end_preserving_focus(0, 7).is_err());
        assert!(Request::end_preserving_focus(8, 0).is_err());
    }
    #[test]
    fn resize_rebind_has_distinct_opcode_and_requires_exact_begin_receipt() {
        let make =
            || Request::rebind_resized(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        let begin = Request::begin(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        let mut expected = begin.packet().to_vec();
        expected[6..8].copy_from_slice(&61_u16.to_le_bytes());
        assert_eq!(make().packet(), expected);
        assert_eq!(make().complete(&reply(1)), Ok((9, Outcome::Begun)));
        assert_eq!(make().complete(&reply(0)), Ok((9, Outcome::Rejected)));
        for wrong in [2, 3, 4, 5, 6] {
            assert_eq!(make().complete(&reply(wrong)), Err(WireError::WrongResult));
        }
        for extent in [
            [0.0, 1.0],
            [-1.0, 1.0],
            [1.0, f64::INFINITY],
            [f64::NAN, 1.0],
        ] {
            assert!(Request::rebind_resized(8, 7, 1, 123, 900, extent, 2).is_err());
        }
        for (sequence, generation, address, pid, deadline, surface) in [
            (0, 7, 1, 123, 900, 2),
            (8, 0, 1, 123, 900, 2),
            (8, 7, 0, 123, 900, 2),
            (8, 7, 1, 0, 900, 2),
            (8, 7, 1, u32::MAX, 900, 2),
            (8, 7, 1, 123, 0, 2),
            (8, 7, 1, 123, 900, 0),
        ] {
            assert!(
                Request::rebind_resized(
                    sequence,
                    generation,
                    address,
                    pid,
                    deadline,
                    [1.0, 1.0],
                    surface
                )
                .is_err()
            );
        }
    }

    use super::*;
    #[test]
    fn direct_keyboard_capability_and_key_payload_are_explicit() {
        let begin =
            Request::begin_direct_keyboard(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        assert_eq!(&begin.packet()[6..8], &59_u16.to_le_bytes());
        assert_eq!(begin.packet().len(), HEADER + 56);
        assert_eq!(begin.complete(&reply(1)), Ok((9, Outcome::Begun)));
        for (state, repeat) in [(1, false), (2, false), (1, true)] {
            let key = Request::key(8, 7, 900, [7, 0xe1], state, repeat).unwrap();
            assert_eq!(&key.packet()[6..8], &60_u16.to_le_bytes());
            assert_eq!(key.packet().len(), HEADER + 32);
            assert_eq!(&key.packet()[28..36], &900_u64.to_le_bytes());
            assert_eq!(&key.packet()[36..40], &7_u32.to_le_bytes());
            assert_eq!(&key.packet()[40..44], &0xe1_u32.to_le_bytes());
            assert_eq!(&key.packet()[44..48], &state.to_le_bytes());
            assert_eq!(&key.packet()[48..52], &u32::from(repeat).to_le_bytes());
            assert_eq!(key.complete(&reply(6)), Ok((9, Outcome::KeySent)));
        }
        for status in 1..=5 {
            assert_eq!(
                Request::key(8, 7, 900, [7, 4], 1, false)
                    .unwrap()
                    .complete(&reply(status)),
                Err(WireError::WrongResult)
            );
        }
        assert_eq!(
            Request::motion(8, 7, 900, [0.0, 0.0])
                .unwrap()
                .complete(&reply(6)),
            Err(WireError::WrongResult)
        );
        assert_eq!(
            Request::key(8, 7, 900, [7, 4], 1, false)
                .unwrap()
                .complete(&reply(0)),
            Ok((9, Outcome::Rejected))
        );
        for (sequence, generation, deadline, usage, state, repeat) in [
            (0, 7, 900, [7, 4], 1, false),
            (8, 0, 900, [7, 4], 1, false),
            (8, 7, 0, [7, 4], 1, false),
            (8, 7, 900, [0, 4], 1, false),
            (8, 7, 900, [7, 0], 1, false),
            (8, 7, 900, [7, 4], 0, false),
            (8, 7, 900, [7, 4], 3, false),
            (8, 7, 900, [7, 4], 2, true),
        ] {
            assert!(Request::key(sequence, generation, deadline, usage, state, repeat).is_err());
        }
    }
    fn reply(status: u32) -> Vec<u8> {
        let mut bytes = b"VFHY".to_vec();
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&53_u16.to_le_bytes());
        bytes.extend_from_slice(&24_u32.to_le_bytes());
        bytes.extend_from_slice(&9_u64.to_le_bytes());
        bytes.extend_from_slice(&7_u64.to_le_bytes());
        bytes.extend_from_slice(&8_u64.to_le_bytes());
        bytes.extend_from_slice(&status.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes
    }
    #[test]
    fn wheel_has_explicit_grant_signed_axes_and_exact_result() {
        let grant =
            Request::begin_buttons_wheel(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        assert_eq!(&grant.packet()[6..8], &58_u16.to_le_bytes());
        assert_eq!(grant.packet().len(), 76);
        assert_eq!(grant.complete(&reply(1)), Ok((9, Outcome::Begun)));
        for delta in [
            [30, -60],
            [-120, 0],
            [0, 1],
            [MAX_WHEEL_120, -MAX_WHEEL_120],
        ] {
            let request = Request::wheel(8, 7, 900, [49.0, 99.0], delta).unwrap();
            assert_eq!(request.packet().len(), 60);
            assert_eq!(&request.packet()[6..8], &57_u16.to_le_bytes());
            assert_eq!(&request.packet()[52..56], &delta[0].to_le_bytes());
            assert_eq!(&request.packet()[56..60], &delta[1].to_le_bytes());
            assert_eq!(request.complete(&reply(5)), Ok((9, Outcome::WheelSent)));
            for wrong in [1, 2, 3, 4, 6] {
                assert_eq!(
                    Request::wheel(8, 7, 900, [49.0, 99.0], delta)
                        .unwrap()
                        .complete(&reply(wrong)),
                    Err(WireError::WrongResult)
                );
            }
        }
        for delta in [
            [0, 0],
            [i32::MIN, 0],
            [0, i32::MAX],
            [MAX_WHEEL_120 + 1, 0],
            [0, -MAX_WHEEL_120 - 1],
        ] {
            assert!(Request::wheel(8, 7, 900, [49.0, 99.0], delta).is_err());
        }
        assert!(Request::wheel(0, 7, 900, [0.0, 0.0], [1, 0]).is_err());
        assert!(Request::wheel(8, 0, 900, [0.0, 0.0], [1, 0]).is_err());
        assert!(Request::wheel(8, 7, 0, [0.0, 0.0], [1, 0]).is_err());
        assert!(Request::wheel(8, 7, 900, [-1.0, 0.0], [1, 0]).is_err());
        assert!(Request::wheel(8, 7, 900, [0.0, f64::INFINITY], [1, 0]).is_err());
        assert_eq!(
            Request::motion(8, 7, 900, [0.0, 0.0])
                .unwrap()
                .complete(&reply(5)),
            Err(WireError::WrongResult)
        );
        assert_eq!(
            Request::button(8, 7, 900, [0.0, 0.0], 1, 1)
                .unwrap()
                .complete(&reply(5)),
            Err(WireError::WrongResult)
        );
    }
    #[test]
    fn command_layout_matches_native_sizes_and_offsets() {
        let request = Request::begin(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        assert_eq!(request.packet().len(), 76);
        assert_eq!(&request.packet()[68..76], &0x5678_u64.to_le_bytes());
        assert_eq!(&request.packet()[20..28], &7_u64.to_le_bytes());
        assert_eq!(&request.packet()[28..36], &0x1234_u64.to_le_bytes());
        assert_eq!(&request.packet()[36..44], &123_u64.to_le_bytes());
        assert_eq!(&request.packet()[52..60], &791_f64.to_le_bytes());
        assert_eq!(request.complete(&reply(1)), Ok((9, Outcome::Begun)));
        assert_eq!(
            Request::motion(8, 7, 900, [0.0, 1.0])
                .unwrap()
                .packet()
                .len(),
            52
        );
        assert_eq!(Request::end(8, 7).unwrap().packet().len(), 28);
    }
    #[test]
    fn window_buttons_have_distinct_layout_and_exact_native_results() {
        let request =
            Request::begin_buttons(8, 7, 0x1234, 123, 900, [791.0, 598.0], 0x5678).unwrap();
        assert_eq!(request.packet().len(), 76);
        assert_eq!(&request.packet()[6..8], &56_u16.to_le_bytes());
        assert_eq!(request.complete(&reply(1)), Ok((9, Outcome::Begun)));
        for button in 0..=6 {
            for state in 0..=3 {
                let request = Request::button(8, 7, 900, [49.0, 99.0], button, state);
                if !(1..=5).contains(&button) || !(1..=2).contains(&state) {
                    assert!(request.is_err());
                    continue;
                }
                let request = request.unwrap();
                assert_eq!(request.packet().len(), 60);
                assert_eq!(&request.packet()[6..8], &55_u16.to_le_bytes());
                assert_eq!(&request.packet()[52..56], &button.to_le_bytes());
                assert_eq!(&request.packet()[56..60], &state.to_le_bytes());
                assert_eq!(request.complete(&reply(4)), Ok((9, Outcome::ButtonSent)));
                assert_eq!(
                    Request::button(8, 7, 900, [49.0, 99.0], button, state)
                        .unwrap()
                        .complete(&reply(2)),
                    Err(WireError::WrongResult)
                );
            }
        }
        assert!(Request::button(8, 7, 0, [49.0, 99.0], 1, 1).is_err());
        assert!(Request::button(8, 7, 900, [f64::NAN, 99.0], 1, 1).is_err());
        assert_eq!(
            Request::motion(8, 7, 900, [49.0, 99.0])
                .unwrap()
                .complete(&reply(4)),
            Err(WireError::WrongResult)
        );
    }

    #[test]
    fn rejects_bad_commands_and_mismatched_results() {
        assert!(Request::begin(8, 7, 1, 0, 900, [1.0, 1.0], 2).is_err());
        assert!(Request::begin(8, 7, 1, 123, 900, [1.0, 1.0], 0).is_err());
        assert!(Request::motion(8, 7, 900, [f64::NAN, 0.0]).is_err());
        assert!(Request::end(0, 7).is_err());
        assert_eq!(
            Request::end(8, 7).unwrap().complete(&reply(2)),
            Err(WireError::WrongResult)
        );
        assert_eq!(
            Request::end(8, 7).unwrap().complete(&reply(0)),
            Ok((9, Outcome::Rejected))
        );
        for offset in [20, 28] {
            let mut bytes = reply(3);
            bytes[offset] ^= 1;
            assert_eq!(
                Request::end(8, 7).unwrap().complete(&bytes),
                Err(WireError::WrongIdentity)
            );
        }
        for size in 0..44 {
            assert_eq!(
                Request::end(8, 7).unwrap().complete(&reply(3)[..size]),
                Err(WireError::InvalidPacket)
            );
        }
        let mut bytes = reply(3);
        bytes[40] = 1;
        assert_eq!(
            Request::end(8, 7).unwrap().complete(&bytes),
            Err(WireError::InvalidPacket)
        );
    }
}
