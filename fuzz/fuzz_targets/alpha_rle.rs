#![no_main]
//! VFAR alpha payloads under caller limits taken from the first input bytes.
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::{
    AlphaRleLimits, decode_alpha_rle, encode_alpha_rle, profile_alpha_rle, validate_alpha_rle,
};

fuzz_target!(|data: &[u8]| {
    let Some((head, payload)) = data.split_first_chunk::<4>() else {
        return;
    };
    // Bounded limits keep the harness's allocations small; the decoder must
    // still honor whatever the caller passes.
    let max_coded_width = u32::from(u16::from_le_bytes([head[0], head[1]]));
    let max_coded_height = u32::from(u16::from_le_bytes([head[2], head[3]]));
    let limits = AlphaRleLimits {
        max_coded_width,
        max_coded_height,
        max_luma_samples: 1 << 22,
        max_decoded_bytes: 1 << 22,
        max_encoded_bytes: 1 << 20,
    };
    let encoded = Bytes::copy_from_slice(payload);
    let decoded = decode_alpha_rle(encoded.clone(), limits);
    let validated = validate_alpha_rle(encoded.clone(), limits);
    let profiled = profile_alpha_rle(encoded, limits);
    assert_eq!(
        decoded.is_ok(),
        validated.is_ok(),
        "{decoded:?} vs {validated:?}"
    );
    assert_eq!(decoded.is_ok(), profiled.is_ok());
    if let Ok(alpha) = decoded {
        assert!(alpha.width <= max_coded_width && alpha.height <= max_coded_height);
        assert_eq!(
            alpha.samples.len() as u64,
            u64::from(alpha.width) * u64::from(alpha.height)
        );
        let again = encode_alpha_rle(alpha.width, alpha.height, &alpha.samples)
            .expect("decoded alpha re-encodes");
        let round = decode_alpha_rle(again, limits).expect("re-encoded alpha decodes");
        assert_eq!(round.samples, alpha.samples);
    }
});
