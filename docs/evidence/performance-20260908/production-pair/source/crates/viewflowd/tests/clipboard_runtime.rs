#[path = "../src/clipboard_runtime.rs"]
mod clipboard_runtime;

use std::{
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use clipboard_runtime::{
    ClipboardConsent, ClipboardInstalled, ClipboardReceiver, ClipboardSendRequest, ClipboardSender,
    DedicatedClipboardControl, MAX_CLIPBOARD_BYTES,
};
use quinn::{Connection, Endpoint};
use sha2::{Digest, Sha256};
use viewflow_protocol::{
    ClipboardOffer, ClipboardPayload, ClipboardTransferFlavor, ClipboardTransferOffer,
    DomainControl, Id128, PROTOCOL_VERSION, wire,
};
use viewflow_transport::{
    ControlSequencer, PeerIdentity, build_client_config, build_server_config,
    receive_control_sequenced, send_control,
};

const CERT: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem");
const KEY: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/peer.key");
const CA: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem");

#[tokio::test]
async fn authenticated_clipboard_transfer_requires_consent_and_reports_native_install_only() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let correlation = [7; 16];
        let installations = Arc::new(AtomicUsize::new(0));
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let installs = Arc::clone(&installations);
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let receipt = receiver
                .receive(
                    consent_incoming(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |verified| {
                        assert_eq!(verified.transfer.offer.id, Id128(11));
                        assert_eq!(verified.accepted.mime_type, "text/plain;charset=utf-8");
                        assert_eq!(verified.payload.data, b"hello");
                        installs.fetch_add(1, Ordering::SeqCst);
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            // Keep the endpoint/connection alive until the sender receives the
            // terminal unidirectional completion stream.
            tokio::time::sleep(Duration::from_millis(20)).await;
            receipt
        });
        let client = endpoint_client();
        let connection = client.connect(address, "localhost").unwrap().await.unwrap();
        let mut sender = ClipboardSender::new(
            DedicatedClipboardControl::acquire(&connection).unwrap(),
            1,
            1,
        )
        .unwrap();
        let complete = sender
            .send(request(correlation, b"hello"), deadline())
            .await
            .unwrap();
        assert_eq!(
            complete.status,
            viewflow_protocol::ClipboardCompletionStatus::Completed
        );
        assert_eq!(server_task.await.unwrap().status, complete.status);
        assert_eq!(installations.load(Ordering::SeqCst), 1);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn receiver_fails_closed_on_hash_mismatch_without_native_install() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let correlation = [8; 16];
        let installations = Arc::new(AtomicUsize::new(0));
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let installs = Arc::clone(&installations);
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let receipt = receiver
                .receive(
                    consent_incoming(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |_| {
                        installs.fetch_add(1, Ordering::SeqCst);
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
            receipt
        });
        let client = endpoint_client();
        let connection = client.connect(address, "localhost").unwrap().await.unwrap();
        let offer = transfer_offer(&connection, correlation, 1, b"good");
        send_control(
            &connection,
            &envelope(
                1,
                wire::control_envelope::Payload::ClipboardTransferOffer(offer.into()),
            ),
        )
        .await
        .unwrap();
        let mut incoming = ControlSequencer::default();
        assert!(matches!(
            DomainControl::try_from(
                receive_control_sequenced(&connection, &mut incoming)
                    .await
                    .unwrap()
            )
            .unwrap(),
            DomainControl::ClipboardAccept(_)
        ));
        let payload = ClipboardPayload {
            offer_id: Id128(11),
            generation: 3,
            offer_nonce: [4; 16],
            payload_sequence: 1,
            mime_type: "text/plain;charset=utf-8".into(),
            data: b"evil".to_vec(),
        };
        send_control(
            &connection,
            &envelope(
                2,
                wire::control_envelope::Payload::ClipboardPayload(payload.into()),
            ),
        )
        .await
        .unwrap();
        let complete = DomainControl::try_from(
            receive_control_sequenced(&connection, &mut incoming)
                .await
                .unwrap(),
        )
        .unwrap();
        assert!(matches!(
            complete,
            DomainControl::ClipboardComplete(value)
                if value.status == viewflow_protocol::ClipboardCompletionStatus::Failed
        ));
        assert_eq!(
            server_task.await.unwrap().status,
            viewflow_protocol::ClipboardCompletionStatus::Failed
        );
        assert_eq!(installations.load(Ordering::SeqCst), 0);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn receiver_suppresses_echo_and_rejects_replayed_delivery_before_install() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let correlation = [9; 16];
        let installations = Arc::new(AtomicUsize::new(0));
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let installs = Arc::clone(&installations);
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let first = receiver
                .receive(
                    consent_incoming(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |_| {
                        installs.fetch_add(1, Ordering::SeqCst);
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            let second = receiver
                .receive(
                    consent_incoming(correlation, 2),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |_| {
                        installs.fetch_add(1, Ordering::SeqCst);
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            let replay = receiver
                .receive(
                    consent_incoming(correlation, 2),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |_| Ok(ClipboardInstalled),
                )
                .await;
            (first, second, replay)
        });
        let client = endpoint_client();
        let connection = client.connect(address, "localhost").unwrap().await.unwrap();
        let mut sender = ClipboardSender::new(
            DedicatedClipboardControl::acquire(&connection).unwrap(),
            1,
            1,
        )
        .unwrap();
        assert_eq!(
            sender
                .send(request(correlation, b"same"), deadline())
                .await
                .unwrap()
                .status,
            viewflow_protocol::ClipboardCompletionStatus::Completed
        );
        assert_eq!(
            sender
                .send(request(correlation, b"same"), deadline())
                .await
                .unwrap()
                .status,
            viewflow_protocol::ClipboardCompletionStatus::Cancelled
        );

        // A new monotonically numbered envelope cannot replay an already used
        // offer nonce + payload sequence; the receiver must not invoke native install.
        let replay = transfer_offer(&connection, correlation, 2, b"same");
        send_control(
            &connection,
            &envelope(
                5,
                wire::control_envelope::Payload::ClipboardTransferOffer(replay.into()),
            ),
        )
        .await
        .unwrap();
        let (first, second, replay) = server_task.await.unwrap();
        assert_eq!(
            first.status,
            viewflow_protocol::ClipboardCompletionStatus::Completed
        );
        assert_eq!(
            second.status,
            viewflow_protocol::ClipboardCompletionStatus::Cancelled
        );
        assert!(replay.is_err());
        assert_eq!(installations.load(Ordering::SeqCst), 1);
    })
    .await
    .unwrap();
}

#[test]
fn clipboard_payload_limit_stays_below_transport_control_limit() {
    assert_eq!(MAX_CLIPBOARD_BYTES, 1024 * 1024);
}

#[tokio::test]
async fn dedicated_clipboard_control_rejects_a_second_same_process_reader() {
    let server = endpoint_server();
    let address = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let connection = server.accept().await.unwrap().await.unwrap();
        tokio::time::sleep(Duration::from_millis(30)).await;
        connection.close(0_u32.into(), b"test done");
    });
    let client = endpoint_client();
    let connection = client.connect(address, "localhost").unwrap().await.unwrap();
    let lease = DedicatedClipboardControl::acquire(&connection).unwrap();
    assert!(DedicatedClipboardControl::acquire(&connection).is_err());
    drop(lease);
    assert!(DedicatedClipboardControl::acquire(&connection).is_ok());
    server_task.await.unwrap();
}

#[tokio::test]
async fn cancellation_after_accept_retires_the_dedicated_connection() {
    let correlation = [10; 16];
    let server = endpoint_server();
    let address = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let connection = server.accept().await.unwrap().await.unwrap();
        let mut receiver =
            ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                .unwrap();
        let result = receiver
            .receive(
                consent_incoming(correlation, 1),
                "text/plain;charset=utf-8",
                deadline(),
                |_| Ok(ClipboardInstalled),
            )
            .await;
        (result, connection.close_reason().is_some())
    });
    let client = endpoint_client();
    let connection = client.connect(address, "localhost").unwrap().await.unwrap();
    let offer = transfer_offer(&connection, correlation, 1, b"cancel");
    send_control(
        &connection,
        &envelope(
            1,
            wire::control_envelope::Payload::ClipboardTransferOffer(offer.into()),
        ),
    )
    .await
    .unwrap();
    let mut incoming = ControlSequencer::default();
    assert!(matches!(
        DomainControl::try_from(
            receive_control_sequenced(&connection, &mut incoming)
                .await
                .unwrap()
        )
        .unwrap(),
        DomainControl::ClipboardAccept(_)
    ));
    connection.close(0_u32.into(), b"test cancellation");
    let (result, retired) = server_task.await.unwrap();
    assert!(result.is_err());
    assert!(retired);
}

#[tokio::test]
async fn bounded_echo_ledger_never_forgets_old_payload_sequences() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let correlation = [11; 16];
        let installations = Arc::new(AtomicUsize::new(0));
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let installs = Arc::clone(&installations);
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let mut statuses = Vec::new();
            for sequence in 1..=65 {
                statuses.push(
                    receiver
                        .receive(
                            consent_incoming(correlation, sequence),
                            "text/plain;charset=utf-8",
                            deadline(),
                            |_| {
                                installs.fetch_add(1, Ordering::SeqCst);
                                Ok(ClipboardInstalled)
                            },
                        )
                        .await
                        .unwrap()
                        .status,
                );
            }
            let replay = receiver
                .receive(
                    consent_incoming(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |_| Ok(ClipboardInstalled),
                )
                .await;
            (statuses, replay)
        });
        let client = endpoint_client();
        let connection = client.connect(address, "localhost").unwrap().await.unwrap();
        let mut sender = ClipboardSender::new(
            DedicatedClipboardControl::acquire(&connection).unwrap(),
            1,
            1,
        )
        .unwrap();
        for byte in 0_u8..64 {
            assert_eq!(
                sender
                    .send(request(correlation, &[byte]), deadline())
                    .await
                    .unwrap()
                    .status,
                viewflow_protocol::ClipboardCompletionStatus::Completed
            );
        }
        assert_eq!(
            sender
                .send(request(correlation, b"ledger-full"), deadline())
                .await
                .unwrap()
                .status,
            viewflow_protocol::ClipboardCompletionStatus::Failed
        );
        send_control(
            &connection,
            &envelope(
                131,
                wire::control_envelope::Payload::ClipboardTransferOffer(
                    transfer_offer(&connection, correlation, 1, b"replay").into(),
                ),
            ),
        )
        .await
        .unwrap();
        let (statuses, replay) = server_task.await.unwrap();
        assert!(
            statuses[..64]
                .iter()
                .all(|status| *status == viewflow_protocol::ClipboardCompletionStatus::Completed)
        );
        assert_eq!(
            statuses[64],
            viewflow_protocol::ClipboardCompletionStatus::Failed
        );
        assert!(replay.is_err());
        assert_eq!(installations.load(Ordering::SeqCst), 64);
    })
    .await
    .unwrap();
}

fn request(correlation: [u8; 16], data: &[u8]) -> ClipboardSendRequest {
    ClipboardSendRequest {
        offer: ClipboardOffer {
            id: Id128(11),
            owner: Id128(12),
            generation: 3,
            flavors: vec![viewflow_protocol::ClipboardFlavor {
                name: "text/plain;charset=utf-8".into(),
                size_bytes: u64::try_from(data.len()).unwrap(),
            }],
        },
        flavors: vec![ClipboardTransferFlavor {
            name: "text/plain;charset=utf-8".into(),
            size_bytes: u64::try_from(data.len()).unwrap(),
            sha256: digest(data),
        }],
        offer_nonce: [4; 16],
        consent: ClipboardConsent::for_outgoing(correlation, Id128(11), 3, [4; 16]).unwrap(),
        mime_type: "text/plain;charset=utf-8".into(),
        data: data.to_vec(),
    }
}

fn transfer_offer(
    connection: &Connection,
    correlation: [u8; 16],
    payload_sequence: u64,
    advertised_data: &[u8],
) -> ClipboardTransferOffer {
    ClipboardTransferOffer {
        offer: ClipboardOffer {
            id: Id128(11),
            owner: Id128(12),
            generation: 3,
            flavors: vec![viewflow_protocol::ClipboardFlavor {
                name: "text/plain;charset=utf-8".into(),
                size_bytes: u64::try_from(advertised_data.len()).unwrap(),
            }],
        },
        flavors: vec![ClipboardTransferFlavor {
            name: "text/plain;charset=utf-8".into(),
            size_bytes: u64::try_from(advertised_data.len()).unwrap(),
            sha256: digest(advertised_data),
        }],
        offer_nonce: [4; 16],
        consent_correlation: correlation,
        connection_binding: binding(connection),
        payload_sequence,
    }
}

fn consent_incoming(correlation: [u8; 16], payload_sequence: u64) -> ClipboardConsent {
    ClipboardConsent::for_incoming(correlation, Id128(11), 3, [4; 16], payload_sequence).unwrap()
}

fn deadline() -> tokio::time::Instant {
    tokio::time::Instant::now() + Duration::from_secs(2)
}

fn digest(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

fn binding(connection: &Connection) -> [u8; 32] {
    let mut binding = [0; 32];
    connection
        .export_keying_material(&mut binding, b"viewflow-clipboard-v1", b"")
        .unwrap();
    binding
}

fn envelope(sequence: u64, payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
    wire::ControlEnvelope {
        protocol_major: u32::from(PROTOCOL_VERSION.major),
        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
        sequence,
        payload: Some(payload),
    }
}

fn identity() -> PeerIdentity {
    PeerIdentity::from_pem(CERT, KEY, CA).unwrap()
}

fn endpoint_server() -> Endpoint {
    Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap()
}

fn endpoint_client() -> Endpoint {
    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity()).unwrap());
    client
}
