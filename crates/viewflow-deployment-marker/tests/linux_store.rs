#![cfg(target_os = "linux")]

use std::{fs, os::unix::fs::MetadataExt};

use tempfile::TempDir;
use viewflow_deployment_marker::{
    DEPLOYMENT_MARKER_FILE_NAME, DeploymentMarkerStore, DeploymentQuarantineMarker, MarkerError,
};

fn marker(generation: u64) -> DeploymentQuarantineMarker {
    DeploymentQuarantineMarker {
        operation_id: "deploy-20260829-0001".to_owned(),
        source_display: [0x11; 16],
        target_device: [0x22; 16],
        coordinator_instance: [0x33; 16],
        created_at_unix_ms: 1_788_000_000_000,
        generation,
    }
}

fn store() -> (TempDir, DeploymentMarkerStore) {
    let temporary = tempfile::tempdir().unwrap();
    let parent = temporary.path().join("state");
    fs::create_dir(&parent).unwrap();
    fs::set_permissions(&parent, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let uid = fs::metadata(&parent).unwrap().uid();
    let store = DeploymentMarkerStore::new(&parent, uid);
    (temporary, store)
}

#[test]
fn publish_is_no_clobber_and_creates_exact_metadata() {
    let (_temporary, store) = store();
    let first = store.publish(&marker(1)).unwrap();
    let metadata = fs::symlink_metadata(store.marker_path()).unwrap();
    assert_eq!(metadata.mode() & 0o777, 0o600);
    assert_eq!(metadata.nlink(), 1);
    assert_eq!(metadata.len(), 256);
    assert_eq!(store.load().unwrap().fingerprint, first);

    assert!(matches!(
        store.publish(&marker(2)),
        Err(MarkerError::MarkerAlreadyExists)
    ));
    assert_eq!(store.load().unwrap().marker.generation, 1);
}

#[test]
fn unsafe_parent_or_marker_never_becomes_a_valid_load() {
    let (_temporary, store) = store();
    let parent = store.marker_path().parent().unwrap().to_owned();
    fs::set_permissions(&parent, std::os::unix::fs::PermissionsExt::from_mode(0o750)).unwrap();
    assert!(matches!(
        store.publish(&marker(1)),
        Err(MarkerError::UnsafeParent)
    ));

    fs::set_permissions(&parent, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    fs::write(parent.join(DEPLOYMENT_MARKER_FILE_NAME), [0_u8; 256]).unwrap();
    fs::set_permissions(
        parent.join(DEPLOYMENT_MARKER_FILE_NAME),
        std::os::unix::fs::PermissionsExt::from_mode(0o644),
    )
    .unwrap();
    assert!(matches!(store.load(), Err(MarkerError::UnsafeMarker)));
}
