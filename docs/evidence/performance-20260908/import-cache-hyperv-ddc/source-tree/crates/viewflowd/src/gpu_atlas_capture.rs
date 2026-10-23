//! Bounded collection of authenticated GPU capture slots for one atlas.
//! Polling never reads a second frame from a slot still held by this collector.
use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, ensure};
use viewflow_protocol::WindowId;

use crate::{
    gpu_atlas_sender::AtlasCaptureLease,
    hyprcapture_gpu_socket::{GpuFrame, GpuReceiveOutcome, HyprCaptureGpuSocketReceiver},
};

struct Slot {
    receiver: HyprCaptureGpuSocketReceiver,
    pending: Option<(Box<GpuFrame>, i64)>,
    // Existing post-recv clock sample, used only by opt-in latency diagnostics.
    received_monotonic_ns: i64,
}

/// One retained allocation per source, with no timestamp renewal while waiting
/// for the other windows. A completed batch exclusively owns every receiver
/// until the batch driver returns them for restoration.
pub struct AtlasCapturePool {
    slots: Option<BTreeMap<WindowId, Slot>>,
    windows: BTreeSet<WindowId>,
    max_windows: usize,
    max_age_ns: u64,
    in_flight: bool,
}

impl AtlasCapturePool {
    /// Register only uncollected slots. A retained GPU allocation must neither
    /// be read again nor cause a cached-ready busy loop while its peers wait.
    pub(crate) fn poll_readable(&mut self, cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        if let Some(slots) = &mut self.slots {
            for slot in slots.values_mut().filter(|slot| slot.pending.is_none()) {
                if slot.receiver.poll_readable(cx).is_ready() {
                    return std::task::Poll::Ready(());
                }
            }
        }
        std::task::Poll::Pending
    }

    /// Tighten startup collection to the live age policy without renewing any
    /// retained capture timestamp or extending an existing lease.
    pub(crate) fn tighten_age(&mut self, max_age_ns: u64) -> Result<()> {
        ensure!(
            max_age_ns > 0 && max_age_ns <= self.max_age_ns,
            "atlas age must tighten"
        );
        let slots = self
            .slots
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas pool unavailable"))?;
        for slot in slots.values_mut() {
            if let Some((frame, deadline)) = &mut slot.pending {
                let tightened = i64::try_from(frame.metadata().capture_monotonic_ns)?
                    .checked_add(i64::try_from(max_age_ns)?)
                    .ok_or_else(|| anyhow::anyhow!("atlas age overflow"))?;
                *deadline = (*deadline).min(tightened);
            }
        }
        self.max_age_ns = max_age_ns;
        Ok(())
    }

    pub(crate) fn windows(&self) -> &BTreeSet<WindowId> {
        &self.windows
    }

    pub(crate) fn max_age_ns(&self) -> u64 {
        self.max_age_ns
    }

    /// Remove only an idle collector-owned slot. No GPU reader can exist here;
    /// dropping the socket makes no HCGR assertion. The session must explicitly
    /// stop and join the producer before reclaiming its native stream identity.
    pub(crate) fn remove_at_frame_boundary(&mut self, window: WindowId) -> Result<()> {
        ensure!(!self.in_flight, "atlas capture batch is in flight");
        let slots = self
            .slots
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas capture pool unavailable"))?;
        ensure!(
            slots.remove(&window).is_some(),
            "atlas capture source missing"
        );
        self.windows.remove(&window);
        Ok(())
    }

    /// Add one already-authenticated native source between batches. The
    /// receiver becomes part of the next complete batch; no partially-held
    /// GPU allocation can be retagged into a changed membership.
    pub(crate) fn add_at_frame_boundary(
        &mut self,
        window: WindowId,
        receiver: HyprCaptureGpuSocketReceiver,
    ) -> Result<()> {
        ensure!(window.0 != 0, "zero atlas source");
        ensure!(
            self.slots.is_some() && !self.in_flight,
            "atlas capture batch is in flight"
        );
        ensure!(
            self.windows.len() < self.max_windows,
            "atlas source capacity exhausted"
        );
        let slots = self
            .slots
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas capture pool is retired"))?;
        ensure!(
            !slots.contains_key(&window) && self.windows.insert(window),
            "duplicate atlas source"
        );
        slots.insert(
            window,
            Slot {
                receiver,
                pending: None,
                received_monotonic_ns: 0,
            },
        );
        Ok(())
    }

    /// # Errors
    /// Requires 1..=4096 distinct nonzero window IDs and a positive age budget.
    pub fn new(
        receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
        max_age_ns: u64,
    ) -> Result<Self> {
        let max_windows = receivers.len();
        Self::new_with_capacity(receivers, max_age_ns, max_windows)
    }

    /// Construct a pool with a fixed negotiated capacity that can enroll
    /// additional authenticated sources at later frame boundaries.
    pub(crate) fn new_with_capacity(
        receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
        max_age_ns: u64,
        max_windows: usize,
    ) -> Result<Self> {
        ensure!(
            max_windows > 0 && receivers.len() <= max_windows && max_windows <= 4096,
            "invalid atlas source count"
        );
        ensure!(
            max_age_ns > 0 && i64::try_from(max_age_ns).is_ok(),
            "invalid atlas source age"
        );
        let mut slots = BTreeMap::new();
        for (window, receiver) in receivers {
            ensure!(
                window.0 != 0 && !slots.contains_key(&window),
                "duplicate or zero atlas source"
            );
            slots.insert(
                window,
                Slot {
                    receiver,
                    pending: None,
                    received_monotonic_ns: 0,
                },
            );
        }
        Ok(Self {
            windows: slots.keys().copied().collect(),
            slots: Some(slots),
            max_windows,
            max_age_ns,
            in_flight: false,
        })
    }

    /// Non-blocking poll. Expired unencoded allocations are explicitly released
    /// because no GPU reader has ever seen them. No source's clock is retagged.
    /// # Errors
    /// Any malformed/disconnected source retires the entire collection. A pool
    /// with an outstanding batch cannot be polled until its receivers return.
    pub fn poll_ready(&mut self) -> Result<Option<Vec<AtlasCaptureLease>>> {
        self.poll_ready_with_clock(crate::gpu_nvenc_runtime::monotonic_ns)
    }

    #[cfg(test)]
    pub(crate) fn poll_ready_at(&mut self, now: i64) -> Result<Option<Vec<AtlasCaptureLease>>> {
        self.poll_ready_with_clock(|| Ok(now))
    }

    fn poll_ready_with_clock(
        &mut self,
        mut now: impl FnMut() -> Result<i64>,
    ) -> Result<Option<Vec<AtlasCaptureLease>>> {
        let mut slots = self
            .slots
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas capture pool is retired or in flight"))?;
        for slot in slots.values_mut() {
            poll_slot(slot, &mut now, self.max_age_ns)?;
        }
        if slots.values().any(|slot| slot.pending.is_none()) {
            self.slots = Some(slots);
            return Ok(None);
        }
        self.in_flight = true;
        Ok(Some(
            slots
                .into_iter()
                .map(|(window, slot)| {
                    // All slots were checked above, without intervening mutation.
                    let (frame, deadline_monotonic_ns) = slot.pending.expect("checked ready slot");
                    AtlasCaptureLease {
                        window,
                        receiver: slot.receiver,
                        frame,
                        deadline_monotonic_ns,
                        received_monotonic_ns: slot.received_monotonic_ns,
                    }
                })
                .collect(),
        ))
    }

    /// Restore only receivers released and returned by the successful batch
    /// driver. This method does not itself assert GPU completion or send HCGR.
    /// # Errors
    /// Rejects restoration while collecting or a different source membership.
    pub fn restore(
        &mut self,
        receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
    ) -> Result<()> {
        ensure!(
            self.slots.is_none(),
            "atlas capture pool is still collecting"
        );
        ensure!(self.in_flight, "atlas capture pool is retired");
        let windows: BTreeSet<_> = receivers.iter().map(|(window, _)| *window).collect();
        ensure!(
            windows == self.windows && windows.len() == receivers.len(),
            "atlas source membership changed"
        );
        self.slots = Some(
            receivers
                .into_iter()
                .map(|(window, receiver)| {
                    (
                        window,
                        Slot {
                            receiver,
                            pending: None,
                            received_monotonic_ns: 0,
                        },
                    )
                })
                .collect(),
        );
        self.in_flight = false;
        Ok(())
    }
}

fn poll_slot(
    slot: &mut Slot,
    clock: &mut impl FnMut() -> Result<i64>,
    max_age_ns: u64,
) -> Result<()> {
    let now = clock()?;
    ensure!(now > 0, "invalid native capture clock");
    if slot
        .pending
        .as_ref()
        .is_some_and(|(_, deadline)| *deadline <= now)
    {
        let (frame, _) = slot.pending.take().expect("checked expired slot");
        slot.receiver.release_after_source_reads(&frame)?;
    }
    if slot.pending.is_some() {
        return Ok(());
    }
    match slot.receiver.recv_frame()? {
        GpuReceiveOutcome::WouldBlock => Ok(()),
        GpuReceiveOutcome::Disconnected => anyhow::bail!("atlas source disconnected"),
        GpuReceiveOutcome::Frame(frame) => {
            // A packet can arrive during recv_frame; a pre-read clock sample
            // must not label that newly captured frame as a future timestamp.
            let now = clock()?;
            let captured = i64::try_from(frame.metadata().capture_monotonic_ns)?;
            ensure!(
                captured <= now,
                "atlas source capture clock is in the future"
            );
            let deadline = captured
                .checked_add(i64::try_from(max_age_ns)?)
                .ok_or_else(|| anyhow::anyhow!("atlas source deadline overflow"))?;
            if deadline <= now {
                slot.receiver.release_after_source_reads(&frame)?;
            } else {
                slot.received_monotonic_ns = now;
                slot.pending = Some((frame, deadline));
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod empty_desktop_tests {
    use super::*;
    #[test]
    fn empty_pool_returns_transparent_batches_and_keeps_enrollment_capacity() {
        let mut pool = AtlasCapturePool::new_with_capacity(vec![], 33_333_333, 8).unwrap();
        for _ in 0..3 {
            assert!(pool.poll_ready_at(100).unwrap().unwrap().is_empty());
            pool.restore(vec![]).unwrap();
        }
        assert!(pool.windows().is_empty());
        assert!(AtlasCapturePool::new_with_capacity(vec![], 33_333_333, 0).is_err());
    }
}
