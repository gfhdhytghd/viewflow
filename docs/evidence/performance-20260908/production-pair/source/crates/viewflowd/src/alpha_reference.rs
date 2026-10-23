//! One immutable, connection-scoped VFAR baseline. This caches alpha bytes,
//! never a color frame or capture timestamp. Senders install only after the
//! matching warmup or frame acknowledgement; Atlas receivers stage on admission.
//! Identity is window bytes (16), then big-endian u64 frame, epoch, config.
//! The 80-byte reference is identity + big-endian u32 width/height + VFAR SHA256.

use anyhow::{Result, bail};
use bytes::Bytes;
use sha2::{Digest, Sha256};
use viewflow_transport::{AlphaRleLimits, profile_alpha_rle};

pub const ALPHA_REFERENCE_BYTES: usize = 80;

pub struct AlphaReferenceCache {
    key: [u8; ALPHA_REFERENCE_BYTES],
    payload: Bytes,
}

impl AlphaReferenceCache {
    /// Construct a checked baseline for the caller's acknowledgement protocol.
    ///
    /// # Errors
    /// Rejects an invalid identity, malformed VFAR, mismatched geometry, or
    /// encoded/decoded data exceeding the caller's bound.
    pub fn new(
        warmup_identity: [u8; 40],
        width: u32,
        height: u32,
        payload: Bytes,
        max_frame_bytes: usize,
    ) -> Result<Self> {
        if warmup_identity[..16] == [0; 16]
            || u64::from_be_bytes(warmup_identity[16..24].try_into()?) == 0
            || u64::from_be_bytes(warmup_identity[24..32].try_into()?) == 0
            || u64::from_be_bytes(warmup_identity[32..40].try_into()?) == 0
        {
            bail!("invalid alpha baseline identity")
        }
        let profile = profile_alpha_rle(
            payload.clone(),
            AlphaRleLimits {
                max_coded_width: width,
                max_coded_height: height,
                max_luma_samples: u64::from(width) * u64::from(height),
                max_decoded_bytes: u64::try_from(max_frame_bytes)?,
                max_encoded_bytes: max_frame_bytes,
            },
        )?;
        if profile.width != width || profile.height != height {
            bail!("alpha baseline geometry mismatch")
        }
        let mut key = [0; ALPHA_REFERENCE_BYTES];
        key[..40].copy_from_slice(&warmup_identity);
        key[40..44].copy_from_slice(&width.to_be_bytes());
        key[44..48].copy_from_slice(&height.to_be_bytes());
        key[48..].copy_from_slice(&Sha256::digest(&payload));
        Ok(Self { key, payload })
    }

    fn matches_lineage(&self, current: [u8; 40], width: u32, height: u32) -> bool {
        current[..16] == self.key[..16]
            && current[24..40] == self.key[24..40]
            // Network-order fixed-width integers compare lexicographically.
            && current[16..24] > self.key[16..24]
            && width.to_be_bytes() == self.key[40..44]
            && height.to_be_bytes() == self.key[44..48]
    }

    /// Only a fresh capture's independently encoded, exactly identical alpha
    /// may use this baseline. A hash match alone is not the sender admission.
    pub fn reference_for(
        &self,
        current: [u8; 40],
        width: u32,
        height: u32,
        current_payload: &Bytes,
    ) -> Option<[u8; ALPHA_REFERENCE_BYTES]> {
        (self.matches_lineage(current, width, height) && *current_payload == self.payload)
            .then_some(self.key)
    }

    /// Resolve bytes only. The caller must use the *current color frame's*
    /// authenticated identity and timestamp and retain all freshness gates.
    ///
    /// # Errors
    /// Rejects any changed reference byte, incompatible lineage/geometry, or
    /// a current frame that does not strictly follow the baseline frame.
    pub fn resolve(
        &self,
        reference: &[u8],
        current: [u8; 40],
        width: u32,
        height: u32,
    ) -> Result<Bytes> {
        if reference != self.key || !self.matches_lineage(current, width, height) {
            bail!("alpha reference does not match acknowledged baseline")
        }
        Ok(self.payload.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_transport::encode_alpha_rle;

    fn identity(frame: u64) -> [u8; 40] {
        let mut tag = [0; 40];
        tag[0] = 1;
        tag[16..24].copy_from_slice(&frame.to_be_bytes());
        tag[24..32].copy_from_slice(&7u64.to_be_bytes());
        tag[32..40].copy_from_slice(&11u64.to_be_bytes());
        tag
    }

    #[test]
    fn exact_current_alpha_reuses_bytes_without_any_timestamp() {
        let alpha = encode_alpha_rle(2, 2, &[1, 2, 3, 4]).unwrap();
        let cache = AlphaReferenceCache::new(identity(5), 2, 2, alpha.clone(), 1024).unwrap();
        let key = cache.reference_for(identity(6), 2, 2, &alpha).unwrap();
        assert_eq!(&key[..40], &identity(5));
        assert_eq!(&key[40..48], &[0, 0, 0, 2, 0, 0, 0, 2]);
        assert_eq!(&key[48..], Sha256::digest(&alpha).as_slice());
        assert_eq!(
            &key[48..],
            &[
                0x6b, 0xbf, 0x71, 0xc4, 0xd6, 0xf2, 0xec, 0x0c, 0x2f, 0x2e, 0xf1, 0xbc, 0x0b, 0x38,
                0x49, 0x6b, 0x3a, 0x2c, 0x2e, 0x65, 0xd8, 0xb0, 0x0b, 0x71, 0xca, 0xc4, 0x8d, 0x55,
                0x6c, 0xa1, 0xe1, 0x7f,
            ]
        );
        assert_eq!(cache.resolve(&key, identity(6), 2, 2).unwrap(), alpha);
        assert_eq!(cache.resolve(&key, identity(100), 2, 2).unwrap(), alpha);
        let changed = encode_alpha_rle(2, 2, &[1, 2, 3, 5]).unwrap();
        assert!(cache.reference_for(identity(6), 2, 2, &changed).is_none());
        assert!(cache.reference_for(identity(5), 2, 2, &alpha).is_none());
        assert!(cache.reference_for(identity(4), 2, 2, &alpha).is_none());
    }

    #[test]
    fn every_key_byte_and_lineage_field_are_bound() {
        let alpha = encode_alpha_rle(2, 2, &[7; 4]).unwrap();
        let cache = AlphaReferenceCache::new(identity(5), 2, 2, alpha.clone(), 1024).unwrap();
        let key = cache.reference_for(identity(6), 2, 2, &alpha).unwrap();
        for i in 0..ALPHA_REFERENCE_BYTES {
            let mut bad = key;
            bad[i] ^= 1;
            assert!(cache.resolve(&bad, identity(6), 2, 2).is_err());
        }
        for i in (0..16).chain(24..40) {
            let mut bad = identity(6);
            bad[i] ^= 1;
            assert!(cache.reference_for(bad, 2, 2, &alpha).is_none());
            assert!(cache.resolve(&key, bad, 2, 2).is_err());
        }
        assert!(cache.resolve(&key[..79], identity(6), 2, 2).is_err());
        assert!(
            cache
                .resolve(&[key.as_slice(), &[0]].concat(), identity(6), 2, 2)
                .is_err()
        );
        assert!(cache.resolve(&key, identity(6), 1, 2).is_err());
        assert!(cache.resolve(&key, identity(6), 2, 1).is_err());
        assert!(cache.resolve(&key, identity(5), 2, 2).is_err());
    }

    #[test]
    fn baseline_is_bounded_and_vfar_validated_before_install() {
        let alpha = encode_alpha_rle(2, 2, &[7; 4]).unwrap();
        assert!(AlphaReferenceCache::new([0; 40], 2, 2, alpha.clone(), 1024).is_err());
        assert!(AlphaReferenceCache::new(identity(0), 2, 2, alpha.clone(), 1024).is_err());
        for start in [24, 32] {
            let mut bad = identity(5);
            bad[start..start + 8].fill(0);
            assert!(AlphaReferenceCache::new(bad, 2, 2, alpha.clone(), 1024).is_err());
        }
        assert!(
            AlphaReferenceCache::new(identity(5), 2, 2, alpha.clone(), alpha.len() - 1).is_err()
        );
        assert!(AlphaReferenceCache::new(identity(5), 3, 2, alpha, 1024).is_err());
        assert!(
            AlphaReferenceCache::new(identity(5), 2, 2, Bytes::from_static(b"VFAR"), 1024).is_err()
        );
    }
}
