//! Local, capability-gated native encoder control. Never sent to the remote peer.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use viewflow_core::{NetworkSample, QualityTarget, RateControlConfig, RateController};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QualityMode {
    #[default]
    Auto,
    HighQuality,
    SaveBandwidth,
}
impl QualityMode {
    #[must_use]
    pub fn from_env() -> Self {
        match std::env::var("VIEWFLOW_QUALITY_MODE").as_deref() {
            Ok("high_quality") => Self::HighQuality,
            Ok("save_bandwidth") => Self::SaveBandwidth,
            _ => Self::Auto,
        }
    }
    fn core(self) -> viewflow_core::QualityMode {
        match self {
            Self::Auto => viewflow_core::QualityMode::Auto,
            Self::HighQuality => viewflow_core::QualityMode::HighQuality,
            Self::SaveBandwidth => viewflow_core::QualityMode::SaveBandwidth,
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub(crate) struct Capability {
    pub kbps: u32,
    pub fps: u32,
}
impl Capability {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let text = std::str::from_utf8(bytes).ok()?;
        let mut fields = text.split_whitespace();
        if fields.next()? != "native-quality-v1" {
            return None;
        }
        let kbps = fields.next()?.strip_prefix("max_kbps=")?.parse().ok()?;
        let fps = fields.next()?.strip_prefix("max_fps=")?.parse().ok()?;
        if fields.next().is_some() || !(1..=80_000).contains(&kbps) || !(1..=240).contains(&fps) {
            return None;
        }
        Some(Self { kbps, fps })
    }
}
pub(crate) fn record(cap: Option<Capability>, target: QualityTarget) -> Option<[u8; 20]> {
    cap?;
    let mut bytes = [0; 20];
    for (chunk, value) in bytes.chunks_exact_mut(4).zip([
        7,
        1,
        target.kbps,
        target.max_fps,
        u32::from(target.scale_permille),
    ]) {
        chunk.copy_from_slice(&value.to_le_bytes());
    }
    Some(bytes)
}
#[derive(Default)]
struct Observations {
    stages: [[(u64, bool); 3]; 2],
    dropped: u64,
    meter: viewflow_core::SendRateMeter,
}
impl Observations {
    fn feedback(&mut self, header: &[u8]) {
        if header.len() < 24 {
            return;
        }
        let word = |at| u32::from_le_bytes(header[at..at + 4].try_into().expect("fixed header"));
        if word(0) != 5 {
            return;
        }
        let lane = word(4) as usize;
        let flags = word(8);
        let stage = word(12) as usize;
        if lane > 1 || stage > 2 || flags > 7 {
            return;
        }
        self.stages[lane][stage] = (
            u64::from_le_bytes(header[16..24].try_into().expect("fixed age")),
            flags & 2 != 0,
        );
        self.dropped += u64::from(flags & 1 != 0);
    }
    fn sample(
        &mut self,
        now_us: u64,
        stats: &quinn::ConnectionStats,
        previous: &mut (u64, u64),
    ) -> NetworkSample {
        let (sent, lost) = (stats.path.sent_packets, stats.path.lost_packets);
        let queue_age_us = self
            .stages
            .iter()
            .flatten()
            .map(|(age, saturated)| (*age).max(if *saturated { 100_000 } else { 0 }))
            .max()
            .unwrap_or(0);
        let sample = NetworkSample {
            now_us,
            rtt_us: u64::try_from(stats.path.rtt.as_micros()).unwrap_or(u64::MAX),
            sent_packets: sent.saturating_sub(previous.0),
            lost_packets: lost.saturating_sub(previous.1),
            queue_age_us,
            frames_dropped: std::mem::take(&mut self.dropped),
            send_kbps: self.meter.update(now_us, stats.udp_tx.bytes),
        };
        *previous = (sent, lost);
        sample
    }
}

// The input relay is buffered, not restarted at timer ticks. A fragmented input
// record can span any number of samples without losing bytes or reordering.
// Stack buffers and the preallocated duplex pipe add no per-frame allocation.
pub(crate) async fn drive<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    reader: &mut R,
    writer: &mut W,
    connection: &quinn::Connection,
    capability: Option<Capability>,
    mode: QualityMode,
) -> Result<()> {
    let Some(cap) = capability else {
        tokio::io::copy(reader, writer).await?;
        return Ok(());
    };
    let mut controller =
        RateController::new(RateControlConfig::new(mode.core(), cap.kbps, cap.fps));
    let start = Instant::now();
    let mut report = Instant::now();
    let stats = connection.stats();
    let mut previous = (stats.path.sent_packets, stats.path.lost_packets);
    let mut observations = Observations::default();
    let mut last = None;
    let mut timer = tokio::time::interval(Duration::from_millis(200));
    loop {
        let mut header = [0u8; 24];
        let read_header = async {
            let size = reader.read_u32_le().await? as usize;
            anyhow::ensure!(
                (4..=96 * 1024 * 1024).contains(&size),
                "native input record length"
            );
            reader.read_exact(&mut header[..size.min(24)]).await?;
            Ok::<_, anyhow::Error>(size)
        };
        tokio::pin!(read_header);
        let size = loop {
            tokio::select! {
                result=&mut read_header => break result?,
                _=timer.tick() => {
                    let stats=connection.stats();
                    let sample=observations.sample(u64::try_from(start.elapsed().as_micros()).unwrap_or(u64::MAX),&stats,&mut previous);
                    let target=controller.on_sample(sample);
                    let changed=last!=Some(target);
                    // HighQuality leaves native setup and existing pacing exactly alone.
                    if mode!=QualityMode::HighQuality && let Some(bytes)=record(Some(cap),target) {
                        writer.write_u32_le(20).await?;writer.write_all(&bytes).await?;writer.flush().await?;
                    }
                    if changed {
                        eprintln!("native-quality target kbps={} max_fps={} scale_permille={} rtt_us={} lost={} sent={} queue_us={} cwnd={}",target.kbps,target.max_fps,target.scale_permille,sample.rtt_us,sample.lost_packets,sample.sent_packets,sample.queue_age_us,stats.path.cwnd);
                    }
                    if report.elapsed()>=Duration::from_secs(5) {
                        eprintln!("native-quality summary kbps={} max_fps={} scale_permille={} rtt_us={} cwnd={}",target.kbps,target.max_fps,target.scale_permille,sample.rtt_us,stats.path.cwnd);
                        report=Instant::now();
                    }
                    last=Some(target);
                }
            }
        };
        observations.feedback(&header[..size.min(24)]);
        writer.write_u32_le(u32::try_from(size)?).await?;
        writer.write_all(&header[..size.min(24)]).await?;
        if size > 24 {
            let copied = tokio::io::copy(&mut reader.take((size - 24) as u64), writer).await?;
            anyhow::ensure!(copied == (size - 24) as u64, "native input truncated");
        }
        writer.flush().await?;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parsing_and_gating() {
        assert_eq!(
            serde_json::from_str::<QualityMode>("\"save_bandwidth\"").unwrap(),
            QualityMode::SaveBandwidth
        );
        assert!(serde_json::from_str::<QualityMode>("\"invalid\"").is_err());
        assert!(Capability::parse(b"activity-priority-v1\n").is_none());
        assert!(Capability::parse(b"native-quality-v1 max_kbps=0 max_fps=60\n").is_none());
        let cap = Capability::parse(b"native-quality-v1 max_kbps=24000 max_fps=60\n");
        let target = RateController::new(RateControlConfig::new(
            QualityMode::SaveBandwidth.core(),
            24000,
            60,
        ))
        .target();
        assert!(record(None, target).is_none());
        let bytes = record(cap, target).unwrap();
        assert_eq!(
            bytes,
            [
                7, 0, 0, 0, 1, 0, 0, 0, 112, 23, 0, 0, 60, 0, 0, 0, 232, 3, 0, 0
            ]
        );
    }
    #[test]
    fn sample_uses_deltas_feedback_and_resets_drops() {
        let mut obs = Observations::default();
        let mut header = [0; 24];
        header[0..4].copy_from_slice(&5u32.to_le_bytes());
        header[8..12].copy_from_slice(&3u32.to_le_bytes());
        header[16..24].copy_from_slice(&55000u64.to_le_bytes());
        obs.feedback(&header);
        let mut stats = quinn::ConnectionStats::default();
        stats.path.sent_packets = 110;
        stats.path.lost_packets = 7;
        let mut prev = (100, 5);
        let sample = obs.sample(200_000, &stats, &mut prev);
        assert_eq!(
            (
                sample.sent_packets,
                sample.lost_packets,
                sample.frames_dropped,
                sample.queue_age_us
            ),
            (10, 2, 1, 100_000)
        );
        assert_eq!(obs.sample(400_000, &stats, &mut prev).frames_dropped, 0);
    }
    async fn connection() -> (
        quinn::Endpoint,
        quinn::Endpoint,
        quinn::Connection,
        quinn::Connection,
    ) {
        use std::sync::Arc;
        use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let transport = Arc::new(quinn::TransportConfig::default());
        let mut server_config = build_server_config(&identity).unwrap();
        server_config.transport_config(transport.clone());
        let server =
            quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let mut client_config = build_client_config(&identity).unwrap();
        client_config.transport_config(transport);
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(client_config);
        let (a, b) = tokio::join!(
            client
                .connect(server.local_addr().unwrap(), "localhost")
                .unwrap(),
            async { server.accept().await.unwrap().await }
        );
        (client, server, a.unwrap(), b.unwrap())
    }
    #[tokio::test]
    async fn old_native_and_high_quality_receive_only_original_records() {
        let (_client, _server, conn, _peer) = connection().await;
        for (cap, mode) in [
            (None, QualityMode::Auto),
            (
                Some(Capability {
                    kbps: 24000,
                    fps: 60,
                }),
                QualityMode::HighQuality,
            ),
        ] {
            let (mut source, mut input) = tokio::io::duplex(256);
            let (mut output, mut native) = tokio::io::duplex(256);
            let packet = [4, 0, 0, 0, 2, 0, 0, 0];
            let relay = drive(&mut input, &mut output, &conn, cap, mode);
            let check = async {
                source.write_all(&packet).await.unwrap();
                let mut received = [0; 8];
                native.read_exact(&mut received).await.unwrap();
                assert_eq!(received, packet);
                assert!(
                    tokio::time::timeout(Duration::from_millis(450), native.read_u8())
                        .await
                        .is_err()
                );
            };
            tokio::select! {r=relay=>panic!("relay stopped: {r:?}"),()=check=>{}}
        }
    }
    #[tokio::test]
    async fn fragmented_record_survives_quality_timer_ticks() {
        let (_client, _server, conn, _peer) = connection().await;
        let (mut source, mut input) = tokio::io::duplex(256);
        let (mut output, mut native) = tokio::io::duplex(1024);
        let relay = drive(
            &mut input,
            &mut output,
            &conn,
            Some(Capability {
                kbps: 24000,
                fps: 60,
            }),
            QualityMode::SaveBandwidth,
        );
        let check = async {
            source.write_all(&[4, 0]).await.unwrap();
            tokio::time::sleep(Duration::from_millis(250)).await;
            source.write_all(&[0, 0, 2, 0, 0, 0]).await.unwrap();
            let mut quality_records = 0;
            loop {
                let size = native.read_u32_le().await.unwrap();
                if size == 4 {
                    assert_eq!(native.read_u32_le().await.unwrap(), 2);
                    break;
                }
                assert_eq!(size, 20);
                let mut quality = [0; 20];
                native.read_exact(&mut quality).await.unwrap();
                assert_eq!(
                    quality,
                    record(
                        Some(Capability {
                            kbps: 24000,
                            fps: 60
                        }),
                        QualityTarget {
                            kbps: 6000,
                            max_fps: 60,
                            scale_permille: 1000
                        }
                    )
                    .unwrap()
                );
                quality_records += 1;
            }
            assert!(quality_records >= 1);
        };
        tokio::select! {r=relay=>panic!("relay stopped: {r:?}"),r=tokio::time::timeout(Duration::from_secs(3),check)=>r.unwrap()}
    }
}
