use sha2::{Digest, Sha256};
use viewflow_deployment_marker::{
    COORDINATOR_INSTANCE_OFFSET, CREATED_AT_UNIX_MS_OFFSET, DEPLOYMENT_MARKER_MAGIC,
    DEPLOYMENT_MARKER_SIZE, DESKFLOW_RUNTIME_MARKER_FILE_NAME, DESKFLOW_RUNTIME_MARKER_MAGIC,
    DESKFLOW_RUNTIME_MARKER_SIZE, DeploymentQuarantineMarker, GENERATION_OFFSET,
    LIFECYCLE_OWNER_COORDINATOR, MarkerError, OPERATION_ID_OFFSET, PROTOCOL_MAJOR, PROTOCOL_MINOR,
    RESERVED_OFFSET, SCHEMA_VERSION, SOURCE_DISPLAY_OFFSET, STATE_ACTIVE, TARGET_DEVICE_OFFSET,
};

fn marker() -> DeploymentQuarantineMarker {
    DeploymentQuarantineMarker {
        operation_id: "deploy-20260829-0001".to_owned(),
        source_display: [0x11; 16],
        target_device: [0x22; 16],
        coordinator_instance: [0x33; 16],
        created_at_unix_ms: 0x0102_0304_0506_0708,
        generation: 0x1112_1314_1516_1718,
    }
}

#[test]
fn v1_golden_vector_has_fixed_offsets_and_digest() {
    let encoded = marker().encode().unwrap();
    assert_eq!(encoded.len(), DEPLOYMENT_MARKER_SIZE);
    assert_eq!(&encoded[..8], &DEPLOYMENT_MARKER_MAGIC);
    assert_eq!(
        &encoded[8..16],
        &[
            SCHEMA_VERSION,
            STATE_ACTIVE,
            PROTOCOL_MAJOR,
            PROTOCOL_MINOR,
            LIFECYCLE_OWNER_COORDINATOR,
            20,
            0,
            0,
        ]
    );
    assert_eq!(
        &encoded[OPERATION_ID_OFFSET..OPERATION_ID_OFFSET + 20],
        b"deploy-20260829-0001"
    );
    assert!(
        encoded[OPERATION_ID_OFFSET + 20..SOURCE_DISPLAY_OFFSET]
            .iter()
            .all(|byte| *byte == 0)
    );
    assert_eq!(
        &encoded[SOURCE_DISPLAY_OFFSET..TARGET_DEVICE_OFFSET],
        &[0x11; 16]
    );
    assert_eq!(
        &encoded[TARGET_DEVICE_OFFSET..COORDINATOR_INSTANCE_OFFSET],
        &[0x22; 16]
    );
    assert_eq!(
        &encoded[COORDINATOR_INSTANCE_OFFSET..CREATED_AT_UNIX_MS_OFFSET],
        &[0x33; 16]
    );
    assert_eq!(
        &encoded[CREATED_AT_UNIX_MS_OFFSET..GENERATION_OFFSET],
        &[0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
    );
    assert_eq!(
        &encoded[GENERATION_OFFSET..RESERVED_OFFSET],
        &[0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11]
    );
    assert!(encoded[RESERVED_OFFSET..].iter().all(|byte| *byte == 0));
    assert_eq!(
        DeploymentQuarantineMarker::decode(&encoded).unwrap(),
        marker()
    );
    assert_eq!(
        format!("{:x}", Sha256::digest(encoded)),
        "f06d30a845877b3400882f7ab3749eb9c8d9d5f7eeaaebe260d946edecb6b4a8"
    );
}

#[test]
fn runtime_marker_is_never_accepted_as_deployment_marker() {
    assert_eq!(DESKFLOW_RUNTIME_MARKER_MAGIC, *b"VFQST002");
    assert_eq!(DESKFLOW_RUNTIME_MARKER_SIZE, 152);
    assert_eq!(DESKFLOW_RUNTIME_MARKER_FILE_NAME, "deskflow-quarantine.v2");
    let mut bytes = [0_u8; DEPLOYMENT_MARKER_SIZE];
    bytes[..8].copy_from_slice(&DESKFLOW_RUNTIME_MARKER_MAGIC);
    assert!(matches!(
        DeploymentQuarantineMarker::decode(&bytes),
        Err(MarkerError::WrongMagic)
    ));
}

#[test]
fn decoder_rejects_nonzero_reserved_and_padding_bytes() {
    let mut reserved = marker().encode().unwrap();
    reserved[RESERVED_OFFSET] = 1;
    assert!(matches!(
        DeploymentQuarantineMarker::decode(&reserved),
        Err(MarkerError::ReservedBytesNonZero)
    ));

    let mut padding = marker().encode().unwrap();
    padding[OPERATION_ID_OFFSET + 20] = 1;
    assert!(matches!(
        DeploymentQuarantineMarker::decode(&padding),
        Err(MarkerError::OperationPaddingNonZero)
    ));
}

#[test]
fn marker_identity_fields_must_be_nonzero() {
    let mut candidate = marker();
    candidate.coordinator_instance = [0; 16];
    assert!(matches!(
        candidate.encode(),
        Err(MarkerError::ZeroCoordinatorInstance)
    ));

    let mut candidate = marker();
    candidate.generation = 0;
    assert!(matches!(
        candidate.encode(),
        Err(MarkerError::ZeroGeneration)
    ));
}
