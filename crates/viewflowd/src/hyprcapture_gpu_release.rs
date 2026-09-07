//! Local GPU allocation release, sent only after all source GPU reads finish.
//! A release is not an encoded-frame or presentation acknowledgement.

use crate::hyprcapture_gpu_wire::HcgfError;

pub const RELEASE_BYTES: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GpuRelease {
    pub sequence: u64,
    pub geometry_epoch: u64,
}

impl GpuRelease {
    /// Encode this release identity into its fixed-size wire representation.
    ///
    /// # Errors
    ///
    /// Returns [`HcgfError::ZeroLineage`] for a zero sequence or geometry epoch.
    pub fn encode(self) -> Result<[u8; RELEASE_BYTES], HcgfError> {
        if self.sequence == 0 || self.geometry_epoch == 0 {
            return Err(HcgfError::ZeroLineage);
        }
        let mut bytes = [0; RELEASE_BYTES];
        bytes[..4].copy_from_slice(b"HCGR");
        bytes[4..6].copy_from_slice(&1u16.to_be_bytes());
        bytes[6..8].copy_from_slice(
            &u16::try_from(RELEASE_BYTES)
                .map_err(|_| HcgfError::HeaderLength)?
                .to_be_bytes(),
        );
        bytes[8..16].copy_from_slice(&self.sequence.to_be_bytes());
        bytes[16..24].copy_from_slice(&self.geometry_epoch.to_be_bytes());
        Ok(bytes)
    }

    /// Decode and validate a fixed-size release identity.
    ///
    /// # Errors
    ///
    /// Returns an error when the bytes have an invalid header, reserved data,
    /// or zero lineage identity.
    pub fn decode(bytes: &[u8]) -> Result<Self, HcgfError> {
        if bytes.len() != RELEASE_BYTES {
            return Err(HcgfError::Length);
        }
        if &bytes[..4] != b"HCGR" {
            return Err(HcgfError::Magic);
        }
        if bytes[4..6] != 1u16.to_be_bytes() {
            return Err(HcgfError::Version);
        }
        if bytes[6..8]
            != u16::try_from(RELEASE_BYTES)
                .map_err(|_| HcgfError::HeaderLength)?
                .to_be_bytes()
        {
            return Err(HcgfError::HeaderLength);
        }
        if bytes[24..].iter().any(|&value| value != 0) {
            return Err(HcgfError::Reserved);
        }
        let release = Self {
            sequence: u64::from_be_bytes(bytes[8..16].try_into().map_err(|_| HcgfError::Length)?),
            geometry_epoch: u64::from_be_bytes(
                bytes[16..24].try_into().map_err(|_| HcgfError::Length)?,
            ),
        };
        if release.sequence == 0 || release.geometry_epoch == 0 {
            return Err(HcgfError::ZeroLineage);
        }
        Ok(release)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_release_identity_and_header() {
        let release = GpuRelease {
            sequence: 0x0102_0304_0506_0708,
            geometry_epoch: 9,
        };
        let bytes = release.encode().unwrap();
        assert_eq!(&bytes[..8], b"HCGR\0\x01\0\x20");
        assert_eq!(&bytes[8..16], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(GpuRelease::decode(&bytes), Ok(release));
        for offset in 24..32 {
            let mut bad = bytes;
            bad[offset] = 1;
            assert_eq!(GpuRelease::decode(&bad), Err(HcgfError::Reserved));
        }
    }

    #[test]
    fn invalid_release_cannot_authorize_reuse() {
        let good = GpuRelease {
            sequence: 1,
            geometry_epoch: 2,
        }
        .encode()
        .unwrap();
        for length in 0..RELEASE_BYTES {
            assert_eq!(GpuRelease::decode(&good[..length]), Err(HcgfError::Length));
        }
        let mut extra = good.to_vec();
        extra.push(0);
        assert_eq!(GpuRelease::decode(&extra), Err(HcgfError::Length));
        for (offset, error) in [
            (0, HcgfError::Magic),
            (4, HcgfError::Version),
            (6, HcgfError::HeaderLength),
        ] {
            let mut bad = good;
            bad[offset] ^= 1;
            assert_eq!(GpuRelease::decode(&bad), Err(error));
        }
        for range in [8..16, 16..24] {
            let mut bad = good;
            bad[range].fill(0);
            assert_eq!(GpuRelease::decode(&bad), Err(HcgfError::ZeroLineage));
        }
    }
}
