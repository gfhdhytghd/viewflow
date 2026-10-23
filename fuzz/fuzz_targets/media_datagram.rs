#![no_main]
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::MediaDatagram;

fuzz_target!(|data: &[u8]| {
    if let Ok(datagram) = MediaDatagram::decode(Bytes::copy_from_slice(data)) {
        let canonical = datagram.encode();
        let again = MediaDatagram::decode(canonical.clone()).expect("datagram re-decodes");
        assert_eq!(again.encode(), canonical);
    }
});
