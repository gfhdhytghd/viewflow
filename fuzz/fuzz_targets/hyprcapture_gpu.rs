#![no_main]
//! HCGF frame metadata, its HCGI geometry trailer, and HCGR releases.
use libfuzzer_sys::fuzz_target;
use viewflowd::hyprcapture_gpu_release::GpuRelease;
use viewflowd::hyprcapture_gpu_wire::{HCGF_BYTES, decode, decode_input_geometry, encode};

fuzz_target!(|data: &[u8]| {
    if let Ok(frame) = decode(data) {
        assert_eq!(&encode(&frame).expect("frame re-encodes")[..], data);
    }
    // The geometry trailer follows HCGF in the same seqpacket.
    if let Some(trailer) = data.get(HCGF_BYTES..) {
        let _ = decode_input_geometry(trailer);
    }
    let _ = decode_input_geometry(data);
    if let Ok(release) = GpuRelease::decode(data) {
        assert_eq!(&release.encode().expect("release re-encodes")[..], data);
    }
});
