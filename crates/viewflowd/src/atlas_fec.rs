//! Negotiated application-payload FEC. VFF1 parity is QUIC-authenticated like VFMD.
//! Data remains VFMD v1; malformed parity never enters ordinary admission.
use bytes::{BufMut, Bytes, BytesMut};
use reed_solomon_simd::{ReedSolomonDecoder, ReedSolomonEncoder};
use viewflow_transport::{MediaDatagram, MediaPlane};

pub(crate) const DATA: usize = 16;
const MAX_CHUNKS: usize = 8192;
const PARITY: usize = 8;
pub(crate) const HEADER: usize = 74;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Meta {
    packet: MediaDatagram, // Empty payload, chunk_index = first data index.
    generation: u64,
    lane: u8,
    block: usize,
    blocks: usize,
    d: usize,
    p: usize,
    size: usize,
    last: usize,
}
impl Meta {
    fn parse(bytes: Bytes) -> Option<(Self, usize, Bytes)> {
        if bytes.len() < HEADER || &bytes[..4] != b"VFF1" {
            return None;
        }
        if bytes[4] != 1 || bytes[6..8] != [0, 0] {
            return None;
        }
        let packet = MediaDatagram {
            plane: MediaPlane::try_from(bytes[5]).ok()?,
            window_id: viewflow_protocol::Id128(u128::from_be_bytes(bytes[8..24].try_into().ok()?)),
            frame_id: u64::from_be_bytes(bytes[24..32].try_into().ok()?),
            geometry_epoch: u64::from_be_bytes(bytes[32..40].try_into().ok()?),
            chunk_index: u16::from_be_bytes(bytes[40..42].try_into().ok()?),
            chunk_count: u16::from_be_bytes(bytes[42..44].try_into().ok()?),
            source_submitted_ns: u64::from_be_bytes(bytes[44..52].try_into().ok()?),
            payload: Bytes::new(),
        };
        let generation = u64::from_be_bytes(bytes[52..60].try_into().ok()?);
        let lane = bytes[60];
        let block = usize::from(u16::from_be_bytes(bytes[61..63].try_into().ok()?));
        let blocks = usize::from(u16::from_be_bytes(bytes[63..65].try_into().ok()?));
        let d = usize::from(bytes[65]);
        let p = usize::from(bytes[66]);
        let index = usize::from(bytes[67]);
        let size = usize::from(u16::from_be_bytes(bytes[68..70].try_into().ok()?));
        let last = usize::from(u16::from_be_bytes(bytes[70..72].try_into().ok()?));
        let count = usize::from(packet.chunk_count);
        if bytes[72..74] != [0, 0]
            || lane > 1
            || !matches!(packet.plane, MediaPlane::Color | MediaPlane::Alpha)
            || count == 0
            || count > MAX_CHUNKS
            || blocks != count.div_ceil(DATA)
            || block >= blocks
            || usize::from(packet.chunk_index) != block * DATA
            || d != (count - block * DATA).min(DATA)
            || p == 0
            || p > PARITY
            || index >= p
            || size == 0
            || size > 16384
            || size % 2 != 0
            || last == 0
            || last > size
            || (block + 1 < blocks && last != size)
            || bytes.len() != HEADER + size
        {
            return None;
        }
        Some((
            Self {
                packet,
                generation,
                lane,
                block,
                blocks,
                d,
                p,
                size,
                last,
            },
            index,
            bytes.slice(HEADER..),
        ))
    }
    fn encode(&self, index: usize, payload: &[u8]) -> Bytes {
        let mut out = BytesMut::with_capacity(HEADER + payload.len());
        out.put_slice(b"VFF1");
        out.put_u8(1);
        out.put_u8(self.packet.plane as u8);
        out.put_u16(0);
        out.put_u128(self.packet.window_id.0);
        out.put_u64(self.packet.frame_id);
        out.put_u64(self.packet.geometry_epoch);
        out.put_u16(self.packet.chunk_index);
        out.put_u16(self.packet.chunk_count);
        out.put_u64(self.packet.source_submitted_ns);
        out.put_u64(self.generation);
        out.put_u8(self.lane);
        out.put_u16(self.block as u16);
        out.put_u16(self.blocks as u16);
        out.put_u8(self.d as u8);
        out.put_u8(self.p as u8);
        out.put_u8(index as u8);
        out.put_u16(self.size as u16);
        out.put_u16(self.last as u16);
        out.put_u16(0);
        out.put_slice(payload);
        out.freeze()
    }
}

#[derive(Default)]
pub(crate) struct Encoder {
    rs: Option<ReedSolomonEncoder>,
    padding: Vec<u8>,
    pub packets: Vec<Bytes>,
}
impl Encoder {
    pub fn encode(
        &mut self,
        data: &[MediaDatagram],
        generation: u64,
        lane: u8,
        percent: u32,
        size: usize,
    ) -> anyhow::Result<()> {
        self.packets.clear();
        let d = data.len();
        if d == 0 || percent == 0 {
            return Ok(());
        }
        // Fill the peer's datagram budget even for D=1: otherwise QUIC can
        // pack a short original and its short parity into the same packet,
        // losing both together. Padding never enters the restored payload.
        let p = (d * percent as usize).div_ceil(100).clamp(1, PARITY);
        anyhow::ensure!(
            d <= DATA && size % 2 == 0 && size <= 16384,
            "invalid FEC block"
        );
        if let Some(rs) = &mut self.rs {
            rs.reset(d, p, size)?;
        } else {
            self.rs = Some(ReedSolomonEncoder::new(d, p, size)?);
        }
        let rs = self.rs.as_mut().expect("initialized encoder");
        for packet in data {
            anyhow::ensure!(packet.payload.len() <= size, "oversize FEC shard");
            if packet.payload.len() == size {
                rs.add_original_shard(&packet.payload)?;
            } else {
                self.padding.resize(size, 0);
                self.padding.fill(0);
                self.padding[..packet.payload.len()].copy_from_slice(&packet.payload);
                rs.add_original_shard(&self.padding)?;
            }
        }
        let mut packet = data[0].clone();
        packet.payload = Bytes::new();
        let meta = Meta {
            generation,
            lane,
            block: usize::from(packet.chunk_index) / DATA,
            blocks: usize::from(packet.chunk_count).div_ceil(DATA),
            packet,
            d,
            p,
            size,
            last: data[d - 1].payload.len(),
        };
        for (index, shard) in rs.encode()?.recovery_iter().enumerate() {
            self.packets.push(meta.encode(index, shard));
        }
        Ok(())
    }
}

#[derive(Default)]
struct Plane {
    identity: Option<MediaDatagram>,
    data: Vec<Option<Bytes>>,
    parity: Vec<Option<Bytes>>,
    meta: Vec<Option<Meta>>,
    completed: Vec<bool>,
    rebuilt: bool,
    protected: bool,
    rebuilt_chunks: u64,
    repair_chunks: u64,
    bytes: usize,
}
fn same(a: &MediaDatagram, b: &MediaDatagram) -> bool {
    a.window_id == b.window_id
        && a.frame_id == b.frame_id
        && a.geometry_epoch == b.geometry_epoch
        && a.plane == b.plane
        && a.chunk_count == b.chunk_count
        && a.source_submitted_ns == b.source_submitted_ns
}
impl Plane {
    fn prepare(&mut self, packet: &MediaDatagram) -> bool {
        if self
            .identity
            .as_ref()
            .is_some_and(|v| packet.frame_id < v.frame_id)
        {
            return false;
        }
        if self
            .identity
            .as_ref()
            .is_none_or(|v| packet.frame_id > v.frame_id)
        {
            let mut identity = packet.clone();
            identity.payload = Bytes::new();
            self.identity = Some(identity);
            self.rebuilt = false;
            self.protected = false;
            self.rebuilt_chunks = 0;
            self.repair_chunks = 0;
            self.bytes = 0;
            self.data.clear();
            self.data.resize(usize::from(packet.chunk_count), None);
            let blocks = self.data.len().div_ceil(DATA);
            self.parity.clear();
            self.parity.resize(blocks * PARITY, None);
            self.meta.clear();
            self.meta.resize(blocks, None);
            self.completed.clear();
            self.completed.resize(blocks, false);
        }
        self.identity.as_ref().is_some_and(|v| same(v, packet))
    }
}
#[derive(Default)]
pub(crate) struct Receiver {
    planes: [Plane; 4],
    rs: Option<ReedSolomonDecoder>,
    padding: Vec<u8>,
    pub recovered: Vec<MediaDatagram>,
    pub parity_bytes: u64,
}
impl Receiver {
    pub fn protects(&mut self, packet: &MediaDatagram, lane: u8) {
        if let Some(i) = Self::plane(lane, packet.plane) {
            let state = &mut self.planes[i];
            if packet.chunk_count > 0 && usize::from(packet.chunk_count) <= MAX_CHUNKS && state.prepare(packet) {
                state.protected = true;
            }
        }
    }
    pub fn expects_parity(&self, frame: u64, lane: usize) -> bool {
        self.planes[lane * 2..lane * 2 + 2].iter().any(|p|
            p.identity.as_ref().is_some_and(|v| v.frame_id == frame)
                && (p.protected || p.meta.iter().any(Option::is_some)))
    }

    pub fn observed(&self, frame: u64, lane: usize) -> (u64, u64) {
        self.planes[lane * 2..lane * 2 + 2]
            .iter()
            .filter(|p| p.identity.as_ref().is_some_and(|v| v.frame_id == frame))
            .fold((0, 0), |(total, missing), p| {
                (
                    total + u64::from(p.identity.as_ref().expect("filtered identity").chunk_count),
                    missing + p.rebuilt_chunks + p.repair_chunks,
                )
            })
    }

    pub fn rebuilt_frame(&self, frame: u64, lane: usize) -> bool {
        self.planes[lane * 2..lane * 2 + 2]
            .iter()
            .any(|p| p.rebuilt && p.identity.as_ref().is_some_and(|v| v.frame_id == frame))
    }

    fn plane(lane: u8, plane: MediaPlane) -> Option<usize> {
        if lane > 1 {
            return None;
        }
        Some(
            usize::from(lane) * 2
                + match plane {
                    MediaPlane::Color => 0,
                    MediaPlane::Alpha => 1,
                    _ => return None,
                },
        )
    }
    #[cfg(test)]
    pub fn data(&mut self, packet: &MediaDatagram, lane: u8) {
        self.data_repair(packet, lane, false);
    }
    pub fn data_repair(&mut self, packet: &MediaDatagram, lane: u8, repair: bool) {
        self.recovered.clear();
        let Some(i) = Self::plane(lane, packet.plane) else {
            return;
        };
        if packet.chunk_count == 0
            || usize::from(packet.chunk_count) > MAX_CHUNKS
            || packet.chunk_index >= packet.chunk_count
        {
            return;
        }
        let state = &mut self.planes[i];
        if !state.prepare(packet) {
            return;
        }
        let slot = &mut state.data[usize::from(packet.chunk_index)];
        if slot.is_none() && state.bytes.saturating_add(packet.payload.len()) <= 64 * 1024 * 1024 {
            state.bytes += packet.payload.len();
            state.repair_chunks += u64::from(repair);
            *slot = Some(packet.payload.clone());
        }
        let _ = self.restore(i, usize::from(packet.chunk_index) / DATA);
    }
    pub fn parity(
        &mut self,
        bytes: Bytes,
        stream: viewflow_protocol::Id128,
        generation: u64,
        activity: bool,
    ) {
        self.recovered.clear();
        let Some((meta, index, payload)) = Meta::parse(bytes) else {
            return;
        };
        if meta.packet.window_id != stream
            || meta.generation != generation
            || meta.lane
                != if activity {
                    (meta.packet.frame_id % 2) as u8
                } else {
                    0
                }
        {
            return;
        }
        let Some(i) = Self::plane(meta.lane, meta.packet.plane) else {
            return;
        };
        let state = &mut self.planes[i];
        if !state.prepare(&meta.packet) {
            return;
        }
        let block = meta.block;
        if state.meta[block].as_ref().is_some_and(|old| old != &meta) {
            return;
        }
        state.meta[block] = Some(meta);
        let slot = &mut state.parity[block * PARITY + index];
        if slot.is_none() {
            self.parity_bytes += (HEADER + payload.len()) as u64;
            *slot = Some(payload);
        }
        let _ = self.restore(i, block); // Malformed/inconsistent FEC is strictly local.
    }
    fn restore(&mut self, plane: usize, block: usize) -> anyhow::Result<()> {
        let state = &mut self.planes[plane];
        if state.completed[block] {
            return Ok(());
        }
        let Some(meta) = &state.meta[block] else {
            return Ok(());
        };
        let start = block * DATA;
        let data = &state.data[start..start + meta.d];
        let missing_bytes: usize = data
            .iter()
            .enumerate()
            .filter(|(_, v)| v.is_none())
            .map(|(index, _)| {
                if index + 1 == meta.d {
                    meta.last
                } else {
                    meta.size
                }
            })
            .sum();
        anyhow::ensure!(
            state.bytes.saturating_add(missing_bytes) <= 64 * 1024 * 1024,
            "FEC plane memory bound"
        );
        let present = data.iter().filter(|v| v.is_some()).count();
        if present == meta.d {
            state.completed[block] = true;
            return Ok(());
        }
        let parity = &state.parity[block * PARITY..block * PARITY + meta.p];
        if present + parity.iter().filter(|v| v.is_some()).count() < meta.d {
            return Ok(());
        }
        if let Some(rs) = &mut self.rs {
            rs.reset(meta.d, meta.p, meta.size)?;
        } else {
            self.rs = Some(ReedSolomonDecoder::new(meta.d, meta.p, meta.size)?);
        }
        let rs = self.rs.as_mut().expect("initialized decoder");
        for (index, bytes) in data.iter().enumerate() {
            if let Some(bytes) = bytes {
                let len = if index + 1 == meta.d {
                    meta.last
                } else {
                    meta.size
                };
                anyhow::ensure!(bytes.len() == len, "inconsistent FEC data size");
                if bytes.len() == meta.size {
                    rs.add_original_shard(index, bytes)?;
                } else {
                    self.padding.resize(meta.size, 0);
                    self.padding.fill(0);
                    self.padding[..bytes.len()].copy_from_slice(bytes);
                    rs.add_original_shard(index, &self.padding)?;
                }
            }
        }
        for (index, bytes) in parity.iter().enumerate() {
            if let Some(bytes) = bytes {
                rs.add_recovery_shard(index, bytes)?;
            }
        }
        for (index, bytes) in rs.decode()?.restored_original_iter() {
            let mut packet = meta.packet.clone();
            packet.chunk_index = (start + index) as u16;
            let len = if index + 1 == meta.d {
                meta.last
            } else {
                meta.size
            };
            packet.payload = Bytes::copy_from_slice(&bytes[..len]);
            state.bytes += packet.payload.len();
            state.rebuilt_chunks += 1;
            state.data[start + index] = Some(packet.payload.clone());
            self.recovered.push(packet);
        }
        state.completed[block] = true;
        state.rebuilt = true;
        Ok(())
    }
}

/// Negotiated application-media feedback excludes QUIC probe/ACK loss.
/// Two lossy windows gate activation; the shared controller gates congestion.
pub(crate) struct Adaptive {
    previous: (u64, u64),
    sampled: std::time::Instant,
    loss_at: std::time::Instant,
    percent: u32,
    loss_windows: u8,
}
impl Default for Adaptive {
    fn default() -> Self {
        Self {
            previous: (0, 0),
            sampled: std::time::Instant::now(),
            loss_at: std::time::Instant::now(),
            percent: 0,
            loss_windows: 0,
        }
    }
}
impl Adaptive {
    #[cfg(test)]
    pub fn test_percent(&mut self, percent: u32) {
        self.percent = percent;
    }
    pub fn update(&mut self, lost: u64, sent: u64, congested: bool) -> u32 {
        let now = std::time::Instant::now();
        if now.duration_since(self.sampled).as_millis() >= 1000 {
            let missing = lost.saturating_sub(self.previous.0);
            let packets = sent.saturating_sub(self.previous.1);
            if packets < 128 {
                if now.duration_since(self.loss_at).as_secs() >= 5 {
                    self.percent = self.percent.saturating_sub(10);
                    self.loss_at = now;
                }
                return if congested { 0 } else { self.percent };
            }
            self.previous = (lost, sent);
            self.sampled = now;
            if packets >= 128
                && missing >= 3
                && missing.saturating_mul(1000) >= packets.saturating_mul(5)
            {
                self.loss_windows = self.loss_windows.saturating_add(1);
                self.loss_at = now;
                if self.loss_windows >= 2 && !congested {
                    self.percent =
                        self.percent
                            .max(if self.percent > 0 && missing * 100 >= packets * 2 {
                                20
                            } else {
                                10
                            });
                }
            } else {
                self.loss_windows = 0;
                if now.duration_since(self.loss_at).as_secs() >= 5 {
                    self.percent = self.percent.saturating_sub(10);
                    self.loss_at = now;
                }
            }
        }
        if congested { 0 } else { self.percent }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn data(count: usize, last: usize) -> Vec<MediaDatagram> {
        (0..count)
            .map(|i| MediaDatagram {
                window_id: viewflow_protocol::Id128(99),
                frame_id: 4,
                geometry_epoch: 1,
                plane: MediaPlane::Color,
                chunk_index: i as u16,
                chunk_count: count as u16,
                source_submitted_ns: 100,
                payload: Bytes::from(
                    (0..if i + 1 == count { last } else { 1100 })
                        .map(|j| ((i * 47 + j) % 251) as u8)
                        .collect::<Vec<_>>(),
                ),
            })
            .collect()
    }
    fn run(
        data: &[MediaDatagram],
        parity: &[Bytes],
        missing: &[usize],
        reverse: bool,
    ) -> (Vec<Option<Bytes>>, Receiver) {
        let mut receiver = Receiver::default();
        let mut result = vec![None; data.len()];
        let mut events: Vec<_> = (0..data.len())
            .filter(|i| !missing.contains(i))
            .map(|i| (false, i))
            .chain(
                (0..parity.len())
                    .filter(|i| !missing.contains(&(i + data.len())))
                    .map(|i| (true, i)),
            )
            .collect();
        if reverse {
            events.reverse();
        }
        for (is_parity, index) in events {
            for _ in 0..2 {
                // duplicates never count as additional shards
                if is_parity {
                    receiver.parity(parity[index].clone(), viewflow_protocol::Id128(99), 1, true);
                } else {
                    receiver.data(&data[index], 0);
                    result[index] = Some(data[index].payload.clone());
                }
                for p in &receiver.recovered {
                    result[usize::from(p.chunk_index)] = Some(p.payload.clone());
                }
            }
        }
        (result, receiver)
    }
    #[test]
    fn every_two_erasure_pattern_padding_parity_loss_duplicates_and_reordering() {
        let data = data(8, 713);
        let mut encoder = Encoder::default();
        encoder.encode(&data, 1, 0, 20, 1100).unwrap();
        assert_eq!(encoder.packets.len(), 2);
        for reverse in [false, true] {
            for a in 0..=10 {
                for b in a..=10 {
                    let losses: Vec<_> = [a, b].into_iter().filter(|i| *i < 10).collect();
                    let (result, _) = run(&data, &encoder.packets, &losses, reverse);
                    assert_eq!(
                        result,
                        data.iter()
                            .map(|v| Some(v.payload.clone()))
                            .collect::<Vec<_>>(),
                        "losses={losses:?} reverse={reverse}"
                    );
                }
            }
        }
        let (result, _) = run(&data, &encoder.packets, &[0, 3, 7], false);
        assert_eq!(result.iter().filter(|v| v.is_none()).count(), 3); // W1 requests precisely these.
    }
    #[test]
    fn many_blocks_have_no_four_block_cap_and_preserve_short_last_shard() {
        let data = data(205, 1);
        let mut encoder = Encoder::default();
        let mut parity = Vec::new();
        for block in data.chunks(DATA) {
            encoder.encode(block, 1, 0, 20, 1100).unwrap();
            parity.extend(encoder.packets.iter().cloned());
        }
        let missing: Vec<_> = (0..data.len()).step_by(DATA).collect();
        let (result, _) = run(&data, &parity, &missing, true);
        assert_eq!(
            result,
            data.iter()
                .map(|v| Some(v.payload.clone()))
                .collect::<Vec<_>>()
        );
    }
    #[test]
    fn maximum_parity_recovers_first_middle_last_and_p_plus_one_stays_missing() {
        let data = data(DATA, 713);
        let mut encoder = Encoder::default();
        encoder.encode(&data, 1, 0, 20, 1100).unwrap();
        assert_eq!(encoder.packets.len(), 4);
        let missing = [0, 7, 8, 15];
        for count in 0..=4 {
            let (result, _) = run(&data, &encoder.packets, &missing[..count], true);
            assert_eq!(
                result,
                data.iter()
                    .map(|v| Some(v.payload.clone()))
                    .collect::<Vec<_>>()
            );
        }
        let (result, _) = run(&data, &encoder.packets, &[0, 1, 7, 8, 15], false);
        assert_eq!(result.iter().filter(|v| v.is_none()).count(), 5);
    }
    #[test]
    fn one_short_shard_recovers_when_all_original_data_is_lost() {
        let data = data(1, 1);
        let mut encoder = Encoder::default();
        encoder.encode(&data, 1, 0, 10, 1100).unwrap();
        assert_eq!(encoder.packets[0].len(), HEADER + 1100);
        assert!(data[0].encode().len() + encoder.packets[0].len() > HEADER + 1100);
        let (result, _) = run(&data, &encoder.packets, &[0], false);
        assert_eq!(result, vec![Some(data[0].payload.clone())]);
    }

    #[test]
    fn malformed_parity_and_wrong_generation_lane_plane_are_local() {
        let data = data(8, 17);
        let mut encoder = Encoder::default();
        encoder.encode(&data, 1, 0, 20, 1100).unwrap();
        for at in [4, 5, 6, 40, 42, 52, 60, 61, 63, 65, 66, 67, 68, 70, 72] {
            let mut bytes = encoder.packets[0].to_vec();
            bytes[at] = 255;
            let mut receiver = Receiver::default();
            receiver.parity(bytes.into(), viewflow_protocol::Id128(99), 1, true);
            assert!(receiver.recovered.is_empty());
            assert_eq!(receiver.parity_bytes, 0, "byte={at}");
        }
        let mut receiver = Receiver::default();
        for len in 0..HEADER {
            receiver.parity(
                encoder.packets[0].slice(..len),
                viewflow_protocol::Id128(99),
                1,
                true,
            );
        }
        receiver.parity(
            encoder.packets[0].clone(),
            viewflow_protocol::Id128(99),
            2,
            true,
        );
        assert_eq!(receiver.parity_bytes, 0);
        for packet in &data {
            receiver.data(packet, 0);
        }
        // Inconsistent D/P/length for an already described block cannot change it.
        receiver.parity(
            encoder.packets[0].clone(),
            viewflow_protocol::Id128(99),
            1,
            true,
        );
        assert!(receiver.recovered.is_empty());
    }
    #[test]
    fn independent_planes_lanes_frames_and_metadata_do_not_mix() {
        let mut receiver = Receiver::default();
        let mut encoder = Encoder::default();
        for lane in 0..2 {
            for plane in [MediaPlane::Color, MediaPlane::Alpha] {
                let mut data = data(8, 713);
                for packet in &mut data {
                    packet.frame_id += u64::from(lane);
                    packet.plane = plane;
                }
                encoder.encode(&data, 1, lane, 20, 1100).unwrap();
                for packet in &data[1..] {
                    receiver.data(packet, lane);
                }
                receiver.parity(
                    encoder.packets[0].clone(),
                    viewflow_protocol::Id128(99),
                    1,
                    true,
                );
                assert_eq!(receiver.recovered.len(), 1);
                assert_eq!(receiver.recovered[0], data[0]);
            }
        }
        let old = data(8, 713);
        receiver.data(&old[0], 1); // Does not replace lane 1's newer frame.
        assert!(receiver.recovered.is_empty());
    }
    #[test]
    fn feedback_counts_only_first_accepted_repairs_and_fec_not_nack_holes() {
        let packets = data(8, 713);
        let mut receiver = Receiver::default();
        receiver.data_repair(&packets[0], 0, true);
        receiver.data_repair(&packets[0], 0, true);
        receiver.data(&packets[0], 0);
        for packet in &packets[1..] {
            receiver.data(packet, 0);
        }
        assert_eq!(receiver.observed(4, 0), (8, 1));
        let mut next = packets[0].clone();
        next.frame_id = 6;
        receiver.data(&next, 0);
        receiver.data_repair(&next, 0, true); // Original arrived first: redundant repair is not loss.
        assert_eq!(receiver.observed(6, 0), (8, 0));
    }

    #[test]
    fn clean_and_congested_emit_zero_parity_and_hysteresis_holds() {
        let mut a = Adaptive::default();
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(0, 1000, false), 0);
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(10, 2000, false), 0);
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(20, 3000, false), 10);
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(60, 4000, false), 20);
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(60, 5000, false), 20);
        a.loss_at -= std::time::Duration::from_secs(6);
        a.sampled -= std::time::Duration::from_secs(1);
        assert_eq!(a.update(60, 6000, false), 10);
        assert_eq!(a.update(60, 6000, true), 0);
        assert_eq!(a.update(60, 6000, false), 10); // Resume the learned ratio without another warmup.
    }
    #[test]
    #[ignore = "owned CPU benchmark; run release --ignored --nocapture"]
    fn fec_cpu_cost() {
        for count in [64, 256, 1024] {
            let data = data(count, 713);
            let mut encoder = Encoder::default();
            let mut receiver = Receiver::default();
            let mut encode_us = Vec::new();
            let mut decode_us = Vec::new();
            for frame in 0..101 {
                let mut enc = std::time::Duration::ZERO;
                let mut dec = std::time::Duration::ZERO;
                for block in data.chunks(DATA) {
                    let start = std::time::Instant::now();
                    encoder.encode(block, 1, 0, 20, 1100).unwrap();
                    enc += start.elapsed();
                    // Change frame identity without allocating per data shard.
                    for packet in &block[1..] {
                        let mut packet = packet.clone();
                        packet.frame_id = frame + 4;
                        receiver.data(&packet, 0);
                    }
                    let start = std::time::Instant::now();
                    for parity in &encoder.packets {
                        let mut parity = parity.to_vec();
                        parity[24..32].copy_from_slice(&(frame + 4).to_be_bytes());
                        receiver.parity(parity.into(), viewflow_protocol::Id128(99), 1, false);
                    }
                    dec += start.elapsed();
                }
                if frame > 0 {
                    encode_us.push(enc.as_micros());
                    decode_us.push(dec.as_micros());
                }
            }
            encode_us.sort_unstable();
            decode_us.sort_unstable();
            println!(
                "FEC_CPU bytes={} D=16 P=4 encode_p50_us={} encode_p95_us={} decode_p50_us={} decode_p95_us={}",
                count * 1100,
                encode_us[50],
                encode_us[95],
                decode_us[50],
                decode_us[95]
            );
        }
    }
}
