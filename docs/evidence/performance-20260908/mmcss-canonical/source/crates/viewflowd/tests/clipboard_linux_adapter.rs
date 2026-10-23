#![cfg(target_os = "linux")]

#[path = "../src/clipboard_runtime.rs"]
mod clipboard_runtime;

use std::{
    ffi::OsString,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::Result;
use clipboard_runtime::{
    ClipboardConsent as RuntimeConsent, ClipboardInstalled, ClipboardReceiver,
    ClipboardSendRequest, ClipboardSender, DedicatedClipboardControl,
};
use quinn::Endpoint;
use sha2::{Digest, Sha256};
use viewflow_platform::{
    ClipboardCommandRunner, ClipboardConsent as NativeConsent, ClipboardError, ClipboardPolicy,
    WlClipboardAdapter,
};
use viewflow_protocol::{ClipboardFlavor, ClipboardOffer, ClipboardTransferFlavor, Id128};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};

const CERT: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem");
const KEY: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/peer.key");
const CA: &[u8] = include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem");

#[derive(Clone, Default)]
struct FakeClipboardRunner {
    writes: Arc<Mutex<Vec<(PathBuf, Vec<OsString>, Vec<u8>)>>>,
}

impl ClipboardCommandRunner for FakeClipboardRunner {
    fn capture(
        &mut self,
        _program: &Path,
        _args: &[OsString],
        _maximum_bytes: usize,
    ) -> Result<Vec<u8>, ClipboardError> {
        Err(ClipboardError::CommandIo)
    }

    fn write(
        &mut self,
        program: &Path,
        args: &[OsString],
        bytes: &[u8],
    ) -> Result<(), ClipboardError> {
        self.writes
            .lock()
            .unwrap()
            .push((program.to_owned(), args.to_vec(), bytes.to_vec()));
        Ok(())
    }
}

#[tokio::test]
async fn verified_callback_writes_before_completed_receipt() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let correlation = [7; 16];
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let fake = FakeClipboardRunner::default();
            let writes = Arc::clone(&fake.writes);
            let mut adapter = WlClipboardAdapter::with_runner(
                fake,
                PathBuf::from("fake-wl-paste"),
                PathBuf::from("fake-wl-copy"),
                ClipboardPolicy::default(),
            );
            let receipt = receiver
                .receive(
                    incoming_consent(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |verified| {
                        adapter
                            .apply_verified_remote(
                                NativeConsent::Granted,
                                verified.transfer,
                                verified.accepted,
                                verified.payload,
                            )
                            .map_err(|error| anyhow::anyhow!("native adapter failed: {error:?}"))?;
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
            (receipt, writes.lock().unwrap().clone())
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
        let (receipt, writes) = server_task.await.unwrap();
        assert_eq!(
            complete.status,
            viewflow_protocol::ClipboardCompletionStatus::Completed
        );
        assert_eq!(receipt.status, complete.status);
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].0, PathBuf::from("fake-wl-copy"));
        assert_eq!(
            writes[0].1,
            vec![
                OsString::from("--type"),
                OsString::from("text/plain;charset=utf-8")
            ]
        );
        assert_eq!(writes[0].2, b"hello");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn denied_native_consent_writes_nothing_and_emits_failed_completion() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let correlation = [8; 16];
        let server = endpoint_server();
        let address = server.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let mut receiver =
                ClipboardReceiver::new(DedicatedClipboardControl::acquire(&connection).unwrap(), 1)
                    .unwrap();
            let fake = FakeClipboardRunner::default();
            let writes = Arc::clone(&fake.writes);
            let mut adapter = WlClipboardAdapter::with_runner(
                fake,
                PathBuf::from("fake-wl-paste"),
                PathBuf::from("fake-wl-copy"),
                ClipboardPolicy::default(),
            );
            let receipt = receiver
                .receive(
                    incoming_consent(correlation, 1),
                    "text/plain;charset=utf-8",
                    deadline(),
                    |verified| {
                        adapter
                            .apply_verified_remote(
                                NativeConsent::NotGranted,
                                verified.transfer,
                                verified.accepted,
                                verified.payload,
                            )
                            .map_err(|error| anyhow::anyhow!("native adapter denied: {error:?}"))?;
                        Ok(ClipboardInstalled)
                    },
                )
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
            (receipt, writes.lock().unwrap().len())
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
        let (receipt, write_count) = server_task.await.unwrap();
        assert_eq!(
            complete.status,
            viewflow_protocol::ClipboardCompletionStatus::Failed
        );
        assert_eq!(receipt.status, complete.status);
        assert_eq!(write_count, 0);
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
            flavors: vec![ClipboardFlavor {
                name: "text/plain;charset=utf-8".into(),
                size_bytes: u64::try_from(data.len()).unwrap(),
            }],
        },
        flavors: vec![ClipboardTransferFlavor {
            name: "text/plain;charset=utf-8".into(),
            size_bytes: u64::try_from(data.len()).unwrap(),
            sha256: Sha256::digest(data).into(),
        }],
        offer_nonce: [4; 16],
        consent: RuntimeConsent::for_outgoing(correlation, Id128(11), 3, [4; 16]).unwrap(),
        mime_type: "text/plain;charset=utf-8".into(),
        data: data.to_vec(),
    }
}

fn incoming_consent(correlation: [u8; 16], payload_sequence: u64) -> RuntimeConsent {
    RuntimeConsent::for_incoming(correlation, Id128(11), 3, [4; 16], payload_sequence).unwrap()
}

fn deadline() -> tokio::time::Instant {
    tokio::time::Instant::now() + Duration::from_secs(2)
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
