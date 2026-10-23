use std::{io::Cursor, net::SocketAddr, sync::Arc, time::Duration};

use bytes::Bytes;
use quinn::{ClientConfig, Connection, Endpoint, crypto::rustls::QuicClientConfig};
use viewflow_core::{Coordinator, FrameAdmission};
use viewflow_protocol::{DomainControl, Id128, PROTOCOL_VERSION, wire};
use viewflow_transport::{
    ALPN, BlobChunk, ControlSequencer, MediaAssembler, MediaAssemblerConfig, MediaDatagram,
    MediaPlane, PeerIdentity, ReliablePayload, build_client_config, build_server_config,
    receive_control_sequenced, receive_reliable, send_blob_chunk, send_control,
};

const CERT: &[u8] = include_bytes!("fixtures/peer.pem");
const KEY: &[u8] = include_bytes!("fixtures/peer.key");
const CA: &[u8] = include_bytes!("fixtures/ca.pem");

#[tokio::test]
async fn keyboard_controls_cross_authenticated_quic_without_device_authority() {
    use viewflow_protocol::{
        InputSwitchState, KeyboardHidUsage, WindowKeyboardAck, WindowKeyboardAuthorization,
        WindowKeyboardEvent, WindowKeyboardMode, WindowKeyboardResult,
    };
    tokio::time::timeout(Duration::from_secs(3), async {
        let server = Endpoint::server(
            build_server_config(&identity()).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let address = server.local_addr().unwrap();
        let auth = WindowKeyboardAuthorization {
            lease_generation: 8,
            owner_device: Id128(1),
            target_device: Id128((42 << 64) | 2),
            target_window: Id128((73 << 64) | 3),
            geometry_epoch: 4,
            presented_frame: 5,
            source_not_after_ns: 900,
            mode: WindowKeyboardMode::DirectApplication,
        };
        let key = WindowKeyboardEvent {
            lease_generation: auth.lease_generation,
            target_device: auth.target_device,
            target_window: auth.target_window,
            geometry_epoch: auth.geometry_epoch,
            presented_frame: auth.presented_frame,
            sequence: 1,
            sender_not_after_ns: 800,
            key: KeyboardHidUsage {
                usage_page: 7,
                usage_id: 0xe1,
                state: InputSwitchState::Pressed,
                repeat: false,
            },
        };
        let source = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            send_control(
                &connection,
                &envelope(
                    1,
                    wire::control_envelope::Payload::WindowKeyboardAuthorization(auth.into()),
                ),
            )
            .await
            .unwrap();
            let mut sequence = ControlSequencer::default();
            let request = receive_control_sequenced(&connection, &mut sequence)
                .await
                .unwrap();
            let decoded = DomainControl::try_from(request).unwrap();
            assert_eq!(decoded, DomainControl::WindowKeyboardEvent(key));
            assert_eq!(
                Coordinator::default().apply_control(decoded),
                Err(viewflow_core::CoordinatorError::WindowInputRuntimeRequired)
            );
            // This transport fixture has no native keyboard. It must not claim
            // native delivery merely because mTLS and wire validation succeeded.
            let ack = WindowKeyboardAck {
                event: key,
                result: WindowKeyboardResult::Rejected,
            };
            send_control(
                &connection,
                &envelope(
                    2,
                    wire::control_envelope::Payload::WindowKeyboardAck(ack.into()),
                ),
            )
            .await
            .unwrap();
            assert!(
                receive_control_sequenced(&connection, &mut sequence)
                    .await
                    .is_err()
            );
        });
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity()).unwrap());
        let connection = client.connect(address, "localhost").unwrap().await.unwrap();
        let mut sequence = ControlSequencer::default();
        assert_eq!(
            DomainControl::try_from(
                receive_control_sequenced(&connection, &mut sequence)
                    .await
                    .unwrap()
            )
            .unwrap(),
            DomainControl::WindowKeyboardAuthorization(auth)
        );
        let request = envelope(
            1,
            wire::control_envelope::Payload::WindowKeyboardEvent(key.into()),
        );
        send_control(&connection, &request).await.unwrap();
        assert_eq!(
            DomainControl::try_from(
                receive_control_sequenced(&connection, &mut sequence)
                    .await
                    .unwrap()
            )
            .unwrap(),
            DomainControl::WindowKeyboardAck(WindowKeyboardAck {
                event: key,
                result: WindowKeyboardResult::Rejected
            })
        );
        send_control(&connection, &request).await.unwrap(); // envelope replay must fail
        source.await.unwrap();
    })
    .await
    .unwrap();
}

fn identity() -> PeerIdentity {
    PeerIdentity::from_pem(CERT, KEY, CA).unwrap()
}

fn wire_id(low: u64) -> wire::Id128 {
    wire::Id128 { high: 0, low }
}

fn wire_size(width: f64, height: f64) -> wire::Size {
    wire::Size { width, height }
}

fn wire_rect(x: f64, width: f64) -> wire::Rect {
    wire::Rect {
        origin: Some(wire::Point { x, y: 0.0 }),
        size: Some(wire_size(width, 100.0)),
    }
}

fn envelope(sequence: u64, payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
    wire::ControlEnvelope {
        protocol_major: u32::from(PROTOCOL_VERSION.major),
        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
        sequence,
        payload: Some(payload),
    }
}

async fn receive_workload(
    connection: Connection,
) -> (Option<(Id128, Id128)>, Bytes, FrameAdmission, BlobChunk) {
    let mut coordinator = Coordinator::default();
    let mut sequencer = ControlSequencer::default();
    for _ in 0..3 {
        let control = receive_control_sequenced(&connection, &mut sequencer)
            .await
            .unwrap();
        let sequence = control.sequence;
        coordinator
            .apply_control_sequenced(sequence, DomainControl::try_from(control).unwrap())
            .unwrap();
    }
    let blob = match receive_reliable(&connection).await.unwrap() {
        ReliablePayload::BlobChunk(chunk) => chunk,
        ReliablePayload::Control(_) => panic!("expected file chunk after controls"),
    };
    let mut media_assembler = MediaAssembler::new(MediaAssemblerConfig::default());
    let assembled_plane = loop {
        let packet = MediaDatagram::decode(connection.read_datagram().await.unwrap()).unwrap();
        if let Some(plane) = media_assembler.push(packet, 200).unwrap() {
            break plane;
        }
    };
    let admission = coordinator
        .ingest_frame_plane(assembled_plane.ready)
        .unwrap();
    (
        coordinator.active_input_route(),
        assembled_plane.payload,
        admission,
        blob,
    )
}

async fn send_test_controls(connection: &Connection) {
    let topology = envelope(
        1,
        wire::control_envelope::Payload::Topology(wire::DeviceTopology {
            generation: 1,
            displays: vec![
                wire::DisplayDescriptor {
                    id: Some(wire_id(10)),
                    device_id: Some(wire_id(1)),
                    bounds_dip: Some(wire_rect(0.0, 100.0)),
                    scale: 1.0,
                    refresh_millihz: 60_000,
                },
                wire::DisplayDescriptor {
                    id: Some(wire_id(11)),
                    device_id: Some(wire_id(2)),
                    bounds_dip: Some(wire_rect(100.0, 100.0)),
                    scale: 2.0,
                    refresh_millihz: 60_000,
                },
            ],
        }),
    );
    send_control(connection, &topology).await.unwrap();

    let window = envelope(
        2,
        wire::control_envelope::Payload::WindowDescriptor(wire::WindowDescriptor {
            id: Some(wire_id(55)),
            family_id: Some(wire_id(56)),
            source_device: Some(wire_id(1)),
            role: wire::WindowRole::Main.into(),
            bounds_dip: Some(wire_rect(75.0, 50.0)),
            min_size_dip: Some(wire_size(20.0, 20.0)),
            max_size_dip: None,
            has_alpha: false,
            blur_radius_dip: None,
        }),
    );
    send_control(connection, &window).await.unwrap();

    let lease = envelope(
        3,
        wire::control_envelope::Payload::InputLease(wire::InputLease {
            generation: 1,
            owner: Some(wire_id(1)),
            route_to: Some(wire_id(2)),
            state: wire::InputLeaseState::Active.into(),
        }),
    );
    send_control(connection, &lease).await.unwrap();
}

async fn send_test_blob_and_media(connection: &Connection) -> BlobChunk {
    let blob = BlobChunk {
        transfer_id: Id128(77),
        item_index: 2,
        offset_bytes: 1_048_576,
        final_chunk: true,
        payload: Bytes::from_static(b"reliable file bytes"),
    };
    send_blob_chunk(connection, &blob).await.unwrap();

    let media_tail = MediaDatagram {
        window_id: Id128(55),
        frame_id: 8,
        geometry_epoch: 0,
        plane: MediaPlane::Color,
        chunk_index: 1,
        chunk_count: 2,
        source_submitted_ns: 100,
        payload: Bytes::from_static(b" frame"),
    };
    let media_head = MediaDatagram {
        chunk_index: 0,
        payload: Bytes::from_static(b"encoded"),
        ..media_tail.clone()
    };
    connection.send_datagram(media_tail.encode()).unwrap();
    connection.send_datagram(media_head.encode()).unwrap();
    blob
}

#[tokio::test]
async fn mutually_authenticated_control_and_media_drive_coordinator() {
    let server = Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let incoming = server.accept().await.unwrap();
        receive_workload(incoming.await.unwrap()).await
    });

    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity()).unwrap());
    let connection = client
        .connect(server_addr, "localhost")
        .unwrap()
        .await
        .unwrap();
    send_test_controls(&connection).await;
    let blob = send_test_blob_and_media(&connection).await;

    let (route, payload, admission, received_blob) =
        tokio::time::timeout(Duration::from_secs(2), server_task)
            .await
            .unwrap()
            .unwrap();
    assert_eq!(route, Some((Id128(1), Id128(2))));
    assert_eq!(payload, Bytes::from_static(b"encoded frame"));
    assert!(matches!(admission, FrameAdmission::Ready(frame) if frame.frame_id == 8));
    assert_eq!(received_blob, blob);
}

#[tokio::test]
async fn server_rejects_client_without_paired_certificate() {
    let server = Endpoint::server(
        build_server_config(&identity()).unwrap(),
        "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
    )
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        let incoming = server.accept().await.expect("client attempted connection");
        incoming.await
    });

    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_pemfile::certs(&mut Cursor::new(CA)) {
        roots.add(certificate.unwrap()).unwrap();
    }
    let mut tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let config = ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls).unwrap()));
    let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
    client.set_default_client_config(config);

    let client_connect = client.connect(server_addr, "localhost").unwrap();
    let (client_result, server_result) = tokio::time::timeout(Duration::from_secs(2), async {
        tokio::join!(client_connect, server_task)
    })
    .await
    .expect("mutual TLS handshake must finish rather than stall");
    let server_result = server_result.expect("server handshake task must not panic");

    assert!(
        client_result.is_err() || server_result.is_err(),
        "a client without a paired certificate must not authenticate"
    );
}
