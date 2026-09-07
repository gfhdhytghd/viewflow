use std::io::Cursor;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};

use sha2::{Digest, Sha256};
use viewflow_platform::sidecar::{
    BoundPeerIdentity, CLEANUP_COMPLETE_BODY_SIZE, CleanupComplete, CleanupMode, CodecError,
    DURABLE_QUARANTINE_MARKER_MAGIC, DURABLE_QUARANTINE_MARKER_SIZE, DurableQuarantineMarker,
    MessageDirection, QUARANTINE_RECOVERY_BODY_SIZE, QuarantineMarkerState,
    QuarantineRecoveryRequest, RejectCode, ReleaseAllInput, SIDECAR_PROTOCOL_VERSION,
    SequenceDisposition, SidecarMessage, SidecarRequest, SidecarSession, read_request,
    write_request,
};
use viewflow_protocol::{Id128, InputLeaseState};

const SOURCE: Id128 = Id128(0x1112_1314_1516_1718_191a_1b1c_1d1e_1f20);
const TARGET: Id128 = Id128(0x2122_2324_2526_2728_292a_2b2c_2d2e_2f30);
const OWNER: Id128 = Id128(0x3132_3334_3536_3738_393a_3b3c_3d3e_3f40);
const BOOT: Id128 = Id128(0x4142_4344_4546_4748_494a_4b4c_4d4e_4f50);
const ROUTE_GENERATION: u64 = 0x5152_5354_5556_5758;
const LEASE_GENERATION: u64 = 0x6162_6364_6566_6768;
const LAST_SEQUENCE: u64 = 0x7172_7374_7576_7778;
const OLD_PID: u64 = 0x8182_8384_8586_8788;
const OLD_START: u64 = 0x9192_9394_9596_9798;
const PEER_EPOCH: u64 = 0xa1a2_a3a4_a5a6_a7a8;
const PEER_PORT: u16 = 0xb1b2;
const OPERATION_LOW: u64 = 0xc1c2_c3c4_c5c6_c7c8;
const ISSUED_AT_MS: u64 = 1_000_000;

fn peer_v4() -> BoundPeerIdentity {
    BoundPeerIdentity {
        epoch: PEER_EPOCH,
        address: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 42), PEER_PORT)),
    }
}

fn marker_v4() -> DurableQuarantineMarker {
    DurableQuarantineMarker {
        state: QuarantineMarkerState::Active,
        source_display: SOURCE,
        target_device: TARGET,
        owner_device: OWNER,
        old_daemon_boot_id: BOOT,
        route_generation: ROUTE_GENERATION,
        active_lease_generation: LEASE_GENERATION,
        last_sequence: LAST_SEQUENCE,
        old_daemon_pid: OLD_PID,
        old_daemon_start_ticks: OLD_START,
        bound_peer: peer_v4(),
    }
}

fn golden_marker_v4() -> [u8; DURABLE_QUARANTINE_MARKER_SIZE] {
    let mut bytes = [0_u8; DURABLE_QUARANTINE_MARKER_SIZE];
    bytes[..8].copy_from_slice(b"VFQST002");
    bytes[8] = 1;
    bytes[16..32].copy_from_slice(&SOURCE.0.to_be_bytes());
    bytes[32..48].copy_from_slice(&TARGET.0.to_be_bytes());
    bytes[48..64].copy_from_slice(&OWNER.0.to_be_bytes());
    bytes[64..80].copy_from_slice(&BOOT.0.to_be_bytes());
    bytes[80..88].copy_from_slice(&ROUTE_GENERATION.to_be_bytes());
    bytes[88..96].copy_from_slice(&LEASE_GENERATION.to_be_bytes());
    bytes[96..104].copy_from_slice(&LAST_SEQUENCE.to_be_bytes());
    bytes[104..112].copy_from_slice(&OLD_PID.to_be_bytes());
    bytes[112..120].copy_from_slice(&OLD_START.to_be_bytes());
    bytes[120..128].copy_from_slice(&PEER_EPOCH.to_be_bytes());
    bytes[128] = 4;
    bytes[130..132].copy_from_slice(&PEER_PORT.to_be_bytes());
    bytes[136..140].copy_from_slice(&[192, 0, 2, 42]);
    bytes
}

fn recovery_request() -> QuarantineRecoveryRequest {
    QuarantineRecoveryRequest::new(marker_v4()).unwrap()
}

fn operation_id() -> Id128 {
    Id128((u128::from(PEER_EPOCH) << 64) | u128::from(OPERATION_LOW))
}

fn cleanup(mode: CleanupMode, recovery_request_sequence: u64) -> CleanupComplete {
    CleanupComplete {
        mode,
        recovery_request_sequence,
        marker_sha256: recovery_request().marker_sha256,
        cleanup_operation_id: operation_id(),
        receipt_issued_at_unix_ms: ISSUED_AT_MS,
        receipt_expires_at_unix_ms: ISSUED_AT_MS + 5_000,
        source_display: SOURCE,
        route_generation: ROUTE_GENERATION,
        target_device: TARGET,
        owner_device: OWNER,
        active_lease_generation: LEASE_GENERATION,
        marker_last_sequence: LAST_SEQUENCE,
        observed_last_sequence: LAST_SEQUENCE,
        sequence_disposition: SequenceDisposition::Exact,
        bound_peer: peer_v4(),
        release_all: ReleaseAllInput {
            generation: LEASE_GENERATION,
            target_device: TARGET,
            event_sequence: LAST_SEQUENCE + 1,
        },
        release_all_applied: true,
        revoke_operation_id: operation_id(),
        revoke_lease_generation: LEASE_GENERATION + 1,
        revoke_owner_device: OWNER,
        revoke_target_device: TARGET,
        revoke_state: InputLeaseState::Revoked,
        revoke_applied: true,
    }
}

fn push_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn push_id(bytes: &mut Vec<u8>, value: Id128) {
    bytes.extend_from_slice(&value.0.to_be_bytes());
}

fn push_peer_v4(bytes: &mut Vec<u8>) {
    push_u64(bytes, PEER_EPOCH);
    bytes.push(4);
    bytes.extend_from_slice(&PEER_PORT.to_be_bytes());
    bytes.extend_from_slice(&[192, 0, 2, 42]);
    bytes.extend_from_slice(&[0; 12]);
    bytes.extend_from_slice(&[0; 4]);
}

fn golden_cleanup_body(value: &CleanupComplete) -> Vec<u8> {
    let mut body = Vec::with_capacity(CLEANUP_COMPLETE_BODY_SIZE);
    body.push(value.mode as u8);
    push_u64(&mut body, value.recovery_request_sequence);
    body.extend_from_slice(&value.marker_sha256);
    push_id(&mut body, value.cleanup_operation_id);
    push_u64(&mut body, value.receipt_issued_at_unix_ms);
    push_u64(&mut body, value.receipt_expires_at_unix_ms);
    push_id(&mut body, value.source_display);
    push_u64(&mut body, value.route_generation);
    push_id(&mut body, value.target_device);
    push_id(&mut body, value.owner_device);
    push_u64(&mut body, value.active_lease_generation);
    push_u64(&mut body, value.marker_last_sequence);
    push_u64(&mut body, value.observed_last_sequence);
    body.push(value.sequence_disposition as u8);
    push_peer_v4(&mut body);
    body.push(1);
    push_u64(&mut body, value.release_all.generation);
    push_id(&mut body, value.release_all.target_device);
    push_u64(&mut body, value.release_all.event_sequence);
    body.push(1);
    push_id(&mut body, value.revoke_operation_id);
    push_u64(&mut body, value.revoke_lease_generation);
    push_id(&mut body, value.revoke_owner_device);
    push_id(&mut body, value.revoke_target_device);
    body.push(3);
    body.push(1);
    assert_eq!(body.len(), CLEANUP_COMPLETE_BODY_SIZE);
    body
}

fn encode(request: &SidecarRequest) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_request(&mut bytes, request).unwrap();
    bytes
}

fn decode(bytes: &[u8]) -> Result<SidecarRequest, CodecError> {
    let mut cursor = Cursor::new(bytes);
    let request = read_request(&mut cursor)?.ok_or(CodecError::FrameTooShort)?;
    assert_eq!(cursor.position(), bytes.len() as u64);
    Ok(request)
}

#[track_caller]
fn assert_invalid_frame(mut frame: Vec<u8>, mutate: impl FnOnce(&mut [u8])) {
    mutate(&mut frame);
    assert!(matches!(decode(&frame), Err(CodecError::InvalidPayload(_))));
}

#[test]
fn marker_v2_ipv4_golden_is_exact_big_endian_and_hashes_all_152_bytes() {
    let expected = golden_marker_v4();
    let encoded = marker_v4().encode().unwrap();
    assert_eq!(encoded, expected);
    assert_eq!(&encoded[..8], &DURABLE_QUARANTINE_MARKER_MAGIC);
    assert!(encoded[9..16].iter().all(|byte| *byte == 0));
    assert!(encoded[140..152].iter().all(|byte| *byte == 0));
    assert_eq!(
        DurableQuarantineMarker::decode(&encoded).unwrap(),
        marker_v4()
    );
    assert_eq!(
        marker_v4().sha256().unwrap(),
        <[u8; 32]>::from(Sha256::digest(expected))
    );
    assert_eq!(
        marker_v4().sha256().unwrap(),
        [
            0xbf, 0x65, 0xf6, 0x72, 0x95, 0x7b, 0xe5, 0xea, 0x5a, 0xcb, 0x83, 0x93, 0x65, 0x46,
            0x52, 0xd4, 0x12, 0x6b, 0xb9, 0xfb, 0xfe, 0xef, 0x1a, 0xe5, 0xfa, 0x03, 0x8f, 0xc4,
            0x31, 0x24, 0x15, 0x5f,
        ]
    );

    assert!(matches!(
        DurableQuarantineMarker::decode(&encoded[..151]),
        Err(CodecError::InvalidPayload(_))
    ));
    let mut oversized = encoded.to_vec();
    oversized.push(0);
    assert!(matches!(
        DurableQuarantineMarker::decode(&oversized),
        Err(CodecError::InvalidPayload(_))
    ));
}

#[test]
fn marker_ipv6_preserves_all_address_bytes_and_rejects_noncanonical_identity() {
    let address = Ipv6Addr::new(0x2001, 0x0db8, 1, 2, 3, 4, 5, 0xabcd);
    let mut marker = marker_v4();
    marker.bound_peer.address = SocketAddr::V6(SocketAddrV6::new(address, PEER_PORT, 0, 42));
    let encoded = marker.encode().unwrap();
    assert_eq!(encoded[128], 6);
    assert_eq!(&encoded[132..136], &42_u32.to_be_bytes());
    assert_eq!(&encoded[136..152], &address.octets());
    assert_eq!(DurableQuarantineMarker::decode(&encoded).unwrap(), marker);

    let mut bad = encoded;
    bad[129] = 1;
    assert!(matches!(
        DurableQuarantineMarker::decode(&bad),
        Err(CodecError::InvalidPayload(_))
    ));

    let mut marker = marker_v4();
    marker.bound_peer.address = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, PEER_PORT));
    assert!(matches!(
        marker.encode(),
        Err(CodecError::InvalidPayload(_))
    ));

    let mut marker = marker_v4();
    marker.bound_peer.address = SocketAddr::V6(SocketAddrV6::new(address, PEER_PORT, 1, 42));
    assert!(matches!(
        marker.encode(),
        Err(CodecError::InvalidPayload(_))
    ));
}

#[test]
fn marker_decoder_rejects_reserved_padding_and_every_zero_identity_class() {
    let expected = golden_marker_v4();
    for range in [
        16..32,
        32..48,
        48..64,
        64..80,
        80..88,
        88..96,
        104..112,
        112..120,
        120..128,
        130..132,
    ] {
        let mut candidate = expected;
        candidate[range].fill(0);
        assert!(matches!(
            DurableQuarantineMarker::decode(&candidate),
            Err(CodecError::InvalidPayload(_))
        ));
    }
    for offset in [9, 15, 129, 132, 140, 151] {
        let mut candidate = expected;
        candidate[offset] = 1;
        assert!(matches!(
            DurableQuarantineMarker::decode(&candidate),
            Err(CodecError::InvalidPayload(_))
        ));
    }
    let mut wrong_magic = expected;
    wrong_magic[7] ^= 1;
    assert!(matches!(
        DurableQuarantineMarker::decode(&wrong_magic),
        Err(CodecError::InvalidPayload(_))
    ));
    let mut wrong_state = expected;
    wrong_state[8] = 3;
    assert!(matches!(
        DurableQuarantineMarker::decode(&wrong_state),
        Err(CodecError::InvalidPayload(_))
    ));
    let mut equal_owner_target = expected;
    equal_owner_target[48..64].copy_from_slice(&expected[32..48]);
    assert!(matches!(
        DurableQuarantineMarker::decode(&equal_owner_target),
        Err(CodecError::InvalidPayload(_))
    ));
}

#[test]
fn kind12_quarantine_recovery_has_exact_176_byte_body_and_full_marker_digest() {
    let request = SidecarRequest {
        sequence: 0x0102_0304_0506_0708,
        message: SidecarMessage::QuarantineRecovery(recovery_request()),
    };
    let encoded = encode(&request);
    let marker = golden_marker_v4();
    let digest = <[u8; 32]>::from(Sha256::digest(marker));
    let mut expected = Vec::new();
    expected.extend_from_slice(&(186_u32).to_be_bytes());
    expected.extend_from_slice(&[SIDECAR_PROTOCOL_VERSION, 12]);
    expected.extend_from_slice(&request.sequence.to_be_bytes());
    expected.extend_from_slice(&marker[8..]);
    expected.extend_from_slice(&digest);
    assert_eq!(QUARANTINE_RECOVERY_BODY_SIZE, 176);
    assert_eq!(encoded, expected);
    assert_eq!(decode(&encoded).unwrap(), request);

    assert_invalid_frame(encoded.clone(), |bytes| bytes[14 + 1] = 1);
    assert_invalid_frame(encoded.clone(), |bytes| bytes[14 + 144 + 31] ^= 1);

    let mut trailing = encoded.clone();
    trailing.push(0);
    trailing[..4].copy_from_slice(&(187_u32).to_be_bytes());
    assert!(matches!(
        decode(&trailing),
        Err(CodecError::InvalidPayload(_))
    ));
    let mut truncated = encoded;
    truncated.pop();
    truncated[..4].copy_from_slice(&(185_u32).to_be_bytes());
    assert!(matches!(decode(&truncated), Err(CodecError::FrameTooShort)));
}

#[test]
fn kind13_cleanup_complete_has_exact_277_byte_normal_and_recovery_goldens() {
    for (mode, recovery_sequence, request_sequence) in [
        (CleanupMode::Normal, 0, 9),
        (CleanupMode::Recovery, 0x0102_0304_0506_0708, 10),
    ] {
        let cleanup = cleanup(mode, recovery_sequence);
        let request = SidecarRequest {
            sequence: request_sequence,
            message: SidecarMessage::CleanupComplete(cleanup),
        };
        let encoded = encode(&request);
        let body = golden_cleanup_body(&cleanup);
        let mut expected = Vec::new();
        expected.extend_from_slice(&(287_u32).to_be_bytes());
        expected.extend_from_slice(&[SIDECAR_PROTOCOL_VERSION, 13]);
        expected.extend_from_slice(&request_sequence.to_be_bytes());
        expected.extend_from_slice(&body);
        assert_eq!(CLEANUP_COMPLETE_BODY_SIZE, 277);
        assert_eq!(encoded, expected);
        assert_eq!(decode(&encoded).unwrap(), request);

        let mut trailing = encoded.clone();
        trailing.push(0);
        trailing[..4].copy_from_slice(&(288_u32).to_be_bytes());
        assert!(matches!(
            decode(&trailing),
            Err(CodecError::InvalidPayload(_))
        ));
        let mut truncated = encoded;
        truncated.pop();
        truncated[..4].copy_from_slice(&(286_u32).to_be_bytes());
        assert!(matches!(decode(&truncated), Err(CodecError::FrameTooShort)));
    }
}

#[test]
#[allow(clippy::too_many_lines)]
fn kind13_decoder_rejects_identity_sequence_boolean_and_peer_mutations() {
    const BODY: usize = 14;

    let request = SidecarRequest {
        sequence: 9,
        message: SidecarMessage::CleanupComplete(cleanup(CleanupMode::Normal, 0)),
    };
    let frame = encode(&request);

    for offset in [
        BODY,
        BODY + 153,
        BODY + 162,
        BODY + 185,
        BODY + 218,
        BODY + 276,
    ] {
        assert_invalid_frame(frame.clone(), |bytes| bytes[offset] = 3);
    }
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 275] = 2);
    for range in [
        BODY + 9..BODY + 41,
        BODY + 41..BODY + 57,
        BODY + 57..BODY + 65,
        BODY + 73..BODY + 89,
        BODY + 89..BODY + 97,
        BODY + 97..BODY + 113,
        BODY + 113..BODY + 129,
        BODY + 129..BODY + 137,
        BODY + 137..BODY + 145,
        BODY + 145..BODY + 153,
        BODY + 154..BODY + 162,
        BODY + 163..BODY + 165,
        BODY + 186..BODY + 194,
        BODY + 194..BODY + 210,
        BODY + 210..BODY + 218,
        BODY + 219..BODY + 235,
        BODY + 235..BODY + 243,
        BODY + 243..BODY + 259,
        BODY + 259..BODY + 275,
    ] {
        assert_invalid_frame(frame.clone(), |bytes| bytes[range].fill(0));
    }
    for offset in [BODY + 181, BODY + 184] {
        assert_invalid_frame(frame.clone(), |bytes| bytes[offset] = 1);
    }
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 165..BODY + 169].fill(0));
    for offset in [BODY + 185, BODY + 218, BODY + 276] {
        assert_invalid_frame(frame.clone(), |bytes| bytes[offset] = 0);
        assert_invalid_frame(frame.clone(), |bytes| bytes[offset] = 2);
    }
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 8] = 1);
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 153] = 2);
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 169] ^= 1);
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 210 + 7] ^= 1);
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 219 + 15] ^= 1);
    assert_invalid_frame(frame.clone(), |bytes| bytes[BODY + 235 + 7] ^= 1);

    assert_invalid_frame(frame.clone(), |bytes| {
        bytes[BODY + 41..BODY + 49].copy_from_slice(&(PEER_EPOCH + 1).to_be_bytes());
        bytes[BODY + 219..BODY + 227].copy_from_slice(&(PEER_EPOCH + 1).to_be_bytes());
    });
    assert_invalid_frame(frame.clone(), |bytes| {
        bytes[BODY + 49..BODY + 57].fill(0);
        bytes[BODY + 227..BODY + 235].fill(0);
    });
    assert_invalid_frame(frame.clone(), |bytes| {
        let target = bytes[BODY + 97..BODY + 113].to_vec();
        bytes[BODY + 113..BODY + 129].copy_from_slice(&target);
    });
    assert_invalid_frame(frame, |bytes| {
        bytes[BODY + 65..BODY + 73].copy_from_slice(&(ISSUED_AT_MS + 5_001).to_be_bytes());
    });
}

#[test]
fn cleanup_ttl_and_sequence_dispositions_accept_only_the_closed_bounds() {
    for ttl in [1, 5_000] {
        let mut value = cleanup(CleanupMode::Normal, 0);
        value.receipt_expires_at_unix_ms = ISSUED_AT_MS + ttl;
        encode(&SidecarRequest {
            sequence: ttl,
            message: SidecarMessage::CleanupComplete(value),
        });
    }
    for ttl in [0, 5_001] {
        let mut value = cleanup(CleanupMode::Normal, 0);
        value.receipt_expires_at_unix_ms = ISSUED_AT_MS + ttl;
        assert!(matches!(
            write_request(
                &mut Vec::new(),
                &SidecarRequest {
                    sequence: ttl + 1,
                    message: SidecarMessage::CleanupComplete(value),
                },
            ),
            Err(CodecError::InvalidPayload(_))
        ));
    }

    let mut reservation = cleanup(CleanupMode::Normal, 0);
    reservation.observed_last_sequence -= 1;
    reservation.sequence_disposition = SequenceDisposition::ProvenUnobservedReservation;
    reservation.release_all.event_sequence = reservation.observed_last_sequence + 1;
    encode(&SidecarRequest {
        sequence: 11,
        message: SidecarMessage::CleanupComplete(reservation),
    });

    let mut no_input_marker = marker_v4();
    no_input_marker.last_sequence = 0;
    let marker_bytes = no_input_marker.encode().unwrap();
    assert_eq!(&marker_bytes[96..104], &[0; 8]);
    assert_eq!(
        DurableQuarantineMarker::decode(&marker_bytes).unwrap(),
        no_input_marker
    );

    let mut no_input_cleanup = cleanup(CleanupMode::Normal, 0);
    no_input_cleanup.marker_last_sequence = 0;
    no_input_cleanup.observed_last_sequence = 0;
    no_input_cleanup.release_all.event_sequence = 1;
    let no_input_frame = encode(&SidecarRequest {
        sequence: 12,
        message: SidecarMessage::CleanupComplete(no_input_cleanup),
    });
    assert_eq!(
        decode(&no_input_frame).unwrap().message,
        SidecarMessage::CleanupComplete(no_input_cleanup)
    );

    let mut reserved_first = no_input_cleanup;
    reserved_first.marker_last_sequence = 1;
    reserved_first.sequence_disposition = SequenceDisposition::ProvenUnobservedReservation;
    encode(&SidecarRequest {
        sequence: 13,
        message: SidecarMessage::CleanupComplete(reserved_first),
    });

    let mut exhausted = cleanup(CleanupMode::Normal, 0);
    exhausted.marker_last_sequence = u64::MAX;
    exhausted.observed_last_sequence = u64::MAX;
    exhausted.release_all.event_sequence = u64::MAX;
    assert!(matches!(
        write_request(
            &mut Vec::new(),
            &SidecarRequest {
                sequence: 14,
                message: SidecarMessage::CleanupComplete(exhausted),
            },
        ),
        Err(CodecError::InvalidPayload(_))
    ));
}

#[test]
#[allow(clippy::too_many_lines)]
fn recovery_session_enforces_direction_monotonic_requests_exact_reply_and_single_use() {
    let recovery = |sequence| SidecarRequest {
        sequence,
        message: SidecarMessage::QuarantineRecovery(recovery_request()),
    };
    let completion = |sequence| SidecarRequest {
        sequence: sequence + 1,
        message: SidecarMessage::CleanupComplete(cleanup(CleanupMode::Recovery, sequence)),
    };
    let mut session = SidecarSession::default();
    session
        .accept(SidecarRequest {
            sequence: 1,
            message: SidecarMessage::CleanupComplete(cleanup(CleanupMode::Normal, 0)),
        })
        .unwrap();
    assert_eq!(
        session.accept_from(MessageDirection::DaemonToSidecar, recovery(10)),
        Err(RejectCode::WrongDirection)
    );
    session
        .accept_from(MessageDirection::SidecarToDaemon, recovery(10))
        .unwrap();
    assert_eq!(session.accept(recovery(10)), Err(RejectCode::ReplayedEvent));
    assert_eq!(session.accept(recovery(9)), Err(RejectCode::ReplayedEvent));
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 2,
            message: SidecarMessage::CleanupComplete(cleanup(CleanupMode::Normal, 0)),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    assert_eq!(
        session.accept_from(MessageDirection::SidecarToDaemon, completion(10)),
        Err(RejectCode::WrongDirection)
    );
    assert_eq!(
        session.accept(completion(9)),
        Err(RejectCode::InvalidLeaseTransition)
    );

    let exact = cleanup(CleanupMode::Recovery, 10);
    let mut mismatched = exact;
    mismatched.marker_sha256[0] ^= 1;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 20,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.source_display = Id128(SOURCE.0 + 1);
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 21,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.route_generation += 1;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 22,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    let alternate_target = Id128(TARGET.0 + 1);
    mismatched.target_device = alternate_target;
    mismatched.release_all.target_device = alternate_target;
    mismatched.revoke_target_device = alternate_target;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 23,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    let alternate_owner = Id128(OWNER.0 + 1);
    mismatched.owner_device = alternate_owner;
    mismatched.revoke_owner_device = alternate_owner;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 24,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.active_lease_generation += 1;
    mismatched.release_all.generation += 1;
    mismatched.revoke_lease_generation += 1;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 25,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.marker_last_sequence += 1;
    mismatched.observed_last_sequence += 1;
    mismatched.release_all.event_sequence += 1;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 26,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.bound_peer.address =
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 43), PEER_PORT));
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 27,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    let mut mismatched = exact;
    mismatched.bound_peer.epoch += 1;
    let alternate_operation =
        Id128((u128::from(mismatched.bound_peer.epoch) << 64) | u128::from(OPERATION_LOW));
    mismatched.cleanup_operation_id = alternate_operation;
    mismatched.revoke_operation_id = alternate_operation;
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 28,
            message: SidecarMessage::CleanupComplete(mismatched),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    session
        .accept_from(MessageDirection::DaemonToSidecar, completion(10))
        .unwrap();
    assert_eq!(
        session.accept(completion(10)),
        Err(RejectCode::InvalidLeaseTransition)
    );
    session.accept(recovery(11)).unwrap();
    session.accept(completion(11)).unwrap();
}
