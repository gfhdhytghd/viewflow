//! Congestion control is local: mixed senders exchange streams and datagrams.
use bytes::Bytes;
use std::{error::Error, sync::Arc, time::Duration};
use viewflow_transport::{
    MediaCongestionController as Cc, PeerIdentity, build_client_config, build_server_config,
    media_transport_config_with,
};

type TestResult = Result<(), Box<dyn Error + Send + Sync>>;

async fn exchange(client_cc: Cc, server_cc: Cc) -> TestResult {
    let identity = PeerIdentity::from_pem(
        include_bytes!("fixtures/peer.pem"),
        include_bytes!("fixtures/peer.key"),
        include_bytes!("fixtures/ca.pem"),
    )?;
    let mut server_config = build_server_config(&identity)?;
    server_config.transport_config(Arc::new(media_transport_config_with(server_cc)));
    let server = quinn::Endpoint::server(server_config, "127.0.0.1:0".parse()?)?;
    let mut client_config = build_client_config(&identity)?;
    client_config.transport_config(Arc::new(media_transport_config_with(client_cc)));
    let mut client = quinn::Endpoint::client("127.0.0.1:0".parse()?)?;
    client.set_default_client_config(client_config);
    let (outbound, inbound) =
        tokio::join!(client.connect(server.local_addr()?, "localhost")?, async {
            server.accept().await.expect("incoming connection").await
        });
    let outbound = outbound?;
    let inbound = inbound?;
    for (sender, receiver) in [(&outbound, &inbound), (&inbound, &outbound)] {
        let payload = vec![42; 128 * 1024];
        let (sent, received) = tokio::join!(
            async {
                let mut stream = sender.open_uni().await?;
                stream.write_all(&payload).await?;
                stream.finish()?;
                Ok::<_, Box<dyn Error + Send + Sync>>(())
            },
            async {
                let mut stream = receiver.accept_uni().await?;
                Ok::<_, Box<dyn Error + Send + Sync>>(stream.read_to_end(payload.len()).await?)
            }
        );
        sent?;
        assert_eq!(received?, payload);
        sender.send_datagram(Bytes::from_static(b"media"))?;
        assert_eq!(receiver.read_datagram().await?.as_ref(), b"media");
    }
    outbound.close(0u32.into(), b"test complete");
    Ok(())
}

#[tokio::test]
async fn mixed_cubic_bbr_streams_and_datagrams_both_directions() -> TestResult {
    tokio::time::timeout(Duration::from_secs(10), async {
        exchange(Cc::Cubic, Cc::Bbr).await?;
        exchange(Cc::Bbr, Cc::Cubic).await?;
        exchange(Cc::DelayCubic, Cc::Cubic).await?;
        exchange(Cc::Cubic, Cc::DelayCubic).await
    })
    .await?
}
