//! Receiver-authoritative cursor telemetry on the paired cursor connection.
//! Datagrams are replaceable observations, never input commands or leases.
use std::sync::{Arc, Mutex};

pub(crate) type State = Arc<Mutex<Option<(u64, u64)>>>;
const MAGIC: &[u8; 8] = b"VFCF\x01\0\0\0";

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Sample {
    pub generation: u64,
    pub anchor_sequence: u64,
    pub serial: u64,
    pub x: f64,
    pub y: f64,
    pub buttons: u32,
}
impl Sample {
    pub fn encode(self) -> Vec<u8> {
        let mut data = MAGIC.to_vec();
        for n in [self.generation, self.anchor_sequence, self.serial] {
            data.extend(n.to_le_bytes());
        }
        for n in [self.x, self.y] {
            data.extend(n.to_le_bytes());
        }
        data.extend(self.buttons.to_le_bytes());
        data
    }
    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() != 52 || &data[..8] != MAGIC {
            return None;
        }
        let word = |offset| u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
        let sample = Self {
            generation: word(8),
            anchor_sequence: word(16),
            serial: word(24),
            x: f64::from_bits(word(32)),
            y: f64::from_bits(word(40)),
            buttons: u32::from_le_bytes(data[48..52].try_into().unwrap()),
        };
        (sample.generation > 0
            && sample.anchor_sequence > 0
            && sample.serial > 0
            && sample.x.is_finite()
            && sample.y.is_finite())
        .then_some(sample)
    }
}

#[cfg(target_os = "macos")]
pub(crate) struct Publisher(tokio::task::JoinHandle<()>);
#[cfg(target_os = "macos")]
impl Drop for Publisher {
    fn drop(&mut self) {
        self.0.abort();
    }
}
#[cfg(target_os = "macos")]
pub(crate) fn start(connection: quinn::Connection, state: State) -> Option<Publisher> {
    if std::env::var("VIEWFLOW_CURSOR_FEEDBACK").as_deref() != Ok("1") {
        return None;
    }
    Some(Publisher(tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_millis(8));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut serial = 0;
        loop {
            tick.tick().await;
            if connection.close_reason().is_some() {
                break;
            }
            let anchor = *state.lock().unwrap();
            let Some((generation, anchor_sequence)) = anchor else {
                continue;
            };
            let Ok((x, y, buttons)) = viewflow_platform::macos_input::observe_cursor() else {
                continue;
            };
            serial += 1;
            let sample = Sample {
                generation,
                anchor_sequence,
                serial,
                x,
                y,
                buttons,
            };
            // Backpressure replaces observations; it never tears down input.
            let _ = connection.send_datagram(sample.encode().into());
        }
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn telemetry_rejects_wrong_version_nonfinite_and_missing_anchor() {
        let s = Sample {
            generation: 2,
            anchor_sequence: 1,
            serial: 3,
            x: -20.5,
            y: 440.,
            buttons: 1,
        };
        assert_eq!(Sample::decode(&s.encode()), Some(s));
        let mut data = s.encode();
        data[4] = 2;
        assert!(Sample::decode(&data).is_none());
        assert!(Sample::decode(&Sample { x: f64::NAN, ..s }.encode()).is_none());
        assert!(
            Sample::decode(
                &Sample {
                    anchor_sequence: 0,
                    ..s
                }
                .encode()
            )
            .is_none()
        );
    }
}
