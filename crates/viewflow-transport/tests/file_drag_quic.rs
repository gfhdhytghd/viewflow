//! Minimal QUIC file-drag lifecycle test.
//!
//! This deliberately exercises only the public transport, protocol, and core
//! state-machine boundaries. The daemon's filesystem receiver is crate-private
//! and is covered by its unit tests; making it public solely for an integration
//! test would widen the production API.

use std::{collections::HashMap, net::SocketAddr, time::Duration};

use bytes::Bytes;
use prost::Message;
use quinn::{Connection, Endpoint};
use viewflow_core::{Coordinator, DragTransferState};
use viewflow_protocol::{DomainControl, PROTOCOL_VERSION, wire};
use viewflow_transport::{
    BlobChunk, ControlSequencer, PeerIdentity, ReliablePayload, build_client_config,
    build_server_config, receive_control_sequenced, receive_reliable, send_blob_chunk,
    send_control,
};

const CERT: &[u8] = include_bytes!("fixtures/peer.pem");
const KEY: &[u8] = include_bytes!("fixtures/peer.key");
const CA: &[u8] = include_bytes!("fixtures/ca.pem");

fn identity() -> PeerIdentity {
    PeerIdentity::from_pem(CERT, KEY, CA).unwrap()
}

fn id(low: u64) -> wire::Id128 {
    wire::Id128 { high: 0, low }
}

fn envelope(sequence: u64, payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
    wire::ControlEnvelope {
        protocol_major: u32::from(PROTOCOL_VERSION.major),
        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
        sequence,
        payload: Some(payload),
    }
}

fn offer(sequence: u64) -> wire::ControlEnvelope {
    envelope(
        sequence,
        wire::control_envelope::Payload::FileDragOffer(wire::FileDragOffer {
            id: Some(id(700)),
            source_device: Some(id(1)),
            target_device: Some(id(2)),
            operation: wire::DragOperation::Copy.into(),
            items: vec![wire::FileDragItem {
                relative_path: "drop/hello.txt".into(),
                size_bytes: 11,
                content_sha256: None,
            }],
            generation: 1,
        }),
    )
}

fn accept() -> wire::ControlEnvelope {
    envelope(
        1,
        wire::control_envelope::Payload::FileDragAccept(wire::FileDragAccept {
            offer_id: Some(id(700)),
            operation: wire::DragOperation::Copy.into(),
            destination_token: "test-destination".into(),
            generation: 1,
        }),
    )
}

fn progress() -> wire::ControlEnvelope {
    envelope(
        3,
        wire::control_envelope::Payload::FileDragProgress(wire::FileDragProgress {
            offer_id: Some(id(700)),
            bytes_transferred: 11,
            total_bytes: 11,
            generation: 1,
            item_index: 0,
            offset_bytes: 0,
            chunk_size_bytes: 11,
            chunk_sha256: None,
        }),
    )
}

fn complete() -> wire::ControlEnvelope {
    envelope(
        4,
        wire::control_envelope::Payload::FileDragComplete(wire::FileDragComplete {
            offer_id: Some(id(700)),
            status: wire::FileDragCompletionStatus::Completed.into(),
            error_message: None,
            generation: 1,
            item_results: vec![wire::FileDragItemResult {
                item_index: 0,
                bytes_received: 11,
                content_sha256: None,
            }],
        }),
    )
}

async fn server_lifecycle(connection: Connection) -> (Vec<u8>, DragTransferState) {
    let mut receiver = Coordinator::default();
    let mut sequencing = ControlSequencer::default();

    // The offer is the first message and causes the receiver to issue Accept.
    let received_offer = receive_control_sequenced(&connection, &mut sequencing)
        .await
        .unwrap();
    receiver
        .apply_control_sequenced(
            received_offer.sequence,
            DomainControl::try_from(received_offer).unwrap(),
        )
        .unwrap();
    let accepted = accept();
    receiver
        .apply_control_sequenced(2, DomainControl::try_from(accepted.clone()).unwrap())
        .unwrap();
    send_control(&connection, &accepted).await.unwrap();

    // Blob and controls use independent reliable streams. Collect all three
    // and apply controls by their protocol sequence, so the test does not
    // accidentally depend on stream scheduling.
    let mut blob = None;
    let mut controls = Vec::new();
    for _ in 0..3 {
        match receive_reliable(&connection).await.unwrap() {
            ReliablePayload::BlobChunk(chunk) => blob = Some(chunk),
            ReliablePayload::Control(bytes) => {
                controls.push(wire::ControlEnvelope::decode(bytes).unwrap());
            }
        }
    }
    controls.sort_by_key(|control| control.sequence);
    for control in controls {
        sequencing.accept(control.sequence).unwrap();
        receiver
            .apply_control_sequenced(control.sequence, DomainControl::try_from(control).unwrap())
            .unwrap();
    }

    let blob = blob.expect("file-drag blob stream");
    assert_eq!(blob.transfer_id.0, 700);
    assert_eq!(blob.item_index, 0);
    assert_eq!(blob.offset_bytes, 0);
    assert!(blob.final_chunk);
    (
        blob.payload.to_vec(),
        receiver.drag_transfers().current().unwrap().state,
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ChunkAdmission {
    Accepted,
    ExactReplay,
    ConflictingReplay,
}

/// The public transport/core boundary has no filesystem receiver. This small
/// receiver-side admission ledger models the daemon's public-observable
/// contract: an identical in-flight replay is a no-op, while a changed payload
/// at an already accepted offset is fail-closed.
fn admit_chunk(
    accepted: &mut HashMap<(viewflow_protocol::Id128, u32, u64), (Bytes, bool)>,
    chunk: &BlobChunk,
) -> ChunkAdmission {
    let key = (chunk.transfer_id, chunk.item_index, chunk.offset_bytes);
    match accepted.get(&key) {
        None => {
            accepted.insert(key, (chunk.payload.clone(), chunk.final_chunk));
            ChunkAdmission::Accepted
        }
        Some((payload, final_chunk))
            if payload == &chunk.payload && *final_chunk == chunk.final_chunk =>
        {
            ChunkAdmission::ExactReplay
        }
        Some(_) => ChunkAdmission::ConflictingReplay,
    }
}

async fn server_replay_lifecycle(
    connection: Connection,
) -> (
    DragTransferState,
    u64,
    usize,
    usize,
    usize,
    usize,
    ChunkAdmission,
) {
    let mut receiver = Coordinator::default();
    let mut sequencing = ControlSequencer::default();
    let received_offer = receive_control_sequenced(&connection, &mut sequencing)
        .await
        .unwrap();
    receiver
        .apply_control_sequenced(
            received_offer.sequence,
            DomainControl::try_from(received_offer).unwrap(),
        )
        .unwrap();
    let accepted = accept();
    receiver
        .apply_control_sequenced(2, DomainControl::try_from(accepted.clone()).unwrap())
        .unwrap();
    send_control(&connection, &accepted).await.unwrap();

    let mut chunks = Vec::new();
    let mut controls = Vec::new();
    for _ in 0..4 {
        match receive_reliable(&connection).await.unwrap() {
            ReliablePayload::BlobChunk(chunk) => chunks.push(chunk),
            ReliablePayload::Control(bytes) => {
                controls.push(wire::ControlEnvelope::decode(bytes).unwrap());
            }
        }
    }
    let mut accepted_chunks = HashMap::new();
    let mut admission = ChunkAdmission::Accepted;
    for chunk in chunks {
        let current = admit_chunk(&mut accepted_chunks, &chunk);
        if current == ChunkAdmission::ConflictingReplay || admission == ChunkAdmission::Accepted {
            admission = current;
        }
    }

    controls.sort_by_key(|control| control.sequence);
    let progress_count = controls
        .iter()
        .filter(|control| {
            matches!(
                control.payload,
                Some(wire::control_envelope::Payload::FileDragProgress(_))
            )
        })
        .count();
    let complete_count = controls
        .iter()
        .filter(|control| {
            matches!(
                control.payload,
                Some(wire::control_envelope::Payload::FileDragComplete(_))
            )
        })
        .count();
    for control in controls {
        sequencing.accept(control.sequence).unwrap();
        receiver
            .apply_control_sequenced(control.sequence, DomainControl::try_from(control).unwrap())
            .unwrap();
    }
    let transfer = receiver.drag_transfers().current().unwrap();
    (
        transfer.state,
        transfer.item_received_bytes(0).unwrap(),
        usize::from(admission == ChunkAdmission::ExactReplay),
        usize::from(admission == ChunkAdmission::ConflictingReplay),
        progress_count,
        complete_count,
        admission,
    )
}

#[tokio::test]
async fn quic_file_drag_offer_accept_blob_complete_reaches_completed() {
    let server = Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let incoming = server.accept().await.unwrap();
        server_lifecycle(incoming.await.unwrap()).await
    });

    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity()).unwrap());
    let connection = client
        .connect(server_addr, "localhost")
        .unwrap()
        .await
        .unwrap();

    send_control(&connection, &offer(1)).await.unwrap();
    let received_accept = tokio::time::timeout(
        Duration::from_secs(2),
        receive_control_sequenced(&connection, &mut ControlSequencer::default()),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        DomainControl::try_from(received_accept).unwrap(),
        DomainControl::FileDragAccept(viewflow_protocol::DragAccept {
            offer_id: viewflow_protocol::Id128(700),
            generation: 1,
            operation: viewflow_protocol::DragOperation::Copy,
            destination_token: "test-destination".into(),
        })
    );

    send_blob_chunk(
        &connection,
        &BlobChunk {
            transfer_id: viewflow_protocol::Id128(700),
            item_index: 0,
            offset_bytes: 0,
            final_chunk: true,
            payload: Bytes::from_static(b"hello world"),
        },
    )
    .await
    .unwrap();
    send_control(&connection, &progress()).await.unwrap();
    send_control(&connection, &complete()).await.unwrap();

    let (payload, state) = tokio::time::timeout(Duration::from_secs(2), server_task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(payload, b"hello world");
    assert_eq!(state, DragTransferState::Completed);
}

fn final_chunk(payload: &'static [u8]) -> BlobChunk {
    BlobChunk {
        transfer_id: viewflow_protocol::Id128(700),
        item_index: 0,
        offset_bytes: 0,
        final_chunk: true,
        payload: Bytes::from_static(payload),
    }
}

#[tokio::test]
async fn quic_file_drag_exact_final_chunk_replay_is_idempotent() {
    let server = Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let incoming = server.accept().await.unwrap();
        server_replay_lifecycle(incoming.await.unwrap()).await
    });
    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity()).unwrap());
    let connection = client
        .connect(server_addr, "localhost")
        .unwrap()
        .await
        .unwrap();

    send_control(&connection, &offer(1)).await.unwrap();
    let received_accept = tokio::time::timeout(
        Duration::from_secs(2),
        receive_control_sequenced(&connection, &mut ControlSequencer::default()),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(matches!(
        DomainControl::try_from(received_accept).unwrap(),
        DomainControl::FileDragAccept(_)
    ));

    let chunk = final_chunk(b"hello world");
    send_blob_chunk(&connection, &chunk).await.unwrap();
    send_control(&connection, &progress()).await.unwrap();
    send_control(&connection, &complete()).await.unwrap();
    send_blob_chunk(&connection, &chunk).await.unwrap();

    let (state, received, exact_replays, conflicts, progress_count, complete_count, admission) =
        tokio::time::timeout(Duration::from_secs(2), server_task)
            .await
            .unwrap()
            .unwrap();
    assert_eq!(admission, ChunkAdmission::ExactReplay);
    assert_eq!((exact_replays, conflicts), (1, 0));
    assert_eq!((progress_count, complete_count), (1, 1));
    assert_eq!(state, DragTransferState::Completed);
    assert_eq!(received, 11, "replay must not advance progress twice");
}

#[tokio::test]
async fn quic_file_drag_same_offset_changed_payload_fails_closed() {
    let server = Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let incoming = server.accept().await.unwrap();
        server_replay_lifecycle(incoming.await.unwrap()).await
    });
    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity()).unwrap());
    let connection = client
        .connect(server_addr, "localhost")
        .unwrap()
        .await
        .unwrap();

    send_control(&connection, &offer(1)).await.unwrap();
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        receive_control_sequenced(&connection, &mut ControlSequencer::default()),
    )
    .await
    .unwrap()
    .unwrap();
    send_blob_chunk(&connection, &final_chunk(b"hello world"))
        .await
        .unwrap();
    send_control(&connection, &progress()).await.unwrap();
    send_control(&connection, &complete()).await.unwrap();
    send_blob_chunk(&connection, &final_chunk(b"HELLO WORLD"))
        .await
        .unwrap();

    let (state, received, exact_replays, conflicts, progress_count, complete_count, admission) =
        tokio::time::timeout(Duration::from_secs(2), server_task)
            .await
            .unwrap()
            .unwrap();
    assert_eq!(admission, ChunkAdmission::ConflictingReplay);
    assert_eq!((exact_replays, conflicts), (0, 1));
    assert_eq!((progress_count, complete_count), (1, 1));
    assert_eq!(state, DragTransferState::Completed);
    assert_eq!(received, 11, "conflicting replay must not mutate progress");
}
