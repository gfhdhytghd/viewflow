//! Negotiated per-display work area snapshots. Geometry uses source pixels.
use anyhow::{Result, ensure};
use serde::Serialize;
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Display {
    pub id: u64,
    pub values: [f64; 8],
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Snapshot {
    pub revision: u64,
    pub displays: Vec<Display>,
}
impl Snapshot {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() >= 24, "work area header");
        let u32_at = |i: usize| {
            let mut word = [0; 4];
            word.copy_from_slice(&bytes[i..i + 4]);
            u32::from_le_bytes(word)
        };
        let u64_at = |i: usize| {
            let mut word = [0; 8];
            word.copy_from_slice(&bytes[i..i + 8]);
            u64::from_le_bytes(word)
        };
        let count = u32_at(16) as usize;
        ensure!(
            u32_at(0) == 7
                && u32_at(4) == 1
                && u64_at(8) > 0
                && count <= 16
                && u32_at(20) == 0
                && bytes.len() == 24 + 72 * count,
            "work area format"
        );
        let mut displays = Vec::new();
        for i in 0..count {
            let at = 24 + 72 * i;
            let id = u64_at(at);
            let values = std::array::from_fn(|j| f64::from_bits(u64_at(at + 8 + j * 8)));
            ensure!(
                id > 0
                    && values.iter().all(|v| v.is_finite())
                    && values[2] > 0.
                    && values[3] > 0.
                    && values[4..].iter().all(|v| *v >= 0.)
                    && values[5] + values[7] < values[2]
                    && values[4] + values[6] < values[3],
                "work area geometry"
            );
            ensure!(
                !displays.iter().any(|d: &Display| d.id == id),
                "duplicate work area display"
            );
            displays.push(Display { id, values });
        }
        Ok(Self {
            revision: u64_at(8),
            displays,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_updates_and_bounds() {
        let mut b = 7u32.to_le_bytes().to_vec();
        b.extend(1u32.to_le_bytes());
        b.extend(1u64.to_le_bytes());
        b.extend(1u32.to_le_bytes());
        b.extend(0u32.to_le_bytes());
        b.extend(42u64.to_le_bytes());
        for v in [6144f64, -598., 3840., 2400., 76., 0., 120., 0.] {
            b.extend(v.to_le_bytes());
        }
        let first = Snapshot::decode(&b).unwrap();
        assert_eq!(first.displays[0].values[4], 76.);
        b[8..16].copy_from_slice(&2u64.to_le_bytes());
        b[80..88].copy_from_slice(&0f64.to_le_bytes());
        assert_eq!(Snapshot::decode(&b).unwrap().revision, 2);
        assert!(Snapshot::decode(&b[..b.len() - 1]).is_err());
        b[64..72].copy_from_slice(&f64::NAN.to_le_bytes());
        assert!(Snapshot::decode(&b).is_err());
    }
}
