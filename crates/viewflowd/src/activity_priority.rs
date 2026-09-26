//! Per-connection scheduling hints; these never authorize or synthesize input.
use std::collections::{BTreeMap, BTreeSet};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActivityPriorityMode {
    #[default]
    Auto,
    Off,
}

#[derive(Default)]
struct Window {
    owner: u128,
    held: BTreeSet<(u32, u64)>,
    interaction: u64,
    until_us: u64,
}

#[derive(Default)]
pub struct ActivityPriority {
    windows: BTreeMap<u128, Window>,
    focus_history: Vec<u128>,
    sequence: u64,
}

/// Shared only by the input and media owners of one authenticated connection.
/// A scheduling observer cannot fail or revoke the underlying input operation.
#[derive(Clone)]
pub struct ActivityHandle {
    state: std::sync::Arc<std::sync::Mutex<ActivityPriority>>,
    origin: std::time::Instant,
}
impl Default for ActivityHandle {
    fn default() -> Self {
        Self { state: Default::default(), origin: std::time::Instant::now() }
    }
}
impl ActivityHandle {
    pub fn observe(&self, apply: impl FnOnce(&mut ActivityPriority, u64)) {
        if let Ok(mut state) = self.state.lock() {
            apply(&mut state, self.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64);
        }
    }
    pub(crate) fn schedule(&self, visible: &BTreeSet<viewflow_protocol::WindowId>) -> (Option<viewflow_protocol::WindowId>, Option<viewflow_protocol::WindowId>, BTreeSet<viewflow_protocol::WindowId>) {
        let Ok(state) = self.state.lock() else { return (None, None, BTreeSet::new()); };
        let now = self.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
        let preferred = state.preferred(now).map(viewflow_protocol::Id128).filter(|id| visible.contains(id));
        let focus = state.last_focus().map(viewflow_protocol::Id128).filter(|id| visible.contains(id));
        let family = visible.iter().copied().filter(|id| preferred.is_some_and(|preferred| state.root(id.0) == Some(preferred.0))).collect();
        (preferred, focus, family)
    }
    pub fn snapshot(&self) -> Option<(Option<u128>, Option<u128>)> {
        let state = self.state.lock().ok()?;
        let now = self.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
        Some((state.preferred(now), state.last_focus()))
    }
}

impl ActivityPriority {
    pub const GRACE_US: u64 = 500_000;
    pub fn membership(&mut self, visible: &[(u128, u128)]) {
        let present: BTreeSet<_> = visible.iter().filter(|(id, _)| *id != 0).map(|(id, _)| *id).collect();
        for &(id, owner) in visible.iter().filter(|(id, _)| *id != 0) {
            self.windows.entry(id).or_default().owner = owner;
        }
        self.windows.retain(|id, _| present.contains(id));
        self.focus_history.retain(|id| present.contains(id));
    }
    fn root(&self, mut id: u128) -> Option<u128> {
        let mut visited = BTreeSet::new();
        while visited.insert(id) {
            let window = self.windows.get(&id)?;
            if window.owner == 0 || !self.windows.contains_key(&window.owner) { return Some(id); }
            id = window.owner;
        }
        None
    }
    pub fn focus(&mut self, id: u128) {
        if let Some(id) = self.root(id) {
            self.focus_history.retain(|old| *old != id);
            self.focus_history.push(id);
        }
    }
    pub fn last_focus(&self) -> Option<u128> { self.focus_history.last().copied() }
    pub fn impulse(&mut self, id: u128, now_us: u64) {
        if let Some(id) = self.root(id) {
            self.sequence += 1;
            let window = self.windows.get_mut(&id).unwrap();
            window.interaction = self.sequence;
            window.until_us = now_us.saturating_add(Self::GRACE_US);
        }
    }
    pub fn hold(&mut self, id: u128, kind: u32, token: u64, down: bool, now_us: u64) {
        if let Some(id) = self.root(id) {
            let held = &mut self.windows.get_mut(&id).unwrap().held;
            if down { held.insert((kind, token)); } else { held.remove(&(kind, token)); }
            self.impulse(id, now_us);
        }
    }
    pub fn release(&mut self, id: Option<u128>, now_us: u64) {
        // An unknown window must not release another window's scheduling hold.
        let root = match id { Some(id) => match self.root(id) { Some(id) => Some(id), None => return }, None => None };
        for (&candidate, window) in &mut self.windows {
            if root.is_none_or(|id| candidate == id) && !window.held.is_empty() {
                window.held.clear(); window.until_us = now_us.saturating_add(Self::GRACE_US);
            }
        }
    }
    pub fn interacting(&self, now_us: u64) -> Option<u128> {
        self.windows.iter().filter(|(_, w)| w.interaction > 0 && (!w.held.is_empty() || now_us < w.until_us))
            .max_by_key(|(_, w)| w.interaction).map(|(&id, _)| id)
    }
    pub fn preferred(&self, now_us: u64) -> Option<u128> { self.interacting(now_us).or_else(|| self.last_focus()) }
    pub fn rank(&self, id: u128, now_us: u64) -> u8 {
        let Some(id) = self.root(id) else { return 2; };
        let active = self.interacting(now_us);
        if active == Some(id) { 0 } else if self.last_focus() == Some(id) { u8::from(active.is_some()) } else { 2 }
    }
    pub fn observe_native(&mut self, event: crate::native_window_wire::Input, now_us: u64) {
        let id = u128::from(event.id);
        match event.kind {
            5 => self.focus(id),
            2 | 4 => self.hold(id, if event.kind == 2 { 1 } else { 2 }, event.a as u32 as u64, event.b != 0, now_us),
            3 if event.b != 0 => self.impulse(id, now_us),
            8 => self.release((id != 0).then_some(id), now_us),
            _ => (), // Pointer motion/hover and partial touchpad bytes do not count.
        }
    }
}

#[derive(Default)]
pub struct Congestion {
    sample_start: Option<u64>,
    normal_since: Option<u64>,
    bad_samples: u32,
    level: usize,
    bad: bool,
}
impl Congestion {
    pub fn observe(&mut self, now_us: u64, queue_us: u64, saturated: bool, fps: u32) -> bool {
        let start = *self.sample_start.get_or_insert(now_us);
        self.bad |= saturated || queue_us > 2_000_000 / u64::from(fps.max(1));
        if now_us.saturating_sub(start) < 250_000 { return false; }
        let old = self.level;
        if self.bad {
            self.normal_since = None;
            self.bad_samples += 1;
            if self.bad_samples >= 3 { self.level = (self.level + 1).min(3); self.bad_samples = 0; }
        } else {
            self.bad_samples = 0;
            let normal = *self.normal_since.get_or_insert(now_us);
            if self.level > 0 && now_us.saturating_sub(normal) >= 2_000_000 {
                self.level -= 1; self.normal_since = Some(now_us);
            }
        }
        self.sample_start = Some(now_us); self.bad = false; old != self.level
    }
    pub fn background_fps(&self, target: u32) -> u32 {
        if self.level == 0 { target } else { target.min([0, 30, 15, 5][self.level]) }
    }
    pub fn level(&self) -> usize { self.level }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interaction_then_last_focus_without_hover_activation() {
        let mut p = ActivityPriority::default(); p.membership(&[(1,0),(2,0),(3,1)]); p.focus(1);
        p.observe_native(crate::native_window_wire::Input{id:2,sequence:1,kind:1,a:10,b:10,c:0,d:0},1);
        assert_eq!(p.preferred(1),Some(1));
        p.impulse(2,10); assert_eq!(p.last_focus(),Some(1)); assert_eq!(p.rank(3,10),1);
        assert_eq!(p.preferred(500_010),Some(1));
        p.hold(2,1,272,true,600_000); assert_eq!(p.preferred(5_000_000),Some(2));
        p.release(Some(999),5_000_000); assert_eq!(p.preferred(6_000_000),Some(2));
        p.hold(2,1,272,false,6_000_000); assert_eq!(p.preferred(6_500_000),Some(1));
        p.impulse(3,7_000_000); assert_eq!(p.interacting(7_000_000),Some(1));
        p.focus(2); p.membership(&[(1,0),(3,1)]); assert_eq!(p.last_focus(),Some(1));
    }
    #[test]
    fn only_sustained_congestion_throttles_and_recovery_is_slow() {
        let mut c = Congestion::default();
        for i in 0..4 { c.observe(1+i*250_000,40_000,false,60); }
        assert_eq!(c.background_fps(60),30);
        for i in 4..7 { c.observe(1+i*250_000,0,true,60); }
        assert_eq!(c.background_fps(60),15);
        for i in 7..17 { c.observe(1+i*250_000,0,false,60); }
        assert_eq!(c.background_fps(60),30);
    }
}
