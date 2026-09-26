//! Native activity frame envelope. The inner codec payload is unchanged.
use anyhow::{Result, ensure};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityFrame {
    pub lane: u32,
    pub epoch: u64,
    pub preferred: u64,
    pub focus: u64,
    pub members: Vec<u64>,
}
impl ActivityFrame {
    pub fn wrap(&self, legacy: &[u8]) -> Result<Vec<u8>> {
        ensure!(legacy.len() >= 32 && legacy[..4] == 1u32.to_le_bytes(), "activity inner frame type");
        ensure!(self.lane <= 1 && self.epoch > 0 && self.members.len() <= 32, "activity frame header");
        let unique: BTreeSet<_> = self.members.iter().copied().collect();
        ensure!(unique.len() == self.members.len() && !unique.contains(&0), "activity membership");
        let mut bytes = Vec::with_capacity(32 + 8*self.members.len() + legacy.len());
        bytes.extend(4u32.to_le_bytes()); bytes.extend(self.lane.to_le_bytes()); bytes.extend(self.epoch.to_le_bytes());
        bytes.extend(self.preferred.to_le_bytes()); bytes.extend(self.focus.to_le_bytes());
        bytes.extend((self.members.len() as u32).to_le_bytes());
        for id in &self.members { bytes.extend(id.to_le_bytes()); }
        bytes.extend(&legacy[4..]); Ok(bytes)
    }
    pub fn parse(bytes: &[u8]) -> Result<Option<Self>> {
        ensure!(bytes.len() >= 32, "native activity frame too short");
        let word = |at: usize| u32::from_le_bytes(bytes[at..at+4].try_into().unwrap());
        if word(0) == 1 { return Ok(None); }
        ensure!(word(0) == 4 && bytes.len() >= 64, "native activity frame type");
        let wide = |at: usize| u64::from_le_bytes(bytes[at..at+8].try_into().unwrap());
        let count = word(32) as usize;
        ensure!(word(4) <= 1 && wide(8) > 0 && count <= 32 && bytes.len() >= 64 + count*8, "native activity frame header");
        let members: Vec<_> = (0..count).map(|i| wide(36+i*8)).collect();
        let unique: BTreeSet<_> = members.iter().copied().collect();
        ensure!(members.len() == unique.len() && !unique.contains(&0), "native activity membership");
        Ok(Some(Self{lane:word(4),epoch:wide(8),preferred:wide(16),focus:wide(24),members}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn envelope_roundtrip_legacy_and_invalid_membership() {
        let mut legacy=vec![0;32];legacy[..4].copy_from_slice(&1u32.to_le_bytes());
        assert_eq!(ActivityFrame::parse(&legacy).unwrap(),None);
        let h=ActivityFrame{lane:1,epoch:4,preferred:8,focus:9,members:vec![8,9]};
        let encoded=h.wrap(&legacy).unwrap();assert_eq!(ActivityFrame::parse(&encoded).unwrap(),Some(h.clone()));
        let mut bad=h;bad.members.push(8);assert!(bad.wrap(&legacy).is_err());
    }
}
