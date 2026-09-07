use std::io::Cursor;

use viewflow_platform::sidecar::{CodecError, read_request};

// Captured from the real Deskflow ViewflowSidecarClientTests binary built from
// source manifest f749b9f163b09846f0a552c6ef6bb8ae7e1d458c7b7604c1ff87dc81dc518d06.
const MOTION: &str = "0000004202050000000000000002000000000000000b102132435465768798a9bacbdcedfe0f0000000000000001000011d5a1d78a574004000000000000c00e000000000000";
const BUTTON: &str = "0000003402060000000000000003000000000000000b102132435465768798a9bacbdcedfe0f0000000000000002000011d5a1d7b39e0101";
const WHEEL: &str = "0000004202070000000000000004000000000000000b102132435465768798a9bacbdcedfe0f0000000000000003000011d5a1d7d6ed3ff4000000000000bfe0000000000000";
const KEYBOARD: &str = "0000003802080000000000000005000000000000000b102132435465768798a9bacbdcedfe0f0000000000000004000011d5a1d7fbb0000700040100";
const RELEASE_ALL: &str =
    "0000002a02090000000000000006000000000000000b102132435465768798a9bacbdcedfe0f0000000000000005";

fn decode_hex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).expect("golden hex must be ASCII");
            u8::from_str_radix(text, 16).expect("golden hex must be valid")
        })
        .collect()
}

fn assert_v2_rejected(value: &str) {
    let bytes = decode_hex(value);
    let mut cursor = Cursor::new(bytes);
    assert!(matches!(
        read_request(&mut cursor),
        Err(CodecError::UnsupportedVersion(2))
    ));
}

#[test]
fn real_deskflow_protocol_v2_frames_are_rejected_after_v3_cutover() {
    for frame in [MOTION, BUTTON, WHEEL, KEYBOARD, RELEASE_ALL] {
        assert_v2_rejected(frame);
    }
}
