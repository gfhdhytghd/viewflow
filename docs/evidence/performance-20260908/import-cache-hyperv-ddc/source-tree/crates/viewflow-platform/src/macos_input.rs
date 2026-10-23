//! macOS desktop input. The state machine is tested without posting OS events.
//! Quartz coordinates are logical desktop points, not Retina backing pixels.

use std::collections::BTreeSet;
use viewflow_protocol::{InputEvent, InputEventKind, InputSwitchState, PointerButton};

#[cfg(target_os = "macos")]
mod native;

/// Stable tag for preventing injected events from being forwarded back.
pub const VIEWFLOW_INPUT_TAG: i64 = 0x5646_4c57;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MacOsInputError {
    PermissionDenied,
    UnsupportedHidUsage,
    UnsupportedInput,
    InvalidCoordinate,
    EventCreationFailed,
}

impl std::fmt::Display for MacOsInputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::PermissionDenied => "macOS event posting permission missing; grant Accessibility access to the receiver in System Settings",
            Self::UnsupportedHidUsage => "unsupported macOS HID usage",
            Self::UnsupportedInput => "unsupported macOS input kind",
            Self::InvalidCoordinate => "invalid macOS input coordinate or delta",
            Self::EventCreationFailed => "macOS could not create an input event",
        })
    }
}
impl std::error::Error for MacOsInputError {}

type Result<T> = std::result::Result<T, MacOsInputError>;

/// USB keyboard page -> Apple virtual key code. Layout interpretation stays on
/// the receiving Mac; GUI maps to Command, Alt maps to Option (no Ctrl swap).
#[must_use]
pub fn hid_to_keycode(page: u16, usage: u16) -> Option<u16> {
    if page != 7 {
        return None;
    }
    Some(match usage {
        0x04..=0x1d => [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7,
            16, 6,
        ][usize::from(usage - 4)],
        0x1e..=0x27 => [18, 19, 20, 21, 23, 22, 26, 28, 25, 29][usize::from(usage - 0x1e)],
        0x28 => 36,
        0x29 => 53,
        0x2a => 51,
        0x2b => 48,
        0x2c => 49,
        0x2d => 27,
        0x2e => 24,
        0x2f => 33,
        0x30 => 30,
        0x31 => 42,
        0x33 => 41,
        0x34 => 39,
        0x35 => 50,
        0x36 => 43,
        0x37 => 47,
        0x38 => 44,
        0x39 => 57,
        0x3a..=0x45 => {
            [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][usize::from(usage - 0x3a)]
        }
        0x49 => 114,
        0x4a => 115,
        0x4b => 116,
        0x4c => 117,
        0x4d => 119,
        0x4e => 121,
        0x4f => 124,
        0x50 => 123,
        0x51 => 125,
        0x52 => 126,
        0x53 => 71,
        0x54 => 75,
        0x55 => 67,
        0x56 => 78,
        0x57 => 69,
        0x58 => 76,
        0x59..=0x61 => [83, 84, 85, 86, 87, 88, 89, 91, 92][usize::from(usage - 0x59)],
        0x62 => 82,
        0x63 => 65,
        0x64 => 10,
        0x67 => 81,
        0x68..=0x6f => [105, 107, 113, 106, 64, 79, 80, 90][usize::from(usage - 0x68)],
        0x87 => 94,
        0x89 => 93,
        0x90 => 104,
        0x91 => 102,
        0xe0 => 59,
        0xe1 => 56,
        0xe2 => 58,
        0xe3 => 55,
        0xe4 => 62,
        0xe5 => 60,
        0xe6 => 61,
        0xe7 => 54,
        _ => return None,
    })
}

fn modifier(key: u16) -> u64 {
    match key {
        56 => (1 << 17) | 0x02,
        60 => (1 << 17) | 0x04,
        59 => (1 << 18) | 0x01,
        62 => (1 << 18) | 0x2000,
        58 => (1 << 19) | 0x20,
        61 => (1 << 19) | 0x40,
        55 => (1 << 20) | 0x08,
        54 => (1 << 20) | 0x10,
        _ => 0,
    }
}

fn button_number(button: PointerButton) -> u32 {
    match button {
        PointerButton::Left => 0,
        PointerButton::Right => 1,
        PointerButton::Middle => 2,
        PointerButton::Back => 3,
        PointerButton::Forward => 4,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Event {
    Motion {
        x: f64,
        y: f64,
        relative: bool,
        drag: Option<u32>,
    },
    Button {
        button: u32,
        down: bool,
    },
    Wheel {
        vertical: i32,
        horizontal: i32,
    },
    Key {
        code: u16,
        down: bool,
        repeat: bool,
    },
}

trait Sink {
    fn post(&mut self, event: Event, flags: u64) -> Result<()>;
    fn reset_pointer(&mut self) {}
}

#[derive(Debug)]
struct State<S: Sink> {
    sink: S,
    keys: BTreeSet<u16>,
    buttons: BTreeSet<u32>,
    wheel_remainder: (f64, f64),
    caps_lock: bool,
}

impl<S: Sink> State<S> {
    fn new(sink: S, caps_lock: bool) -> Self {
        Self {
            sink,
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            wheel_remainder: (0.0, 0.0),
            caps_lock,
        }
    }

    fn flags(&self) -> u64 {
        self.keys
            .iter()
            .fold(u64::from(self.caps_lock) << 16, |flags, key| {
                flags | modifier(*key)
            })
    }

    fn key(&mut self, code: u16, down: bool, repeat: bool) -> Result<()> {
        let held = self.keys.contains(&code);
        if held == down && (!down || !repeat || modifier(code) != 0 || code == 57) {
            return Ok(());
        }
        let mut keys = self.keys.clone();
        if down {
            keys.insert(code);
        } else {
            keys.remove(&code);
        }
        let caps = if code == 57 && down && !held {
            !self.caps_lock
        } else {
            self.caps_lock
        };
        let flags = keys
            .iter()
            .fold(u64::from(caps) << 16, |f, key| f | modifier(*key));
        self.sink.post(
            Event::Key {
                code,
                down,
                repeat: repeat && held,
            },
            flags,
        )?;
        self.keys = keys;
        self.caps_lock = caps;
        Ok(())
    }

    fn button(&mut self, button: u32, down: bool) -> Result<()> {
        if self.buttons.contains(&button) == down {
            return Ok(());
        }
        self.sink
            .post(Event::Button { button, down }, self.flags())?;
        if down {
            self.buttons.insert(button);
        } else {
            self.buttons.remove(&button);
        }
        Ok(())
    }

    fn motion(&mut self, x: f64, y: f64, relative: bool) -> Result<()> {
        if !x.is_finite()
            || !y.is_finite()
            || x.abs() > f64::from(i32::MAX)
            || y.abs() > f64::from(i32::MAX)
        {
            return Err(MacOsInputError::InvalidCoordinate);
        }
        self.sink.post(
            Event::Motion {
                x,
                y,
                relative,
                drag: self.buttons.first().copied(),
            },
            self.flags(),
        )
    }

    // Coordinates are range checked to native i32-point limits; sub-millipoint
    // precision beyond that range is irrelevant. Wheel truncation is deliberate
    // and the discarded fraction is retained for the next event.
    #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
    fn apply(&mut self, event: &InputEvent) -> Result<()> {
        match event.event {
            InputEventKind::Touchpad(_) => Err(MacOsInputError::UnsupportedInput),
            InputEventKind::PointerMotion(m) => self.motion(m.delta_x_dip, m.delta_y_dip, true),
            InputEventKind::DesktopPointerPosition(p) => {
                // The standalone receiver uses the native Quartz desktop as
                // its logical desktop. A shared-layout adapter must translate
                // its global origin before submitting these coordinates.
                self.motion(
                    p.x_millidip as f64 / 1000.0,
                    p.y_millidip as f64 / 1000.0,
                    false,
                )
            }
            InputEventKind::PointerButton(b) => self.button(
                button_number(b.button),
                b.state == InputSwitchState::Pressed,
            ),
            InputEventKind::KeyboardHidUsage(k) => self.key(
                hid_to_keycode(k.usage_page, k.usage_id)
                    .ok_or(MacOsInputError::UnsupportedHidUsage)?,
                k.state == InputSwitchState::Pressed,
                k.repeat,
            ),
            InputEventKind::PointerWheel(w) => {
                // Quartz pixel scrolling: 40 points per detent. Remainders
                // retain high-resolution input and are committed atomically.
                let axis = |delta: f64, remainder: f64| -> Result<(i32, f64)> {
                    let value = delta * 40.0 + remainder;
                    if !value.is_finite() || value.abs() > f64::from(i32::MAX) {
                        return Err(MacOsInputError::InvalidCoordinate);
                    }
                    Ok((value.trunc() as i32, value.fract()))
                };
                let (v, vr) = axis(w.vertical_delta_detents, self.wheel_remainder.0)?;
                // Quartz positive horizontal means left; protocol means right.
                let (h, hr) = axis(-w.horizontal_delta_detents, self.wheel_remainder.1)?;
                if v != 0 || h != 0 {
                    self.sink.post(
                        Event::Wheel {
                            vertical: v,
                            horizontal: h,
                        },
                        self.flags(),
                    )?;
                }
                self.wheel_remainder = (vr, hr);
                Ok(())
            }
            InputEventKind::ReleaseAll => self.release_all(),
        }
    }

    fn release_all(&mut self) -> Result<()> {
        let mut error = None;
        for button in self.buttons.clone() {
            if let Err(e) = self.button(button, false) {
                error = Some(e);
            }
        }
        // Release non-modifiers first, preserving chord flags until key-up.
        let mut keys: Vec<_> = self.keys.iter().copied().collect();
        keys.sort_by_key(|key| modifier(*key) != 0);
        for key in keys {
            if let Err(e) = self.key(key, false, false) {
                error = Some(e);
            }
        }
        self.wheel_remainder = (0.0, 0.0);
        self.sink.reset_pointer();
        error.map_or(Ok(()), Err)
    }
}

impl<S: Sink> Drop for State<S> {
    fn drop(&mut self) {
        for _ in 0..3 {
            if self.release_all().is_ok() {
                return;
            }
        }
        eprintln!("macOS input cleanup could not post all held-input releases");
    }
}

/// Native receiver. Posting is synchronous and ordered; no focus/capture gate.
#[cfg(target_os = "macos")]
#[derive(Debug)]
pub struct MacOsInputBackend(State<native::QuartzSink>);

#[cfg(target_os = "macos")]
impl MacOsInputBackend {
    /// Creates a receiver without posting input or opening permission prompts.
    /// Missing OS authorization is reported on apply, allowing local recovery.
    #[must_use]
    pub fn new() -> Self {
        Self(State::new(
            native::QuartzSink::default(),
            native::caps_lock(),
        ))
    }

    /// Checks current OS event-post authorization without requesting it.
    #[must_use]
    pub fn is_authorized() -> bool {
        native::is_authorized()
    }

    /// # Errors
    /// Reports unsupported HID, malformed coordinates or native posting failure.
    pub fn apply(&mut self, event: &InputEvent) -> Result<()> {
        self.0.apply(event)
    }

    /// # Errors
    /// Failed releases remain held in the ledger for subsequent retries.
    pub fn release_all(&mut self) -> Result<()> {
        self.0.release_all()
    }
}

#[cfg(target_os = "macos")]
impl Default for MacOsInputBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, rc::Rc};
    use viewflow_protocol::{Id128, KeyboardHidUsage, PointerWheelEvent};

    #[derive(Default)]
    struct Recording {
        events: Vec<(Event, u64)>,
        fail_once: bool,
    }
    impl Sink for Rc<RefCell<Recording>> {
        fn post(&mut self, event: Event, flags: u64) -> Result<()> {
            let mut s = self.borrow_mut();
            if std::mem::take(&mut s.fail_once) {
                return Err(MacOsInputError::PermissionDenied);
            }
            s.events.push((event, flags));
            Ok(())
        }
    }
    fn receiver() -> (State<Rc<RefCell<Recording>>>, Rc<RefCell<Recording>>) {
        let sink = Rc::new(RefCell::new(Recording::default()));
        (State::new(sink.clone(), false), sink)
    }
    fn input(event: InputEventKind) -> InputEvent {
        InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence: 1,
            sender_not_after_ns: 0,
            event,
        }
    }
    fn key(usage_id: u16, down: bool, repeat: bool) -> InputEvent {
        input(InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
            usage_page: 7,
            usage_id,
            state: if down {
                InputSwitchState::Pressed
            } else {
                InputSwitchState::Released
            },
            repeat,
        }))
    }

    #[test]
    fn maps_physical_keyboard_without_ctrl_command_swap() {
        for (usage, code) in [
            (4, 0),
            (0x1d, 6),
            (0x28, 36),
            (0x4c, 117),
            (0x58, 76),
            (0x6f, 90),
            (0xe0, 59),
            (0xe3, 55),
            (0xe4, 62),
            (0xe7, 54),
        ] {
            assert_eq!(hid_to_keycode(7, usage), Some(code));
        }
        assert_eq!(hid_to_keycode(0x0c, 0xcd), None);
        assert_eq!(hid_to_keycode(7, 0xffff), None);
        let codes: Vec<_> = (0..=255).filter_map(|u| hid_to_keycode(7, u)).collect();
        assert_eq!(codes.len(), codes.iter().collect::<BTreeSet<_>>().len());
    }

    #[test]
    fn duplicate_suppression_repeat_and_two_sided_modifiers() {
        let (mut s, log) = receiver();
        for e in [
            key(0xe1, true, false),
            key(0xe5, true, false),
            key(4, true, false),
            key(4, true, false),
            key(4, true, true),
            key(0xe1, false, false),
        ] {
            s.apply(&e).unwrap();
        }
        assert_eq!(log.borrow().events.len(), 5);
        assert_eq!(s.flags() & (1 << 17), 1 << 17);
        assert_eq!(s.flags() & 0x02, 0);
        assert_eq!(s.flags() & 0x04, 0x04);
        assert!(matches!(
            log.borrow().events[3].0,
            Event::Key { repeat: true, .. }
        ));
        s.release_all().unwrap();
        assert_eq!(s.flags(), 0);
        assert!(s.keys.is_empty());
    }

    #[test]
    fn drag_uses_held_button_and_absolute_points_keep_negative_origins() {
        let (mut s, log) = receiver();
        s.button(1, true).unwrap();
        s.motion(0.125, -0.25, true).unwrap();
        s.apply(&input(InputEventKind::DesktopPointerPosition(
            viewflow_protocol::DesktopPointerPosition {
                x_millidip: -125_500,
                y_millidip: 20_250,
            },
        )))
        .unwrap();
        assert_eq!(
            log.borrow().events[1].0,
            Event::Motion {
                x: 0.125,
                y: -0.25,
                relative: true,
                drag: Some(1)
            }
        );
        assert_eq!(
            log.borrow().events[2].0,
            Event::Motion {
                x: -125.5,
                y: 20.25,
                relative: false,
                drag: Some(1)
            }
        );
        s.button(1, false).unwrap();
        s.motion(1.0, 2.0, true).unwrap();
        assert!(matches!(
            log.borrow().events.last().unwrap().0,
            Event::Motion { drag: None, .. }
        ));
        assert_eq!(
            s.motion(f64::NAN, 0.0, true),
            Err(MacOsInputError::InvalidCoordinate)
        );
    }

    #[test]
    fn wheel_preserves_fraction_and_rejects_both_axes_before_post() {
        let (mut s, log) = receiver();
        let wheel = |v, h| {
            input(InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: v,
                horizontal_delta_detents: h,
            }))
        };
        for _ in 0..4 {
            s.apply(&wheel(0.01, 0.01)).unwrap();
        }
        assert_eq!(
            log.borrow().events[0].0,
            Event::Wheel {
                vertical: 1,
                horizontal: -1
            }
        );
        let remainder = s.wheel_remainder;
        assert!(s.apply(&wheel(1.0, f64::INFINITY)).is_err());
        assert_eq!(s.wheel_remainder, remainder);
        assert_eq!(log.borrow().events.len(), 1);
        log.borrow_mut().fail_once = true;
        assert!(s.apply(&wheel(1.0, 1.0)).is_err());
        assert_eq!(s.wheel_remainder, remainder);
    }

    #[test]
    fn release_failure_preserves_failed_input_and_continues_other_releases() {
        let (mut s, log) = receiver();
        s.button(0, true).unwrap();
        s.apply(&key(0xe3, true, false)).unwrap();
        s.apply(&key(4, true, false)).unwrap();
        log.borrow_mut().fail_once = true;
        assert_eq!(s.release_all(), Err(MacOsInputError::PermissionDenied));
        assert_eq!(s.buttons, BTreeSet::from([0]));
        assert!(s.keys.is_empty());
        s.release_all().unwrap();
        assert!(s.buttons.is_empty());
        let events = &log.borrow().events;
        assert!(matches!(
            events[3].0,
            Event::Key {
                code: 0,
                down: false,
                ..
            }
        ));
        assert_ne!(events[3].1 & (1 << 20), 0);
        assert!(matches!(
            events[4].0,
            Event::Key {
                code: 55,
                down: false,
                ..
            }
        ));
        assert_eq!(events[4].1 & (1 << 20), 0);
    }

    #[test]
    fn failed_press_does_not_commit_and_drop_retries_transient_release() {
        let (mut s, log) = receiver();
        log.borrow_mut().fail_once = true;
        assert!(s.apply(&key(4, true, false)).is_err());
        assert!(s.keys.is_empty());
        s.apply(&key(4, true, false)).unwrap();
        log.borrow_mut().fail_once = true;
        drop(s);
        assert_eq!(log.borrow().events.len(), 2);
        assert!(matches!(
            log.borrow().events[1].0,
            Event::Key { down: false, .. }
        ));
    }

    #[test]
    fn caps_lock_toggles_only_on_new_down_and_cleanup_does_not_toggle() {
        let (mut s, _) = receiver();
        s.apply(&key(0x39, true, false)).unwrap();
        s.apply(&key(0x39, true, true)).unwrap();
        assert!(s.caps_lock);
        s.release_all().unwrap();
        assert!(s.caps_lock);
        s.apply(&key(0x39, true, false)).unwrap();
        assert!(!s.caps_lock);
    }
}
