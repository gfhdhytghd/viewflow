//! Native backend fixtures only: no capture, GUI windows, or injected input.
#![cfg(unix)]
use std::{path::Path, time::Duration};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
use viewflowd::reverse_bridge::{ReverseBridgeConfig, run_window_bridge};

const NATIVE_FIXTURE: &str = r#"
import os, struct, sys, time
from pathlib import Path
role, root, restart = sys.argv[1:]
root = Path(root)
def record(payload):
    sys.stdout.buffer.write(struct.pack('<I', len(payload)) + payload)
    sys.stdout.buffer.flush()
def read():
    header = sys.stdin.buffer.read(4)
    if not header: return None
    assert len(header) == 4
    size, = struct.unpack('<I', header)
    payload = sys.stdin.buffer.read(size)
    assert len(payload) == size
    return payload
attempts = root / (role + '-starts')
with attempts.open('a') as log: log.write('start\n')
if role == 'source':
    # Valid VFRV record framing; synthetic codec bytes aren't decoded here.
    frame = struct.pack('<IIIIqII', 1, 1, 2, 2, 1, 1, 0)
    frame += struct.pack('<I', 5) + bytes(5) + struct.pack('<I', 5) + b'\0\0\0\1\x65'
    record(frame)
    event = read()
    assert struct.unpack_from('<I', event)[0] == 2
    assert struct.unpack_from('<Q', event, 12)[0] == 1
    with (root / 'roundtrips').open('a') as log: log.write('ordered\n')
    if restart == 'yes' and attempts.read_text().count('start') == 1: sys.exit(7)
    while read() is not None: pass
else:
    frame = read()
    assert struct.unpack_from('<I', frame)[0] == 1
    # A normal scheduling delay larger than 33 ms doesn't revoke the session.
    time.sleep(0.080)
    record(struct.pack('<IQQIiiii', 2, 1, 1, 1, -50, 40, 0, 0))
    while read() is not None: pass
with (root / (role + '-cleaned')).open('a') as log: log.write('eof\n')
"#;

fn config(root: &Path, source: bool, restart: bool) -> ReverseBridgeConfig {
    ReverseBridgeConfig {
        native: Path::new("/usr/bin/python3").into(),
        args: vec![
            root.join("native.py").to_str().unwrap().into(),
            if source { "source" } else { "presenter" }.into(),
            root.to_str().unwrap().into(),
            if restart { "yes" } else { "no" }.into(),
        ],
    }
}

async fn trial(server_is_source: bool, restart: bool) {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("native.py"), NATIVE_FIXTURE).unwrap();
    let identity = PeerIdentity::from_pem(
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
    )
    .unwrap();
    let server = quinn::Endpoint::server(
        build_server_config(&identity).unwrap(),
        "127.0.0.1:0".parse().unwrap(),
    )
    .unwrap();
    let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity).unwrap());
    let connecting = client
        .connect(server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (sent, received) = tokio::join!(connecting, async { server.accept().await.unwrap().await });
    let sent = sent.unwrap();
    let received = received.unwrap();
    let source_config = config(root.path(), true, restart);
    let presenter_config = config(root.path(), false, restart);
    let (source, presenter) = if server_is_source {
        (received.clone(), sent.clone())
    } else {
        (sent.clone(), received.clone())
    };
    let source_task =
        tokio::spawn(async move { run_window_bridge(&source, &source_config, true).await });
    let presenter_task =
        tokio::spawn(async move { run_window_bridge(&presenter, &presenter_config, false).await });
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let completed = std::fs::read_to_string(root.path().join("roundtrips"))
                .unwrap_or_default()
                .lines()
                .count();
            if completed >= if restart { 2 } else { 1 } {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("ordered media/input roundtrip and native restart");
    assert!(sent.close_reason().is_none() && received.close_reason().is_none());
    sent.close(0u32.into(), b"fixture done");
    tokio::time::timeout(Duration::from_secs(5), async {
        source_task.await.unwrap().unwrap();
        presenter_task.await.unwrap().unwrap();
    })
    .await
    .expect("native EOF cleanup completes before bridge return");
    for role in ["source", "presenter"] {
        assert!(
            root.path().join(format!("{role}-cleaned")).exists(),
            "{role} missed EOF cleanup"
        );
    }
    server.close(0u32.into(), b"done");
    client.close(0u32.into(), b"done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn source_can_be_either_tls_endpoint_and_delayed_input_stays_ordered() {
    trial(false, false).await;
    trial(true, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_failure_recovers_on_same_paired_connection() {
    trial(false, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn listener_presents_two_sources_without_waiting_for_first_to_close() {
    let roots = [
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
    ];
    for root in &roots {
        std::fs::write(root.path().join("native.py"), NATIVE_FIXTURE).unwrap();
    }
    let identity = PeerIdentity::from_pem(
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
    )
    .unwrap();
    let server = quinn::Endpoint::server(
        build_server_config(&identity).unwrap(),
        "127.0.0.1:0".parse().unwrap(),
    )
    .unwrap();
    let listener = server.clone();
    let backend = config(roots[0].path(), false, false);
    let serving = tokio::spawn(async move {
        viewflowd::reverse_bridge::serve_window_bridges(&listener, &backend, false).await
    });
    let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    client.set_default_client_config(build_client_config(&identity).unwrap());
    let mut connections = Vec::new();
    let mut tasks = Vec::new();
    for root in &roots[1..] {
        let connection = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap()
            .await
            .unwrap();
        let backend = config(root.path(), true, false);
        let source = connection.clone();
        tasks.push(tokio::spawn(async move {
            run_window_bridge(&source, &backend, true).await
        }));
        connections.push(connection);
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        while !roots[1..]
            .iter()
            .all(|root| root.path().join("roundtrips").exists())
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("both sources must exchange data while both connections remain open");
    assert!(
        connections
            .iter()
            .all(|connection| connection.close_reason().is_none())
    );
    connections[0].close(0u32.into(), b"first window closed");
    tasks.remove(0).await.unwrap().unwrap();
    assert!(connections[1].close_reason().is_none());
    server.close(0u32.into(), b"listener stopped");
    tokio::time::timeout(Duration::from_secs(5), async {
        tasks.remove(0).await.unwrap().unwrap();
        serving.await.unwrap().unwrap();
    })
    .await
    .expect("listener shutdown cleans up every native backend");
    assert_eq!(
        std::fs::read_to_string(roots[0].path().join("presenter-cleaned"))
            .unwrap()
            .lines()
            .count(),
        2
    );
    client.close(0u32.into(), b"done");
}
