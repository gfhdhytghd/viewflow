#![no_main]
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::{CodecDescriptor, FrameCodecMetadata};

fuzz_target!(|data: &[u8]| {
    let bytes = Bytes::copy_from_slice(data);
    if let Ok(descriptor) = CodecDescriptor::decode(bytes.clone()) {
        assert_eq!(descriptor.encode().expect("descriptor re-encodes"), bytes);
    }
    if let Ok(metadata) = FrameCodecMetadata::decode(bytes.clone()) {
        assert_eq!(metadata.encode().expect("metadata re-encodes"), bytes);
    }
});
