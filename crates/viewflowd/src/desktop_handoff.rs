//! Ordered, OS-neutral ownership for the input-only desktop lane.
use serde::{Deserialize, Serialize};

pub const REQUEST: u32 = 100;
pub const RETURN: u32 = 101;
pub const CAPS: u32 = 102;
pub const FAULT: u32 = 103;
pub const CAPTURED: u32 = 200;
pub const ENTERED: u32 = 201;
pub const RELEASED: u32 = 202;
pub const DENIED: u32 = 203;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Record {
    pub lease: u64,
    pub sequence: u64,
    pub kind: u32,
    pub values: [i32; 4],
}
impl Record {
    pub fn new(kind: u32, lease: u64, values: [i32; 4]) -> Self {
        Self {
            kind,
            lease,
            sequence: 0,
            values,
        }
    }
    pub fn encode(self) -> [u8; 40] {
        let mut b = [0; 40];
        b[..4].copy_from_slice(&2u32.to_le_bytes());
        b[4..12].copy_from_slice(&self.lease.to_le_bytes());
        b[12..20].copy_from_slice(&self.sequence.to_le_bytes());
        b[20..24].copy_from_slice(&self.kind.to_le_bytes());
        for (i, v) in self.values.iter().enumerate() {
            b[24 + i * 4..28 + i * 4].copy_from_slice(&v.to_le_bytes());
        }
        b
    }
    pub fn decode(b: &[u8]) -> anyhow::Result<Self> {
        anyhow::ensure!(
            b.len() == 40 && b[..4] == 2u32.to_le_bytes(),
            "invalid handoff record"
        );
        Ok(Self {
            lease: u64::from_le_bytes(b[4..12].try_into()?),
            sequence: u64::from_le_bytes(b[12..20].try_into()?),
            kind: u32::from_le_bytes(b[20..24].try_into()?),
            values: std::array::from_fn(|i| {
                i32::from_le_bytes(b[24 + i * 4..28 + i * 4].try_into().unwrap())
            }),
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Local,
    Pending(u64),
    Captured(u64),
    Receiving(u64),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Native(Record),
    Peer(Record),
}
#[derive(Debug)]
pub struct Ownership {
    pub phase: Phase,
    pub local_wins_tie: bool,
    pub can_send: bool,
    pub can_receive: bool,
    generation: u64,
    peer_generation: u64,
}
impl Ownership {
    pub fn new(local_wins_tie: bool, can_send: bool, can_receive: bool) -> Self {
        Self {
            phase: Phase::Local,
            local_wins_tie,
            can_send,
            can_receive,
            generation: 0,
            peer_generation: 0,
        }
    }
    pub fn busy(&self) -> bool {
        self.phase != Phase::Local
    }
    pub fn disconnect(&mut self) -> Vec<Action> {
        self.phase = Phase::Local;
        vec![Action::Native(Record::new(RELEASED, 0, [0; 4]))]
    }
    pub fn local(&mut self, r: Record, available: bool) -> Vec<Action> {
        match r.kind {
            REQUEST if self.phase == Phase::Local && self.can_send && available => {
                self.generation += 1;
                self.phase = Phase::Pending(self.generation);
                vec![Action::Peer(Record::new(
                    REQUEST,
                    self.generation,
                    r.values,
                ))]
            }
            // A physical candidate can already be queued when an incoming
            // grant enters the native adapter. Do not reset that newer owner.
            REQUEST if self.busy() => vec![],
            REQUEST => vec![Action::Native(Record::new(RELEASED, 0, [0; 4]))],
            RETURN | FAULT => {
                let lease = match self.phase {
                    Phase::Pending(g) | Phase::Captured(g) | Phase::Receiving(g) => g,
                    Phase::Local => 0,
                };
                let mut actions = self.disconnect();
                if lease != 0 {
                    actions.push(Action::Peer(Record::new(RELEASED, lease, [0; 4])));
                }
                actions
            }
            1..=4 => match self.phase {
                Phase::Captured(g) => vec![Action::Peer(Record { lease: g, ..r })],
                _ => vec![],
            },
            _ => vec![],
        }
    }
    pub fn peer(&mut self, r: Record, available: bool) -> Vec<Action> {
        match r.kind {
            REQUEST => {
                let fresh = r.lease > self.peer_generation;
                self.peer_generation = self.peer_generation.max(r.lease);
                let wins = matches!(self.phase, Phase::Pending(_)) && !self.local_wins_tie;
                if !fresh || !self.can_receive || (!available && !wins) || (self.busy() && !wins) {
                    return vec![Action::Peer(Record::new(DENIED, r.lease, [0; 4]))];
                }
                let mut out = vec![];
                if wins {
                    out.extend(self.disconnect());
                }
                self.phase = Phase::Receiving(r.lease);
                out.push(Action::Native(Record::new(ENTERED, r.lease, r.values)));
                out.push(Action::Peer(Record::new(CAPTURED, r.lease, [0; 4])));
                out
            }
            CAPTURED if self.phase == Phase::Pending(r.lease) => {
                self.phase = Phase::Captured(r.lease);
                vec![Action::Native(r)]
            }
            DENIED if self.phase == Phase::Pending(r.lease) => self.disconnect(),
            RELEASED if matches!(self.phase,Phase::Receiving(g)|Phase::Captured(g)|Phase::Pending(g) if g==r.lease) => {
                self.disconnect()
            }
            1..=4 if self.phase == Phase::Receiving(r.lease) => vec![Action::Native(r)],
            _ => vec![],
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}
impl Rect {
    pub fn adjacent(self, peer: Self) -> bool {
        let (x, y, w, h) = (
            i64::from(self.x),
            i64::from(self.y),
            i64::from(self.width),
            i64::from(self.height),
        );
        let (px, py, pw, ph) = (
            i64::from(peer.x),
            i64::from(peer.y),
            i64::from(peer.width),
            i64::from(peer.height),
        );
        w >= 2
            && h >= 2
            && pw >= 2
            && ph >= 2
            && (((x + w == px || px + pw == x) && y.max(py) < (y + h).min(py + ph))
                || ((y + h == py || py + ph == y) && x.max(px) < (x + w).min(px + pw)))
    }
    pub fn args(self) -> [String; 4] {
        [
            self.x.to_string(),
            self.y.to_string(),
            self.width.to_string(),
            self.height.to_string(),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn rec(k: u32, g: u64) -> Record {
        Record::new(k, g, [0; 4])
    }
    #[test]
    fn symmetric_collision_has_one_controller() {
        let mut a = Ownership::new(true, true, true);
        let mut b = Ownership::new(false, true, true);
        a.local(rec(REQUEST, 0), true);
        b.local(rec(REQUEST, 0), true);
        assert_eq!(
            a.peer(rec(REQUEST, 1), true),
            vec![Action::Peer(rec(DENIED, 1))]
        );
        b.peer(rec(REQUEST, 1), true);
        a.peer(rec(CAPTURED, 1), true);
        b.peer(rec(DENIED, 1), true);
        assert_eq!(a.phase, Phase::Captured(1));
        assert_eq!(b.phase, Phase::Receiving(1));
    }
    #[test]
    fn return_disconnect_and_stale_events_release_only_current_lease() {
        let mut s = Ownership::new(true, true, true);
        s.peer(rec(REQUEST, 7), true);
        assert_eq!(s.peer(rec(4, 6), true), vec![]);
        assert!(
            !s.peer(rec(RELEASED, 6), true)
                .iter()
                .any(|a| matches!(a, Action::Native(_)))
        );
        assert_eq!(s.disconnect(), vec![Action::Native(rec(RELEASED, 0))]);
        assert_eq!(
            s.peer(rec(REQUEST, 7), true),
            vec![Action::Peer(rec(DENIED, 7))]
        );
        s.local(rec(REQUEST, 0), true);
        s.peer(rec(CAPTURED, 1), true);
        assert_eq!(s.local(rec(RETURN, 0), true).len(), 2);
        assert!(!s.busy());
    }
    #[test]
    fn capability_and_target_busy_are_lane_local() {
        let mut s = Ownership::new(true, false, true);
        s.local(rec(REQUEST, 0), true);
        assert!(!s.busy());
        s.peer(rec(REQUEST, 1), false);
        assert!(!s.busy());
        s.peer(rec(REQUEST, 2), true);
        assert_eq!(s.phase, Phase::Receiving(2));
        assert!(s.local(rec(4, 0), true).is_empty()); // receiving input cannot echo
    }
    #[test]
    fn queued_physical_candidate_does_not_reset_incoming_owner() {
        let mut s = Ownership::new(false, true, true);
        s.peer(rec(REQUEST, 8), true);
        assert!(s.local(rec(REQUEST, 0), true).is_empty());
        assert_eq!(s.phase, Phase::Receiving(8));
        assert_eq!(s.peer(rec(4, 8), true), vec![Action::Native(rec(4, 8))]);
    }
    #[test]
    fn edge_overlap_and_wire_round_trip() {
        let a = Rect {
            x: 0,
            y: 0,
            width: 100,
            height: 80,
        };
        assert!(a.adjacent(Rect {
            x: -100,
            y: 20,
            ..a
        }));
        assert!(!a.adjacent(Rect { x: 100, y: 80, ..a }));
        let r = Record {
            sequence: 42,
            ..rec(REQUEST, 9)
        };
        assert_eq!(Record::decode(&r.encode()).unwrap(), r);
        assert!(Record::decode(&[0; 39]).is_err());
    }
}

// Kernel-owned lock: process death releases ownership. No stale lockfile test,
// polling, deadline or focus condition participates in ownership.
#[derive(Debug)]
pub struct Seat(std::fs::File);
#[allow(unsafe_code)]
impl Seat {
    pub fn acquire() -> anyhow::Result<Self> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        #[cfg(unix)]
        let filename = format!("viewflow-handoff-seat-{}.lock", unsafe { libc::getuid() });
        #[cfg(not(unix))]
        let filename = "viewflow-handoff-seat.lock";
        let file = options.open(std::env::temp_dir().join(filename))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            anyhow::ensure!(
                unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                "desktop already controlled"
            );
        }
        Ok(Self(file))
    }
}
#[allow(unsafe_code)]
impl Drop for Seat {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }
}
