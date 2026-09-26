//! Connection-local lane admission. This chooses captures, never input or focus.
use crate::activity_priority::{ActivityHandle, Congestion};
use anyhow::{Result, ensure};
use std::collections::BTreeSet;
use viewflow_protocol::{AtlasActivity, WindowId};

pub(crate) struct AtlasActivityScheduler {
    activity: ActivityHandle,
    members: BTreeSet<WindowId>,
    preferred: Option<WindowId>,
    focus: Option<WindowId>,
    family: BTreeSet<WindowId>,
    epoch: u64,
    dual: bool,
    target_fps: u32,
    congestion: Congestion,
    last_admitted: [Option<u64>; 2],
    single_turn: bool,
}

impl AtlasActivityScheduler {
    pub(crate) fn new(activity: ActivityHandle, dual: bool, target_fps: u32) -> Self {
        Self {
            activity,
            members: BTreeSet::new(),
            preferred: None,
            focus: None,
            family: BTreeSet::new(),
            epoch: 0,
            dual,
            target_fps: target_fps.max(1),
            congestion: Congestion::default(),
            last_admitted: [None; 2],
            single_turn: false,
        }
    }

    pub(crate) fn local_activation(&self, window: WindowId) {
        self.activity.observe(|state, _| state.focus(window.0));
    }

    pub(crate) fn refresh(&mut self, members: &BTreeSet<WindowId>) -> Result<()> {
        let (preferred, focus, family) = self.activity.schedule(members);
        if self.epoch == 0
            || self.members != *members
            || self.preferred != preferred
            || self.focus != focus
            || self.family != family
        {
            self.epoch = self
                .epoch
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("atlas activity epoch exhausted"))?;
            self.members.clone_from(members);
            self.preferred = preferred;
            self.focus = focus;
            self.family = family;
            // A priority change immediately admits the newly preferred family.
            self.last_admitted[1] = None;
        }
        Ok(())
    }

    pub(crate) fn fallback(&mut self) -> Result<()> {
        if self.dual {
            self.dual = false;
            self.epoch = self
                .epoch
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("atlas activity epoch exhausted"))?;
            self.last_admitted = [None, None];
        }
        Ok(())
    }

    pub(crate) fn observe_queue(&mut self, now_us: u64, age_us: u64, saturated: bool) -> bool {
        self.congestion
            .observe(now_us, age_us, saturated, self.target_fps)
    }

    pub(crate) fn background_fps(&self) -> u32 {
        self.congestion.background_fps(self.target_fps)
    }

    /// Background gets the first opportunity whenever 200 ms have elapsed.
    /// Each lane has its own bounded worker; a busy background cannot block 1.
    pub(crate) fn order(&self, now_us: u64) -> [usize; 2] {
        if self.last_admitted[0].is_none_or(|last| now_us.saturating_sub(last) >= 200_000) {
            [0, 1]
        } else {
            [1, 0]
        }
    }

    pub(crate) fn select(&self, lane: usize, now_us: u64) -> BTreeSet<WindowId> {
        if lane > 1 || (!self.dual && lane == 1) {
            return BTreeSet::new();
        }
        let period = if lane == 0 {
            1_000_000 / u64::from(self.background_fps())
        } else {
            1_000_000 / u64::from(self.target_fps)
        };
        if self.dual
            && self.last_admitted[lane].is_some_and(|last| now_us.saturating_sub(last) < period)
        {
            return BTreeSet::new();
        }
        if !self.dual {
            // Single encoder: alternate a priority opportunity and a background
            // opportunity when due; priority continues at target otherwise.
            let background_due = self.last_admitted[0]
                .is_none_or(|last| now_us.saturating_sub(last) >= period.min(200_000));
            let priority_due = self.last_admitted[1].is_none_or(|last| {
                now_us.saturating_sub(last) >= 1_000_000 / u64::from(self.target_fps)
            });
            if background_due && (self.single_turn || self.family.is_empty() || !priority_due) {
                return self.members.difference(&self.family).copied().collect();
            }
            return if priority_due {
                self.family.clone()
            } else {
                BTreeSet::new()
            };
        }
        if lane == 1 {
            self.family.clone()
        } else {
            self.members.difference(&self.family).copied().collect()
        }
    }

    pub(crate) fn admitted(&mut self, lane: usize, selected: &BTreeSet<WindowId>, now_us: u64) {
        if self.dual {
            self.last_admitted[lane] = Some(now_us);
        } else {
            if !selected.is_subset(&self.family) || self.family.is_empty() {
                self.last_admitted[0] = Some(now_us);
            } else {
                self.last_admitted[1] = Some(now_us);
            }
            self.single_turn = !self.single_turn;
        }
    }

    pub(crate) fn frame(&self, lane: usize) -> Result<AtlasActivity> {
        ensure!(
            self.epoch > 0 && lane < 2 && (self.dual || lane == 0),
            "activity scheduling state unavailable"
        );
        Ok(AtlasActivity {
            lane: lane as u32,
            epoch: self.epoch,
            // The fallback uses lane 0 for every window. A priority hint here
            // would cause the receiver to reject its preferred window's tiles.
            preferred: self.dual.then_some(self.preferred).flatten(),
            focus: self.focus,
            members: self.members.iter().copied().collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;
    fn setup(dual: bool) -> (ActivityHandle, AtlasActivityScheduler) {
        let handle = ActivityHandle::default();
        handle.observe(|state, _| {
            state.membership(&[(1, 0), (2, 0), (3, 1)]);
            state.focus(1);
        });
        let mut scheduler = AtlasActivityScheduler::new(handle.clone(), dual, 60);
        scheduler
            .refresh(&[Id128(1), Id128(2), Id128(3)].into())
            .unwrap();
        (handle, scheduler)
    }
    #[test]
    fn scroll_changes_lane_immediately_and_popup_follows_owner() {
        let (handle, mut s) = setup(true);
        assert_eq!(s.select(1, 0), [Id128(1), Id128(3)].into());
        let old = s.frame(1).unwrap();
        s.admitted(1, &s.select(1, 0), 0);
        handle.observe(|state, now| state.impulse(2, now));
        s.refresh(&s.members.clone()).unwrap();
        assert_eq!(s.select(1, 1), [Id128(2)].into());
        assert_eq!(s.select(0, 1), [Id128(1), Id128(3)].into());
        let new = s.frame(1).unwrap();
        assert!(new.epoch > old.epoch);
        assert_eq!(new.focus, Some(Id128(1)));
    }
    #[test]
    fn background_has_opportunity_and_fallback_keeps_all_tiles_eligible() {
        let (_, mut dual) = setup(true);
        dual.admitted(0, &dual.select(0, 0), 0);
        assert_eq!(dual.order(200_000), [0, 1]);
        let (_, mut single) = setup(false);
        let selected = single.select(0, 0);
        assert_eq!(selected, [Id128(1), Id128(3)].into());
        single.admitted(0, &selected, 0);
        assert_eq!(single.select(0, 1), [Id128(2)].into());
        assert!(single.select(1, 1).is_empty());
        let frame = single.frame(0).unwrap();
        assert_eq!(frame.preferred, None);
        assert_eq!(frame.members.len(), 3);
        frame.validate().unwrap();
    }
    #[test]
    fn runtime_resource_fallback_advances_epoch_and_keeps_membership() {
        let (_, mut scheduler) = setup(true);
        let old = scheduler.frame(1).unwrap();
        scheduler.fallback().unwrap();
        let new = scheduler.frame(0).unwrap();
        assert!(new.epoch > old.epoch);
        assert_eq!(new.members, old.members);
        assert_eq!(new.preferred, None);
        assert_eq!(new.focus, old.focus);
        assert!(scheduler.select(1, 0).is_empty());
    }
    #[test]
    fn two_connections_do_not_share_activity_or_backpressure() {
        let (one, mut a) = setup(true);
        let (_, mut b) = setup(true);
        one.observe(|state, now| state.impulse(2, now));
        a.refresh(&a.members.clone()).unwrap();
        for time in [0, 250_000, 500_000, 750_000] {
            a.observe_queue(time, 100_000, true);
            b.observe_queue(time, 0, false);
        }
        assert_eq!(a.background_fps(), 30);
        assert_eq!(b.background_fps(), 60);
        assert_eq!(a.frame(1).unwrap().preferred, Some(Id128(2)));
        assert_eq!(b.frame(1).unwrap().preferred, Some(Id128(1)));
    }
}
