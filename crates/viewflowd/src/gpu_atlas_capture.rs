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
    partitioned_in_flight: BTreeSet<WindowId>,
    // Sources whose socket disconnected or delivered an unusable packet. They
    // leave collection at once; the owner retires them through normal removal.
    lost: BTreeSet<WindowId>,
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

    /// Sources dropped from collection after a per-window failure, awaiting
    /// `remove_at_frame_boundary`/`withdraw_activity` to stop their producer.
    pub(crate) fn lost_windows(&self) -> &BTreeSet<WindowId> {
        &self.lost
    }

    pub(crate) fn poll_readable_subset(&mut self, cx: &mut std::task::Context<'_>, selected: &BTreeSet<WindowId>) -> std::task::Poll<()> {
        if let Some(slots) = &mut self.slots {
            for (window, slot) in slots.iter_mut().filter(|(window, slot)| selected.contains(window) && slot.pending.is_none()) {
                let _ = window;
                if slot.receiver.poll_readable(cx).is_ready() { return std::task::Poll::Ready(()); }
            }
        }
        std::task::Poll::Pending
    }

    pub(crate) fn source_reads_pending(&self, window: WindowId) -> bool {
        self.in_flight || self.partitioned_in_flight.contains(&window)
    }

    /// Withdraw membership immediately, but keep an in-flight native allocation
    /// owned until its worker proves source reads complete.
    pub(crate) fn withdraw_activity(&mut self, window: WindowId) -> Result<()> {
        ensure!(!self.in_flight, "legacy atlas batch active");
        ensure!(self.windows.remove(&window) || self.lost.remove(&window), "atlas source missing");
        if let Some(slots) = &mut self.slots { slots.remove(&window); }
        Ok(())
    }

    pub(crate) fn max_age_ns(&self) -> u64 {
        self.max_age_ns
    }

    /// Remove only an idle collector-owned slot. No GPU reader can exist here;
    /// dropping the socket makes no HCGR assertion. The session must explicitly
    /// stop and join the producer before reclaiming its native stream identity.
    pub(crate) fn remove_at_frame_boundary(&mut self, window: WindowId) -> Result<()> {
        ensure!(!self.in_flight && !self.partitioned_in_flight.contains(&window), "atlas capture batch is in flight");
        if self.lost.remove(&window) {
            return Ok(());
        }
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
        // A lost source keeps its producer until removal stops it, so the same
        // window cannot be re-enrolled underneath that cleanup.
        ensure!(
            !self.lost.contains(&window) && !slots.contains_key(&window) && self.windows.insert(window),
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
            partitioned_in_flight: BTreeSet::new(),
            lost: BTreeSet::new(),
        })
    }

    /// Non-blocking poll. Expired unencoded allocations are explicitly released
    /// because no GPU reader has ever seen them. No source's clock is retagged.
    /// # Errors
    /// A malformed or disconnected source is dropped alone and listed in
    /// `lost_windows`; the others keep streaming. Clock failures remain fatal,
    /// and a pool with an outstanding batch cannot be polled until its
    /// receivers return.
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
        ensure!(self.partitioned_in_flight.is_empty(), "activity capture lanes are in flight");
        let mut slots = self
            .slots
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas capture pool is retired or in flight"))?;
        let mut failed = Vec::new();
        for (window, slot) in &mut slots {
            if let Err(error) = poll_slot(slot, &mut now, self.max_age_ns)? {
                failed.push((*window, error));
            }
        }
        for (window, error) in failed {
            lose(&mut self.windows, &mut self.lost, &mut slots, window, &error);
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

    /// Collect only the chosen media lane. Other windows keep their independent
    /// capture sockets and do not delay this batch. A migration waits only for
    /// the affected window's existing GPU lease to return.
    pub(crate) fn poll_ready_subset(
        &mut self, selected: &BTreeSet<WindowId>,
    ) -> Result<Option<Vec<AtlasCaptureLease>>> {
        self.poll_subset_with_clock(selected, crate::gpu_nvenc_runtime::monotonic_ns)
    }

    /// Admit every currently ready member of a lane without waiting for a
    /// static, migrating, or temporarily slow peer. The activity manifest keeps
    /// global proxy membership, so omitted tiles retain their last picture.
    pub(crate) fn poll_available_subset(
        &mut self, selected: &BTreeSet<WindowId>,
    ) -> Result<Vec<AtlasCaptureLease>> {
        self.poll_available_with_clock(selected, crate::gpu_nvenc_runtime::monotonic_ns)
    }

    #[cfg(test)]
    pub(crate) fn poll_available_at(&mut self, selected: &BTreeSet<WindowId>, now: i64) -> Result<Vec<AtlasCaptureLease>> {
        self.poll_available_with_clock(selected, || Ok(now))
    }

    fn poll_available_with_clock(
        &mut self, selected: &BTreeSet<WindowId>, mut now: impl FnMut() -> Result<i64>,
    ) -> Result<Vec<AtlasCaptureLease>> {
        ensure!(!self.in_flight && selected.is_subset(&self.windows), "activity capture membership");
        let slots = self.slots.as_mut().ok_or_else(|| anyhow::anyhow!("atlas pool unavailable"))?;
        let mut ready = Vec::new();
        let mut failed = Vec::new();
        for window in selected.difference(&self.partitioned_in_flight) {
            let slot = slots.get_mut(window).ok_or_else(|| anyhow::anyhow!("activity slot unavailable"))?;
            match poll_slot(slot, &mut now, self.max_age_ns)? {
                Ok(()) if slot.pending.is_some() => ready.push(*window),
                Ok(()) => {}
                Err(error) => failed.push((*window, error)),
            }
        }
        for (window, error) in failed {
            lose(&mut self.windows, &mut self.lost, slots, window, &error);
        }
        let mut leases = Vec::with_capacity(ready.len());
        for window in ready {
            let slot = slots.remove(&window).expect("ready slot exists");
            let (frame, deadline_monotonic_ns) = slot.pending.expect("ready frame exists");
            leases.push(AtlasCaptureLease { window, receiver: slot.receiver, frame,
                deadline_monotonic_ns, received_monotonic_ns: slot.received_monotonic_ns });
            self.partitioned_in_flight.insert(window);
        }
        Ok(leases)
    }

    #[cfg(test)]
    pub(crate) fn poll_subset_at(&mut self, selected: &BTreeSet<WindowId>, now: i64) -> Result<Option<Vec<AtlasCaptureLease>>> {
        self.poll_subset_with_clock(selected, || Ok(now))
    }

    fn poll_subset_with_clock(
        &mut self, selected: &BTreeSet<WindowId>, mut now: impl FnMut() -> Result<i64>,
    ) -> Result<Option<Vec<AtlasCaptureLease>>> {
        ensure!(!self.in_flight, "legacy capture batch is in flight");
        ensure!(selected.is_subset(&self.windows), "activity capture membership");
        if !selected.is_disjoint(&self.partitioned_in_flight) { return Ok(None); }
        let slots=self.slots.as_mut().ok_or_else(|| anyhow::anyhow!("atlas pool unavailable"))?;
        let mut failed = Vec::new();
        for window in selected {
            if let Err(error) = poll_slot(slots.get_mut(window).ok_or_else(|| anyhow::anyhow!("activity slot unavailable"))?, &mut now, self.max_age_ns)? {
                failed.push((*window, error));
            }
        }
        if !failed.is_empty() {
            // The lane lost a member; the caller reselects from `windows`.
            for (window, error) in failed {
                lose(&mut self.windows, &mut self.lost, slots, window, &error);
            }
            return Ok(None);
        }
        if selected.iter().any(|id| slots[id].pending.is_none()) { return Ok(None); }
        let mut leases=Vec::with_capacity(selected.len());
        for window in selected {
            let slot=slots.remove(window).expect("checked selected slot");
            let (frame,deadline_monotonic_ns)=slot.pending.expect("checked ready slot");
            leases.push(AtlasCaptureLease {window:*window,receiver:slot.receiver,frame,
                deadline_monotonic_ns,received_monotonic_ns:slot.received_monotonic_ns});
        }
        self.partitioned_in_flight.extend(selected);
        Ok(Some(leases))
    }

    pub(crate) fn restore_subset(
        &mut self, receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
    ) -> Result<()> {
        let returned: BTreeSet<_>=receivers.iter().map(|(id,_)|*id).collect();
        ensure!(returned.len()==receivers.len() && returned.is_subset(&self.partitioned_in_flight), "activity returned lease membership");
        let slots=self.slots.as_mut().ok_or_else(|| anyhow::anyhow!("atlas pool unavailable"))?;
        ensure!(returned.iter().all(|id| !slots.contains_key(id)), "activity slot returned twice");
        for (window,receiver) in receivers {
            self.partitioned_in_flight.remove(&window);
            if self.windows.contains(&window) {
                slots.insert(window,Slot {receiver,pending:None,received_monotonic_ns:0});
            }
        }
        Ok(())
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

fn lose(
    windows: &mut BTreeSet<WindowId>,
    lost: &mut BTreeSet<WindowId>,
    slots: &mut BTreeMap<WindowId, Slot>,
    window: WindowId,
    error: &anyhow::Error,
) {
    eprintln!("atlas-source-lost window={window:?} reason={error:#}");
    // Dropping the slot drops any pending allocation and its FDs. No GPU
    // reader has seen it, exactly as for an expired unencoded slot.
    slots.remove(&window);
    windows.remove(&window);
    lost.insert(window);
}

/// The outer error is a shared clock failure; the inner one belongs to this
/// source alone and must not retire its peers.
fn poll_slot(
    slot: &mut Slot,
    clock: &mut impl FnMut() -> Result<i64>,
    max_age_ns: u64,
) -> Result<Result<()>> {
    let now = clock()?;
    ensure!(now > 0, "invalid native capture clock");
    Ok(poll_slot_at(slot, now, clock, max_age_ns))
}

fn poll_slot_at(
    slot: &mut Slot,
    now: i64,
    clock: &mut impl FnMut() -> Result<i64>,
    max_age_ns: u64,
) -> Result<()> {
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

#[cfg(test)]
mod lost_source_tests {
    use super::*;
    use std::os::fd::{FromRawFd, OwnedFd};
    use viewflow_protocol::Id128;

    #[allow(unsafe_code)]
    fn pair() -> (OwnedFd, OwnedFd) {
        let mut raw = [-1; 2];
        // SAFETY: output has exactly two descriptor slots.
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, raw.as_mut_ptr()) },
            0
        );
        // SAFETY: each successful socketpair result has one owner.
        unsafe { (OwnedFd::from_raw_fd(raw[0]), OwnedFd::from_raw_fd(raw[1])) }
    }

    #[allow(unsafe_code)]
    fn receiver(socket: OwnedFd) -> HyprCaptureGpuSocketReceiver {
        // SAFETY: test identity query has no preconditions.
        HyprCaptureGpuSocketReceiver::new(socket, unsafe { libc::geteuid() }, std::process::id())
            .unwrap()
    }

    fn pool() -> (AtlasCapturePool, OwnedFd) {
        let (first, first_peer) = pair();
        let (second, second_peer) = pair();
        drop(first_peer);
        let pool = AtlasCapturePool::new(
            vec![(Id128(1), receiver(first)), (Id128(2), receiver(second))],
            1000,
        )
        .unwrap();
        (pool, second_peer)
    }

    #[test]
    fn one_disconnected_source_leaves_batch_peers_streaming() {
        let (mut pool, _live) = pool();
        assert!(pool.poll_ready_at(10).unwrap().is_none());
        assert_eq!(pool.windows(), &BTreeSet::from([Id128(2)]));
        assert_eq!(pool.lost_windows(), &BTreeSet::from([Id128(1)]));
        assert!(pool.poll_ready_at(11).unwrap().is_none());
        // A lost window cannot be re-enrolled until normal removal retires it.
        let (again, _peer) = pair();
        assert!(pool.add_at_frame_boundary(Id128(1), receiver(again)).is_err());
        pool.remove_at_frame_boundary(Id128(1)).unwrap();
        assert!(pool.lost_windows().is_empty());
        assert_eq!(pool.windows(), &BTreeSet::from([Id128(2)]));
    }

    #[test]
    fn one_disconnected_source_leaves_activity_lanes_streaming() {
        let (mut pool, _live) = pool();
        let all = BTreeSet::from([Id128(1), Id128(2)]);
        assert!(pool.poll_available_at(&all, 10).unwrap().is_empty());
        assert_eq!(pool.lost_windows(), &BTreeSet::from([Id128(1)]));
        let remaining = BTreeSet::from([Id128(2)]);
        assert!(pool.poll_available_at(&remaining, 11).unwrap().is_empty());
        assert!(pool.poll_subset_at(&remaining, 12).unwrap().is_none());
        pool.withdraw_activity(Id128(1)).unwrap();
        assert!(pool.lost_windows().is_empty());
        assert!(pool.withdraw_activity(Id128(1)).is_err());
    }
}
