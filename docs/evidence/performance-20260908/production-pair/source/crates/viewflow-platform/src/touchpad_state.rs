//! Contact lifecycle shared by the Windows injector and input-free tests.
use viewflow_protocol::{TouchpadContact, TouchpadFrame};

#[derive(Debug, Default)]
pub(crate) struct TouchpadState {
    pub(crate) previous: TouchpadFrame,
}

impl TouchpadState {
    pub(crate) fn apply<E>(
        &mut self,
        frame: TouchpadFrame,
        mut inject: impl FnMut(&[(TouchpadContact, bool)]) -> Result<(), E>,
    ) -> Result<(), E> {
        let current = &frame.contacts[..usize::from(frame.count)];
        let old = &self.previous.contacts[..usize::from(self.previous.count)];
        if old.iter().any(|c| !current.iter().any(|n| n.id == c.id)) {
            // Release removed contacts before introducing replacements. This
            // remains at most five contacts even when all tracking IDs change.
            let lifted: Vec<_> = old.iter().map(|c| {
                current.iter().find(|n| n.id == c.id).map_or((*c, false), |n| (*n, true))
            }).collect();
            inject(&lifted)?;
            let mut remaining = TouchpadFrame { width: frame.width, height: frame.height, ..TouchpadFrame::default() };
            for c in old.iter().filter_map(|c| current.iter().find(|n| n.id == c.id)) {
                remaining.contacts[usize::from(remaining.count)] = *c;
                remaining.count += 1;
            }
            // Commit each successful OS submission, even if the next fails.
            self.previous = remaining;
        }
        if !current.is_empty() {
            let pressed: Vec<_> = current.iter().map(|c| (*c, true)).collect();
            inject(&pressed)?;
        }
        self.previous = frame;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(ids: &[u32]) -> TouchpadFrame {
        let mut f = TouchpadFrame { width: 10000, height: 6000, count: ids.len() as u8, ..TouchpadFrame::default() };
        for (c, id) in f.contacts.iter_mut().zip(ids) { *c = TouchpadContact { id: *id, x: 1000, y: 2000 }; }
        f
    }
    #[test]
    fn five_finger_replacement_lifts_old_ids_before_new_ones() {
        let mut state = TouchpadState::default();
        state.apply(frame(&[1,2,3,4,5]), |_| Ok::<_, ()>(())).unwrap();
        let mut calls = vec![];
        state.apply(frame(&[6,7,8,9,10]), |events| { calls.push(events.to_vec()); Ok::<_, ()>(()) }).unwrap();
        assert_eq!(calls.len(), 2);
        assert!(calls[0].iter().all(|(c, down)| c.id <= 5 && !down));
        assert!(calls[1].iter().all(|(c, down)| c.id >= 6 && *down));
        assert!(calls.iter().all(|c| c.len() == 5));
    }
    #[test]
    fn failed_lifts_remain_tracked_and_successful_lifts_are_not_replayed() {
        let mut state = TouchpadState { previous: frame(&[1,2,3]) };
        assert!(state.apply(frame(&[2,4]), |_| Err(())).is_err());
        assert_eq!(state.previous, frame(&[1,2,3]));
        let mut count = 0;
        assert!(state.apply(frame(&[2,4]), |_| { count += 1; if count == 1 { Ok(()) } else { Err(()) } }).is_err());
        assert_eq!(state.previous, frame(&[2]));
        let mut released = vec![];
        state.apply(frame(&[]), |events| { released.extend_from_slice(events); Ok::<_, ()>(()) }).unwrap();
        assert_eq!(released, vec![(frame(&[2]).contacts[0], false)]);
        assert_eq!(state.previous.count, 0);
    }
}
