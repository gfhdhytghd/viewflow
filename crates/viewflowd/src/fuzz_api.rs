//! Narrow entry points for the out-of-workspace fuzz crate. Only compiled with
//! the `fuzzing` feature; production builds keep these decoders private.

/// Decodes one cursor telemetry datagram and checks it re-encodes canonically.
#[must_use]
pub fn cursor_feedback_roundtrip(data: &[u8]) -> bool {
    let Some(sample) = crate::cursor_feedback::Sample::decode(data) else {
        return false;
    };
    assert_eq!(sample.encode(), data, "cursor feedback is not canonical");
    true
}

/// Reads one clipboard record from a peer stream and validates its content.
#[must_use]
pub fn clipboard_record(bytes: &[u8], remote_role: u8) -> bool {
    crate::clipboard_sync::fuzz_receive_record(bytes, remote_role)
}

/// Parses one bounded local capture-plugin JSON response.
#[cfg(target_os = "linux")]
#[must_use]
pub fn hyprcapture_response(bytes: &[u8], expected_address: &str, max_pixel_bytes: usize) -> bool {
    crate::hyprcapture_runtime::fuzz_parse_response(bytes, expected_address, max_pixel_bytes)
}
