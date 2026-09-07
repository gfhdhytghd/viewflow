//! Small owned CoreGraphics FFI boundary. No native pointer crosses a call or
//! thread boundary; only the Rust state machine survives between events.
#![allow(unsafe_code)]

use super::{Event, MacOsInputError, Result, Sink, VIEWFLOW_INPUT_TAG, modifier};
use std::{
    ffi::c_void,
    ptr::NonNull,
    time::{Duration, Instant},
};

type Ref = *mut c_void;
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct Point {
    x: f64,
    y: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct Size {
    width: f64,
    height: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct Rect {
    origin: Point,
    size: Size,
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGPreflightPostEventAccess() -> bool;
    fn CGEventSourceFlagsState(state: i32) -> u64;
    fn CGEventSourceCreate(state: i32) -> Ref;
    fn CGEventSourceSetLocalEventsSuppressionInterval(source: Ref, seconds: f64);
    fn CGEventSourceSetLocalEventsFilterDuringSuppressionState(
        source: Ref,
        filter: u32,
        state: u32,
    );
    fn CGEventCreate(source: Ref) -> Ref;
    fn CGEventGetLocation(event: Ref) -> Point;
    fn CGEventSetLocation(event: Ref, position: Point);
    fn CGEventCreateMouseEvent(source: Ref, kind: u32, position: Point, button: u32) -> Ref;
    fn CGEventCreateKeyboardEvent(source: Ref, key: u16, down: bool) -> Ref;
    fn CGEventCreateScrollWheelEvent2(
        source: Ref,
        units: u32,
        count: u32,
        v: i32,
        h: i32,
        z: i32,
    ) -> Ref;
    fn CGEventSetFlags(event: Ref, flags: u64);
    fn CGEventSetType(event: Ref, kind: u32);
    fn CGEventSetIntegerValueField(event: Ref, field: u32, value: i64);
    fn CGEventPost(tap: u32, event: Ref);
    fn CGGetActiveDisplayList(max: u32, displays: *mut u32, count: *mut u32) -> i32;
    fn CGDisplayBounds(display: u32) -> Rect;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Ref);
    fn CFStringCreateWithCString(
        allocator: Ref,
        value: *const std::ffi::c_char,
        encoding: u32,
    ) -> Ref;
    fn CFPreferencesCopyValue(key: Ref, app: Ref, user: Ref, host: Ref) -> Ref;
    fn CFNumberGetValue(number: Ref, kind: i32, value: *mut f64) -> bool;
    fn CFGetTypeID(value: Ref) -> usize;
    fn CFNumberGetTypeID() -> usize;
    static kCFPreferencesAnyApplication: Ref;
    static kCFPreferencesCurrentUser: Ref;
    static kCFPreferencesAnyHost: Ref;
}

struct Owned(NonNull<c_void>);
impl Owned {
    fn new(value: Ref) -> Result<Self> {
        NonNull::new(value)
            .map(Self)
            .ok_or(MacOsInputError::EventCreationFailed)
    }
    fn raw(&self) -> Ref {
        self.0.as_ptr()
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: each create/copy result is owned exactly once and non-null.
        unsafe {
            CFRelease(self.raw());
        }
    }
}

pub(super) fn is_authorized() -> bool {
    // SAFETY: preflight has no pointer parameters or input side effects.
    unsafe { CGPreflightPostEventAccess() }
}
pub(super) fn caps_lock() -> bool {
    // SAFETY: 1 is kCGEventSourceStateCombinedSessionState.
    unsafe { CGEventSourceFlagsState(1) & (1 << 16) != 0 }
}

fn double_click_interval() -> Duration {
    // SAFETY: CF preference constants are process-lifetime references. Copied
    // objects are checked for null and type before reading their numeric value.
    unsafe {
        let Ok(key) = Owned::new(CFStringCreateWithCString(
            std::ptr::null_mut(),
            c"com.apple.mouse.doubleClickThreshold".as_ptr(),
            0x0800_0100,
        )) else {
            return Duration::from_millis(500);
        };
        if let Ok(number) = Owned::new(CFPreferencesCopyValue(
            key.raw(),
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        )) {
            let mut seconds = 0.0;
            if CFGetTypeID(number.raw()) == CFNumberGetTypeID()
                && CFNumberGetValue(number.raw(), 13, &raw mut seconds)
                && seconds.is_finite()
                && (0.0..=10.0).contains(&seconds)
            {
                return Duration::from_secs_f64(seconds);
            }
        }
    }
    Duration::from_millis(500)
}

fn location() -> Result<Point> {
    // SAFETY: a null source requests current system state; object remains alive
    // while its location is read. This does not post or move the cursor.
    unsafe {
        let event = Owned::new(CGEventCreate(std::ptr::null_mut()))?;
        Ok(CGEventGetLocation(event.raw()))
    }
}

fn clamp(point: Point) -> Result<Point> {
    // SAFETY: the display buffer is sized to the advertised count. If display
    // topology changes, Quartz returns at most the capacity passed to it.
    unsafe {
        let mut count = 0;
        if CGGetActiveDisplayList(0, std::ptr::null_mut(), &raw mut count) != 0 || count == 0 {
            return Err(MacOsInputError::EventCreationFailed);
        }
        let mut ids = vec![0; count as usize];
        if CGGetActiveDisplayList(count, ids.as_mut_ptr(), &raw mut count) != 0 {
            return Err(MacOsInputError::EventCreationFailed);
        }
        let mut nearest = None;
        let mut distance = f64::INFINITY;
        for id in ids.into_iter().take(count as usize) {
            let r = CGDisplayBounds(id);
            if r.size.width < 1.0 || r.size.height < 1.0 {
                continue;
            }
            let p = Point {
                x: point.x.clamp(r.origin.x, r.origin.x + r.size.width - 1.0),
                y: point.y.clamp(r.origin.y, r.origin.y + r.size.height - 1.0),
            };
            let d = (p.x - point.x).hypot(p.y - point.y);
            if d < distance {
                nearest = Some(p);
                distance = d;
            }
        }
        nearest.ok_or(MacOsInputError::EventCreationFailed)
    }
}

#[derive(Clone, Copy, Debug)]
struct Click {
    at: Instant,
    position: Point,
    count: i64,
    number: i64,
}

#[derive(Debug)]
pub(super) struct QuartzSink {
    position: Option<Point>,
    clicks: [Option<Click>; 5],
    click_interval: Duration,
    next_number: i64,
}
impl Default for QuartzSink {
    fn default() -> Self {
        Self {
            position: None,
            clicks: [None; 5],
            click_interval: double_click_interval(),
            next_number: 1,
        }
    }
}

type PreparedEvent = (Owned, Option<Point>, Option<(usize, Click)>);

impl QuartzSink {
    // Build an owned event separately from posting so native tests can verify
    // Quartz fields without ever injecting a key or moving the mouse.
    #[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
    fn create(&self, event: Event, flags: u64) -> Result<PreparedEvent> {
        // SAFETY: all references below are owned, all event enum values follow
        // CGEventTypes.h, and all pointers are released after use. No post here.
        unsafe {
            let source = Owned::new(CGEventSourceCreate(-1))?;
            CGEventSourceSetLocalEventsSuppressionInterval(source.raw(), 0.0);
            // Permit ordinary local events both after injection and during drag.
            for state in [0, 1] {
                CGEventSourceSetLocalEventsFilterDuringSuppressionState(source.raw(), 7, state);
            }
            let mut position = None;
            let mut click = None;
            let native = match event {
                Event::Key { code, down, repeat } => {
                    let e = Owned::new(CGEventCreateKeyboardEvent(source.raw(), code, down))?;
                    if modifier(code) != 0 || code == 57 {
                        CGEventSetType(e.raw(), 12);
                    }
                    CGEventSetIntegerValueField(e.raw(), 8, i64::from(repeat));
                    e
                }
                Event::Wheel {
                    vertical,
                    horizontal,
                } => {
                    let e = Owned::new(CGEventCreateScrollWheelEvent2(
                        source.raw(),
                        0,
                        2,
                        vertical,
                        horizontal,
                        0,
                    ))?;
                    // A preceding motion may still be in Quartz's event queue.
                    // Route scrolling to the last submitted position, like clicks.
                    if let Some(p) = self.position {
                        CGEventSetLocation(e.raw(), p);
                    }
                    e
                }
                Event::Motion {
                    x,
                    y,
                    relative,
                    drag,
                } => {
                    let old = self.position.map_or_else(location, Ok)?;
                    let p = clamp(if relative {
                        Point {
                            x: old.x + x,
                            y: old.y + y,
                        }
                    } else {
                        Point { x, y }
                    })?;
                    let kind = match drag {
                        None => 5,
                        Some(0) => 6,
                        Some(1) => 7,
                        Some(_) => 27,
                    };
                    let e = Owned::new(CGEventCreateMouseEvent(
                        source.raw(),
                        kind,
                        p,
                        drag.unwrap_or(0),
                    ))?;
                    CGEventSetIntegerValueField(e.raw(), 4, (p.x - old.x).round() as i64);
                    CGEventSetIntegerValueField(e.raw(), 5, (p.y - old.y).round() as i64);
                    if let Some(c) = drag.and_then(|button| self.clicks[button as usize]) {
                        CGEventSetIntegerValueField(e.raw(), 0, c.number);
                        CGEventSetIntegerValueField(e.raw(), 1, c.count);
                    }
                    position = Some(p);
                    e
                }
                Event::Button { button, down } => {
                    let p = self.position.map_or_else(location, Ok)?;
                    let kind = match (button, down) {
                        (0, true) => 1,
                        (0, false) => 2,
                        (1, true) => 3,
                        (1, false) => 4,
                        (_, true) => 25,
                        (_, false) => 26,
                    };
                    let e = Owned::new(CGEventCreateMouseEvent(source.raw(), kind, p, button))?;
                    let index = button as usize;
                    let now = Instant::now();
                    let count = if down {
                        let count = self.clicks[index]
                            .filter(|c| {
                                now.duration_since(c.at) <= self.click_interval
                                    && (p.x - c.position.x).hypot(p.y - c.position.y) <= 4.0
                            })
                            .map_or(1, |c| c.count.saturating_add(1));
                        click = Some((
                            index,
                            Click {
                                at: now,
                                position: p,
                                count,
                                number: self.next_number,
                            },
                        ));
                        count
                    } else {
                        self.clicks[index].map_or(1, |c| c.count)
                    };
                    CGEventSetIntegerValueField(e.raw(), 1, count);
                    let number = if down {
                        self.next_number
                    } else {
                        self.clicks[index].map_or(self.next_number, |c| c.number)
                    };
                    CGEventSetIntegerValueField(e.raw(), 0, number);
                    position = Some(p);
                    e
                }
            };
            CGEventSetFlags(native.raw(), flags);
            CGEventSetIntegerValueField(native.raw(), 42, VIEWFLOW_INPUT_TAG);
            Ok((native, position, click))
        }
    }
}

impl Sink for QuartzSink {
    fn post(&mut self, event: Event, flags: u64) -> Result<()> {
        if !is_authorized() {
            return Err(MacOsInputError::PermissionDenied);
        }
        let (native, position, click) = self.create(event, flags)?;
        // SAFETY: native is a live owned CGEvent. kCGHIDEventTap = 0. Quartz
        // provides no delivery result: success means submitted, not consumed.
        unsafe {
            CGEventPost(0, native.raw());
        }
        if let Some(p) = position {
            self.position = Some(p);
        }
        if let Some((index, c)) = click {
            self.clicks[index] = Some(c);
            self.next_number = self.next_number.checked_add(1).unwrap_or(1);
        }
        Ok(())
    }
    fn reset_pointer(&mut self) {
        self.position = None;
        self.clicks = [None; 5];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGEventGetType(event: Ref) -> u32;
        fn CGEventGetFlags(event: Ref) -> u64;
        fn CGEventGetIntegerValueField(event: Ref, field: u32) -> i64;
    }

    #[test]
    fn quartz_keyboard_objects_have_flags_repeat_and_loop_tag_without_posting() {
        let sink = QuartzSink::default();
        for (code, kind, repeat) in [(0, 10, true), (56, 12, false), (57, 12, false)] {
            let (event, _, _) = sink
                .create(
                    Event::Key {
                        code,
                        down: true,
                        repeat,
                    },
                    1 << 17,
                )
                .unwrap();
            // SAFETY: getters read the live event allocated above; no posting.
            unsafe {
                assert_eq!(CGEventGetType(event.raw()), kind);
                assert_eq!(CGEventGetFlags(event.raw()), 1 << 17);
                assert_eq!(
                    CGEventGetIntegerValueField(event.raw(), 8),
                    i64::from(repeat)
                );
                assert_eq!(
                    CGEventGetIntegerValueField(event.raw(), 42),
                    VIEWFLOW_INPUT_TAG
                );
            }
        }
    }

    #[test]
    fn quartz_buttons_and_wheel_construct_without_posting() {
        let sink = QuartzSink {
            position: Some(Point { x: 10.0, y: 20.0 }),
            ..QuartzSink::default()
        };
        for (button, kind) in [(0, 1), (1, 3), (2, 25), (3, 25), (4, 25)] {
            let (event, _, _) = sink
                .create(Event::Button { button, down: true }, 0)
                .unwrap();
            unsafe {
                assert_eq!(CGEventGetType(event.raw()), kind);
                assert_eq!(
                    CGEventGetIntegerValueField(event.raw(), 3),
                    i64::from(button)
                );
                assert_eq!(CGEventGetIntegerValueField(event.raw(), 1), 1);
            }
        }
        let (event, _, _) = sink
            .create(
                Event::Wheel {
                    vertical: 40,
                    horizontal: -20,
                },
                0,
            )
            .unwrap();
        unsafe {
            assert_eq!(CGEventGetType(event.raw()), 22);
            assert_eq!(CGEventGetIntegerValueField(event.raw(), 96), 40);
            assert_eq!(CGEventGetIntegerValueField(event.raw(), 97), -20);
            let p = CGEventGetLocation(event.raw());
            assert_eq!((p.x, p.y), (10.0, 20.0));
        }
    }

    #[test]
    fn quartz_click_up_matches_down_and_next_click_has_double_count() {
        let mut sink = QuartzSink {
            position: Some(Point { x: 10.0, y: 20.0 }),
            ..QuartzSink::default()
        };
        let (down, _, click) = sink
            .create(
                Event::Button {
                    button: 0,
                    down: true,
                },
                0,
            )
            .unwrap();
        let (index, c) = click.unwrap();
        // Simulate the ledger commit; deliberately do not post the event.
        sink.clicks[index] = Some(c);
        sink.next_number += 1;
        let (up, _, _) = sink
            .create(
                Event::Button {
                    button: 0,
                    down: false,
                },
                0,
            )
            .unwrap();
        let (double, _, _) = sink
            .create(
                Event::Button {
                    button: 0,
                    down: true,
                },
                0,
            )
            .unwrap();
        unsafe {
            assert_eq!(
                CGEventGetIntegerValueField(down.raw(), 0),
                CGEventGetIntegerValueField(up.raw(), 0)
            );
            assert_eq!(CGEventGetIntegerValueField(double.raw(), 1), 2);
        }
    }
}
