//! Dedicated, refreshable clock stream for atlas capture timestamps. Mapping
//! never renews a source timestamp and expires independently of media traffic.
use anyhow::{Context, Result, ensure};
use quinn::{Connection, RecvStream, SendStream};
use std::time::Duration;
use tokio::time::{Instant, timeout_at};
use viewflow_transport::ClockEstimate;

const MAGIC: &[u8; 4] = b"VFCT";

/// Receiver-clock lower bound for a source capture time. Subtracting the full
/// measured uncertainty makes admission conservative within that clock model.
#[derive(Clone, Copy, Debug)]
pub struct AtlasClockMapping {
    estimate: ClockEstimate,
    valid_until: Instant,
    binding: [u8; 32],
}

impl AtlasClockMapping {
    /// # Errors
    /// Expired estimates and unrepresentable/zero timestamps are never clamped
    /// into apparently fresh media times. Refresh before mapping more frames.
    pub fn map_source_ns(self, connection: &Connection, source_ns: u64) -> Result<u64> {
        ensure!(
            connection.close_reason().is_none() && self.binding == binding(connection)?,
            "atlas clock belongs to a different or closed connection"
        );
        ensure!(
            Instant::now() < self.valid_until,
            "atlas clock mapping expired"
        );
        let mapped = i128::from(source_ns) + i128::from(self.estimate.remote_offset_ns)
            - i128::from(self.estimate.uncertainty_ns);
        let mapped = u64::try_from(mapped).context("atlas mapped clock overflow")?;
        ensure!(source_ns > 0 && mapped > 0, "invalid atlas capture clock");
        Ok(mapped)
    }
}

fn binding(connection: &Connection) -> Result<[u8; 32]> {
    let mut value = [0; 32];
    connection
        .export_keying_material(&mut value, b"viewflow-atlas-clock-v1", b"")
        .map_err(|_| anyhow::anyhow!("atlas clock TLS binding unavailable"))?;
    Ok(value)
}

struct ClockGuard(Option<Connection>);
impl Drop for ClockGuard {
    fn drop(&mut self) {
        if let Some(connection) = &self.0 {
            connection.close(0_u32.into(), b"atlas clock stream retired");
        }
    }
}

pub struct AtlasClockClient {
    connection: Connection,
    io: Option<(SendStream, RecvStream)>,
    max_uncertainty_ns: u64,
    valid_for: Duration,
    last_clock_ns: Option<u64>,
}

impl Drop for AtlasClockClient {
    fn drop(&mut self) {
        self.connection
            .close(0_u32.into(), b"atlas clock owner stopped");
    }
}

impl AtlasClockClient {
    /// Open this stream before atlas startup on the dedicated paired connection.
    /// # Errors
    /// The caller must refresh it before any source timestamp can be mapped.
    pub async fn open(
        connection: &Connection,
        max_uncertainty_ns: u64,
        valid_for: Duration,
        deadline: Instant,
    ) -> Result<Self> {
        let mut guard = ClockGuard(Some(connection.clone()));
        ensure!(
            connection.peer_identity().is_some(),
            "atlas clock requires authenticated peer"
        );
        ensure!(
            max_uncertainty_ns > 0 && !valid_for.is_zero() && valid_for <= Duration::from_secs(30),
            "invalid atlas clock policy"
        );
        ensure!(Instant::now() < deadline, "atlas clock startup expired");
        let io = timeout_at(deadline, connection.open_bi()).await??;
        guard.0 = None;
        Ok(Self {
            connection: connection.clone(),
            io: Some(io),
            max_uncertainty_ns,
            valid_for,
            last_clock_ns: None,
        })
    }

    /// # Errors
    /// Invalid exchanges, excessive uncertainty, expiry or cancellation retire
    /// this connection. `now` must use the capture's native monotonic clock.
    pub async fn refresh(
        &mut self,
        now: impl FnMut() -> Result<u64>,
        deadline: Instant,
    ) -> Result<AtlasClockMapping> {
        self.sample(now, deadline, 1).await
    }

    /// Take eight bounded startup measurements and select the lowest-RTT still
    /// valid sample. High jitter is not hidden by increasing the accepted bound.
    /// # Errors
    /// No acceptable sample, malformed exchange, timeout or cancellation closes
    /// the connection. Each sample retains its own original validity deadline.
    pub async fn calibrate(
        &mut self,
        now: impl FnMut() -> Result<u64>,
        deadline: Instant,
    ) -> Result<AtlasClockMapping> {
        self.sample(now, deadline, 8).await
    }

    async fn sample(
        &mut self,
        mut now: impl FnMut() -> Result<u64>,
        deadline: Instant,
        count: usize,
    ) -> Result<AtlasClockMapping> {
        let mut guard = ClockGuard(Some(self.connection.clone()));
        let mut io = self.io.take().context("atlas clock client retired")?;
        ensure!(Instant::now() < deadline, "atlas clock refresh expired");
        let binding = binding(&self.connection)?;
        let mut last_clock = self.last_clock_ns;
        let mapping = timeout_at(deadline, async {
            let mut samples = Vec::with_capacity(count);
            for _ in 0..count {
                let valid_until = Instant::now()
                    .checked_add(self.valid_for)
                    .context("atlas clock validity overflow")?;
                let t0 = now()?;
                ensure!(
                    t0 > 0 && last_clock.is_none_or(|last| t0 >= last),
                    "source clock went backwards"
                );
                io.0.write_all(MAGIC).await?;
                io.0.write_all(&t0.to_be_bytes()).await?;
                let mut reply = [0; 16];
                io.1.read_exact(&mut reply).await?;
                let t3 = now()?;
                let estimate = ClockEstimate::from_exchange(
                    t0,
                    u64::from_be_bytes(reply[..8].try_into()?),
                    u64::from_be_bytes(reply[8..].try_into()?),
                    t3,
                )?;
                samples.push(AtlasClockMapping {
                    estimate,
                    valid_until,
                    binding,
                });
                last_clock = Some(t3);
            }
            let now = Instant::now();
            ensure!(now < deadline, "atlas clock refresh expired");
            let mapping = samples
                .into_iter()
                .filter(|sample| now < sample.valid_until)
                .min_by_key(|sample| sample.estimate.network_round_trip_ns)
                .context("atlas clock estimate already expired")?;
            ensure!(
                mapping.estimate.uncertainty_ns <= self.max_uncertainty_ns,
                "atlas clock uncertainty exceeds budget: measured_ns={} limit_ns={}",
                mapping.estimate.uncertainty_ns,
                self.max_uncertainty_ns
            );
            Ok::<_, anyhow::Error>(mapping)
        })
        .await??;
        self.io = Some(io);
        self.last_clock_ns = last_clock;
        guard.0 = None;
        Ok(mapping)
    }
}

pub struct AtlasClockServer {
    connection: Connection,
    io: Option<(SendStream, RecvStream)>,
    last_clock_ns: Option<u64>,
}

impl Drop for AtlasClockServer {
    fn drop(&mut self) {
        self.connection
            .close(0_u32.into(), b"atlas clock owner stopped");
    }
}

impl AtlasClockServer {
    /// Accept the first dedicated bidirectional stream before atlas startup.
    /// # Errors
    /// This does not accept an atlas plan or authorize media by itself.
    pub async fn accept(connection: &Connection, deadline: Instant) -> Result<Self> {
        let mut guard = ClockGuard(Some(connection.clone()));
        ensure!(
            connection.peer_identity().is_some() && Instant::now() < deadline,
            "invalid atlas clock startup"
        );
        let io = timeout_at(deadline, connection.accept_bi()).await??;
        guard.0 = None;
        Ok(Self {
            connection: connection.clone(),
            io: Some(io),
            last_clock_ns: None,
        })
    }

    /// Respond once, using the receiver's native monotonic clock. Keep calling
    /// under a bounded silence deadline while the media session is active.
    /// # Errors
    /// Failure/cancellation closes this dedicated connection, not just a stream.
    pub async fn respond(
        &mut self,
        mut now: impl FnMut() -> Result<u64>,
        deadline: Instant,
    ) -> Result<()> {
        let mut guard = ClockGuard(Some(self.connection.clone()));
        let mut io = self.io.take().context("atlas clock server retired")?;
        ensure!(Instant::now() < deadline, "atlas clock response expired");
        timeout_at(deadline, async {
            let mut probe = [0; 12];
            io.1.read_exact(&mut probe).await?;
            let t1 = now()?;
            ensure!(
                self.last_clock_ns.is_none_or(|last| t1 >= last),
                "receiver clock went backwards"
            );
            ensure!(
                &probe[..4] == MAGIC && u64::from_be_bytes(probe[4..].try_into()?) > 0,
                "invalid atlas clock probe"
            );
            let t2 = now()?;
            ensure!(t1 > 0 && t2 >= t1, "receiver clock went backwards");
            io.0.write_all(&t1.to_be_bytes()).await?;
            io.0.write_all(&t2.to_be_bytes()).await?;
            ensure!(Instant::now() < deadline, "atlas clock response expired");
            self.last_clock_ns = Some(t2);
            Ok::<_, anyhow::Error>(())
        })
        .await??;
        self.io = Some(io);
        guard.0 = None;
        Ok(())
    }
}

/// Receiver clock used both by the clock responder and live frame admission.
/// # Errors
/// Rejects unavailable QPC and timestamp conversion overflow.
#[cfg(windows)]
pub fn windows_now_ns() -> Result<u64> {
    let sample = crate::atlas_receiver_presenter::QpcSample::current()?;
    u64::try_from(u128::from(sample.ticks) * 1_000_000_000 / u128::from(sample.frequency))
        .context("Windows monotonic clock overflow")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atlas_session::tests::pair;

    #[tokio::test]
    async fn refreshed_mapping_is_conservative_expiring_and_connection_bound() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut client = AtlasClockClient::open(&outbound, 20, Duration::from_secs(1), deadline)
            .await
            .unwrap();
        let mut source = [100, 120].into_iter();
        let (mapping, server) = tokio::join!(
            client.refresh(|| Ok(source.next().unwrap()), deadline),
            async {
                let mut server = AtlasClockServer::accept(&inbound, deadline).await.unwrap();
                server.respond(|| Ok(1010), deadline).await.unwrap();
                server
            }
        );
        let mut server = server;
        let mapping = mapping.unwrap();
        assert_eq!(mapping.map_source_ns(&outbound, 200).unwrap(), 1090);
        let expired = AtlasClockMapping {
            valid_until: Instant::now(),
            ..mapping
        };
        assert!(expired.map_source_ns(&outbound, 200).is_err());
        let mut source = [200, 220].into_iter();
        let (refreshed, response) = tokio::join!(
            client.refresh(|| Ok(source.next().unwrap()), deadline),
            server.respond(|| Ok(1110), deadline)
        );
        response.unwrap();
        assert_eq!(
            refreshed.unwrap().map_source_ns(&outbound, 300).unwrap(),
            1190
        );
        let (_c2, _s2, foreign, _remote2) = pair().await;
        assert!(mapping.map_source_ns(&foreign, 200).is_err());
        let too_small = AtlasClockMapping {
            estimate: ClockEstimate {
                remote_offset_ns: -1000,
                ..mapping.estimate
            },
            ..mapping
        };
        assert!(too_small.map_source_ns(&outbound, 1).is_err());
        assert!(mapping.map_source_ns(&outbound, u64::MAX).is_err());
        outbound.close(0_u32.into(), b"test close");
        assert!(mapping.map_source_ns(&outbound, 200).is_err());
    }

    #[tokio::test]
    async fn excessive_uncertainty_retires_the_connection() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut client = AtlasClockClient::open(&outbound, 5, Duration::from_secs(1), deadline)
            .await
            .unwrap();
        let mut source = [100, 200].into_iter();
        let (mapping, server) = tokio::join!(
            client.refresh(|| Ok(source.next().unwrap()), deadline),
            async {
                let mut server = AtlasClockServer::accept(&inbound, deadline).await.unwrap();
                server.respond(|| Ok(1000), deadline).await.unwrap();
                server
            }
        );
        assert!(mapping.unwrap_err().to_string().contains("uncertainty"));
        assert!(outbound.close_reason().is_some());
        drop(server);
    }

    #[tokio::test]
    async fn calibration_selects_low_jitter_without_relaxing_the_bound() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut client = AtlasClockClient::open(&outbound, 5, Duration::from_secs(1), deadline)
            .await
            .unwrap();
        let mut call = 0_u64;
        let source_clock = || {
            let sample = call / 2;
            let value = 100
                + sample * 100
                + if call % 2 == 0 {
                    0
                } else if sample == 3 {
                    2
                } else {
                    100
                };
            call += 1;
            Ok(value)
        };
        let (mapping, server) = tokio::join!(client.calibrate(source_clock, deadline), async {
            let mut server = AtlasClockServer::accept(&inbound, deadline).await.unwrap();
            for sample in 0..8 {
                server
                    .respond(|| Ok(1000 + sample * 100), deadline)
                    .await
                    .unwrap();
            }
            server
        });
        let mapping = mapping.unwrap();
        assert_eq!(call, 16);
        assert_eq!(mapping.estimate.uncertainty_ns, 1);
        assert_eq!(mapping.map_source_ns(&outbound, 2000).unwrap(), 2898);
        drop(server);
    }

    #[tokio::test]
    async fn cancelled_refresh_cannot_be_reused() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut client = AtlasClockClient::open(&outbound, 5, Duration::from_secs(1), deadline)
            .await
            .unwrap();
        let mut refresh = Box::pin(client.refresh(|| Ok(100), deadline));
        let (waiting, _streams) = tokio::join!(
            tokio::time::timeout(Duration::from_millis(10), &mut refresh),
            inbound.accept_bi()
        );
        assert!(waiting.is_err());
        drop(refresh);
        assert!(outbound.close_reason().is_some());
        assert!(client.refresh(|| Ok(200), deadline).await.is_err());
    }
}
