#![no_main]
use libfuzzer_sys::fuzz_target;
use viewflow_deployment_marker::DeploymentQuarantineMarker;

fuzz_target!(|data: &[u8]| {
    if let Ok(marker) = DeploymentQuarantineMarker::decode(data) {
        assert_eq!(&marker.encode().expect("marker re-encodes")[..], data);
    }
});
