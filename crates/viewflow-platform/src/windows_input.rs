//! Windows keyboard and pointer injection.
//!
//! HID mapping and pressed-state bookkeeping are platform-independent so they
//! remain testable on non-Windows builders. Only the final `SendInput` call is
//! conditionally compiled for Windows.

#[cfg(any(windows, test))]
use std::collections::{BTreeMap, BTreeSet};

#[cfg(any(windows, test))]
use viewflow_protocol::{
    InputEvent, InputEventKind, InputSwitchState, KeyboardHidUsage, PointerButton,
};

/// A Windows Set 1 scan code plus the extended-key marker required by
/// `KEYBDINPUT`.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WindowsScanCode {
    pub code: u16,
    pub extended: bool,
}

/// Identifies input synthesized by Viewflow in Win32 low-level input hooks.
///
/// Capture backends can compare `dwExtraInfo` with this stable `"VFLW"` tag
/// to avoid forwarding injected events back across the transport.
pub const VIEWFLOW_INPUT_TAG: usize = 0x5646_4c57;

/// Counts returned after a complete native force-release batch.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ForceReleaseReport {
    pub requested_input_count: u32,
    pub inserted_input_count: u32,
}

/// Stable failure categories produced by the Windows input backend.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowsInputError {
    UnsupportedHidUsage { usage_page: u16, usage_id: u16 },
    NonFiniteDelta,
    DeltaOutOfRange,
    SendInputFailed,
}

/// Explicitly configured mapping from shared logical coordinates to native pixels.
#[derive(Clone, Copy, Debug)]
pub struct DesktopPointerDisplay {
    pub bounds: viewflow_protocol::DesktopRect,
    pub native_x: i32,
    pub native_y: i32,
    pub scale_milli: u32,
}

impl DesktopPointerDisplay {
    pub fn native_position(
        self,
        position: viewflow_protocol::DesktopPointerPosition,
    ) -> Result<(i32, i32), WindowsInputError> {
        self.bounds
            .validate()
            .map_err(|_| WindowsInputError::DeltaOutOfRange)?;
        if !(125..=8000).contains(&self.scale_milli) {
            return Err(WindowsInputError::DeltaOutOfRange);
        }
        let axis = |value: i64, origin: i64, extent: u64, native: i32| {
            let offset = value
                .checked_sub(origin)
                .ok_or(WindowsInputError::DeltaOutOfRange)?;
            if offset < 0 || offset as u64 >= extent {
                return Err(WindowsInputError::DeltaOutOfRange);
            }
            let pixels = i128::from(offset) * i128::from(self.scale_milli) / 1_000_000;
            i32::try_from(i128::from(native) + pixels)
                .map_err(|_| WindowsInputError::DeltaOutOfRange)
        };
        Ok((
            axis(
                position.x_millidip,
                self.bounds.x_millidip,
                self.bounds.width_millidip,
                self.native_x,
            )?,
            axis(
                position.y_millidip,
                self.bounds.y_millidip,
                self.bounds.height_millidip,
                self.native_y,
            )?,
        ))
    }
}

// Input coordinates and virtual-screen metrics must both be physical pixels.
#[cfg(any(windows, test))]
fn normalize_desktop_pixel(value: i32, origin: i32, size: i32) -> Result<i32, WindowsInputError> {
    let offset = i64::from(value) - i64::from(origin);
    if size <= 0 || offset < 0 || offset >= i64::from(size) {
        return Err(WindowsInputError::DeltaOutOfRange);
    }
    Ok(((offset * 65536 + 32768) / i64::from(size)).min(65535) as i32)
}

/// Sink used to isolate OS injection from the state machine.
#[cfg(any(windows, test))]
trait InputSink {
    fn relative_motion(&mut self, delta_x: i32, delta_y: i32) -> Result<(), WindowsInputError>;
    fn button(
        &mut self,
        button: PointerButton,
        state: InputSwitchState,
    ) -> Result<(), WindowsInputError>;
    fn wheel(&mut self, vertical: i32, horizontal: i32) -> Result<(), WindowsInputError>;
    fn key(
        &mut self,
        scan_code: WindowsScanCode,
        state: InputSwitchState,
    ) -> Result<(), WindowsInputError>;
    fn cancel_windows_key(&mut self, scan_code: WindowsScanCode) -> Result<(), WindowsInputError>;
}

/// Maximum number of best-effort release passes made while destroying an
/// injector. Successful releases are removed after each pass, so only inputs
/// that still appear held are retried.
#[cfg(any(windows, test))]
const DROP_RELEASE_ATTEMPTS: usize = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg(any(windows, test))]
enum ForceReleaseSpec {
    Key(WindowsScanCode),
    Button(PointerButton),
}

#[cfg(any(windows, test))]
fn supported_hid_usages() -> impl Iterator<Item = (u16, u16)> {
    (0x04..=0x47)
        .chain(0x49..=0x65)
        .chain(std::iter::once(0x67))
        .chain(0x68..=0x73)
        .chain(0x87..=0x8c)
        .chain(0xe0..=0xe7)
        .map(|usage_id| (0x07, usage_id))
        .chain(
            [0x00b5, 0x00b6, 0x00b7, 0x00cd, 0x00e2, 0x00e9, 0x00ea]
                .into_iter()
                .map(|usage_id| (0x0c, usage_id)),
        )
}

#[cfg(any(windows, test))]
fn force_release_specs() -> Vec<ForceReleaseSpec> {
    let mut releases = supported_hid_usages()
        .map(|(usage_page, usage_id)| {
            hid_usage_to_windows_scan_code(usage_page, usage_id)
                .expect("listed HID usage must have a Windows scan code")
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(ForceReleaseSpec::Key)
        .collect::<Vec<_>>();
    releases.extend(
        [
            PointerButton::Left,
            PointerButton::Middle,
            PointerButton::Right,
            PointerButton::Back,
            PointerButton::Forward,
        ]
        .into_iter()
        .map(ForceReleaseSpec::Button),
    );
    releases
}

/// Returns the deduplicated keyboard scan codes covered by the stateless
/// Windows force-release batch.
///
/// # Panics
///
/// Panics only if the internal supported-HID table contains an entry without
/// a Windows scan-code mapping.
#[cfg(windows)]
#[must_use]
pub fn force_release_scan_codes() -> Vec<WindowsScanCode> {
    supported_hid_usages()
        .map(|(usage_page, usage_id)| {
            hid_usage_to_windows_scan_code(usage_page, usage_id)
                .expect("listed HID usage must have a Windows scan code")
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Stateful injector that suppresses duplicate transitions and releases all
/// remotely-held state when a route ends or a connection fails.
#[derive(Debug)]
#[cfg(any(windows, test))]
struct StatefulInput<S: InputSink> {
    sink: S,
    pressed_keys: BTreeMap<(u16, u16), WindowsScanCode>,
    pressed_buttons: Vec<PointerButton>,
    pointer_remainder: (f64, f64),
    wheel_remainder: (f64, f64),
}

#[cfg(any(windows, test))]
impl<S: InputSink> StatefulInput<S> {
    fn new(sink: S) -> Self {
        Self {
            sink,
            pressed_keys: BTreeMap::new(),
            pressed_buttons: Vec::new(),
            pointer_remainder: (0.0, 0.0),
            wheel_remainder: (0.0, 0.0),
        }
    }

    fn apply(&mut self, event: &InputEvent) -> Result<(), WindowsInputError> {
        match event.event {
            InputEventKind::DesktopPointerPosition(_) | InputEventKind::Touchpad(_) => {
                return Err(WindowsInputError::DeltaOutOfRange);
            }
            InputEventKind::PointerMotion(motion) => {
                let (delta_x, remainder_x) =
                    accumulated_delta(motion.delta_x_dip, self.pointer_remainder.0, 1.0)?;
                let (delta_y, remainder_y) =
                    accumulated_delta(motion.delta_y_dip, self.pointer_remainder.1, 1.0)?;
                if delta_x != 0 || delta_y != 0 {
                    self.sink.relative_motion(delta_x, delta_y)?;
                }
                self.pointer_remainder = (remainder_x, remainder_y);
            }
            InputEventKind::PointerButton(button) => {
                self.apply_button(button.button, button.state)?;
            }
            InputEventKind::PointerWheel(wheel) => {
                self.apply_wheel(wheel.vertical_delta_detents, wheel.horizontal_delta_detents)?;
            }
            InputEventKind::KeyboardHidUsage(key) => self.apply_key(key)?,
            InputEventKind::ReleaseAll => self.release_all()?,
        }
        Ok(())
    }

    fn apply_button(
        &mut self,
        button: PointerButton,
        state: InputSwitchState,
    ) -> Result<(), WindowsInputError> {
        let is_pressed = self.pressed_buttons.contains(&button);
        let changes_state = matches!(state, InputSwitchState::Pressed) != is_pressed;
        if !changes_state {
            return Ok(());
        }
        self.sink.button(button, state)?;
        match state {
            InputSwitchState::Pressed => {
                self.pressed_buttons.push(button);
            }
            InputSwitchState::Released => {
                self.pressed_buttons.retain(|pressed| *pressed != button);
            }
        }
        Ok(())
    }

    fn apply_key(&mut self, key: KeyboardHidUsage) -> Result<(), WindowsInputError> {
        let identity = (key.usage_page, key.usage_id);
        let is_pressed = self.pressed_keys.contains_key(&identity);
        match key.state {
            InputSwitchState::Pressed if is_pressed && !key.repeat => Ok(()),
            InputSwitchState::Released if !is_pressed => Ok(()),
            InputSwitchState::Pressed => {
                let scan_code = hid_usage_to_windows_scan_code(key.usage_page, key.usage_id)
                    .ok_or(WindowsInputError::UnsupportedHidUsage {
                        usage_page: key.usage_page,
                        usage_id: key.usage_id,
                    })?;
                self.sink.key(scan_code, InputSwitchState::Pressed)?;
                self.pressed_keys.insert(identity, scan_code);
                Ok(())
            }
            InputSwitchState::Released => {
                let scan_code = self.pressed_keys[&identity];
                self.sink.key(scan_code, InputSwitchState::Released)?;
                self.pressed_keys.remove(&identity);
                Ok(())
            }
        }
    }

    fn apply_wheel(&mut self, vertical: f64, horizontal: f64) -> Result<(), WindowsInputError> {
        let (vertical_units, vertical_remainder) =
            accumulated_delta(vertical, self.wheel_remainder.0, 120.0)?;
        let (horizontal_units, horizontal_remainder) =
            accumulated_delta(horizontal, self.wheel_remainder.1, 120.0)?;
        if vertical_units != 0 || horizontal_units != 0 {
            self.sink.wheel(vertical_units, horizontal_units)?;
        }
        self.wheel_remainder = (vertical_remainder, horizontal_remainder);
        Ok(())
    }

    fn release_all(&mut self) -> Result<(), WindowsInputError> {
        self.pointer_remainder = (0.0, 0.0);
        self.wheel_remainder = (0.0, 0.0);
        let mut first_error = None;

        let buttons = self.pressed_buttons.clone();
        for button in buttons {
            match self.sink.button(button, InputSwitchState::Released) {
                Ok(()) => self.pressed_buttons.retain(|pressed| *pressed != button),
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }

        let keys: Vec<_> = self
            .pressed_keys
            .iter()
            .map(|(identity, scan_code)| (*identity, *scan_code))
            .collect();
        for (identity, scan_code) in keys {
            let release = if matches!(identity, (7, 0xe3 | 0xe7)) {
                self.sink.cancel_windows_key(scan_code)
            } else {
                self.sink.key(scan_code, InputSwitchState::Released)
            };
            match release {
                Ok(()) => {
                    self.pressed_keys.remove(&identity);
                }
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }

        first_error.map_or(Ok(()), Err)
    }

    fn release_all_before_drop(&mut self) {
        for _ in 0..DROP_RELEASE_ATTEMPTS {
            if self.pressed_buttons.is_empty() && self.pressed_keys.is_empty() {
                break;
            }
            let _ = self.release_all();
        }
    }
}

#[cfg(any(windows, test))]
impl<S: InputSink> Drop for StatefulInput<S> {
    fn drop(&mut self) {
        self.release_all_before_drop();
    }
}

#[cfg(any(windows, test))]
#[allow(clippy::cast_possible_truncation)]
fn accumulated_delta(
    value: f64,
    remainder: f64,
    units_per_input: f64,
) -> Result<(i32, f64), WindowsInputError> {
    if !value.is_finite() {
        return Err(WindowsInputError::NonFiniteDelta);
    }
    let total = value.mul_add(units_per_input, remainder);
    let integral = total.round();
    if integral < f64::from(i32::MIN) || integral > f64::from(i32::MAX) {
        return Err(WindowsInputError::DeltaOutOfRange);
    }
    Ok((integral as i32, total - integral))
}

/// Maps USB HID keyboard usages to Windows Set 1 scan codes.
///
/// Usage page `0x07` is Keyboard/Keypad and `0x0c` is Consumer. Unknown
/// usages are rejected rather than interpreted as virtual-key codes.
#[must_use]
pub fn hid_usage_to_windows_scan_code(usage_page: u16, usage_id: u16) -> Option<WindowsScanCode> {
    let (code, extended) = match (usage_page, usage_id) {
        (0x07, 0x04..=0x1d) => (letter_scan_code(usage_id)?, false),
        (0x07, 0x1e..=0x27) => (number_scan_code(usage_id)?, false),
        (0x07, 0x28) => (0x1c, false),
        (0x07, 0x29) => (0x01, false),
        (0x07, 0x2a) => (0x0e, false),
        (0x07, 0x2b) => (0x0f, false),
        (0x07, 0x2c) => (0x39, false),
        (0x07, 0x2d) => (0x0c, false),
        (0x07, 0x2e) => (0x0d, false),
        (0x07, 0x2f) => (0x1a, false),
        (0x07, 0x30) => (0x1b, false),
        (0x07, 0x31 | 0x32) => (0x2b, false),
        (0x07, 0x33) => (0x27, false),
        (0x07, 0x34) => (0x28, false),
        (0x07, 0x35) => (0x29, false),
        (0x07, 0x36) => (0x33, false),
        (0x07, 0x37) => (0x34, false),
        (0x07, 0x38) => (0x35, false),
        (0x07, 0x39) => (0x3a, false),
        (0x07, 0x3a..=0x43) => (0x3b + (usage_id - 0x3a), false),
        (0x07, 0x44) => (0x57, false),
        (0x07, 0x45) => (0x58, false),
        (0x07, 0x46) => (0x37, true),
        (0x07, 0x47) => (0x46, false),
        // Pause (0x48) needs an E1-prefixed multi-byte Set 1 sequence, which
        // KEYBDINPUT cannot represent with this backend's single scan code.
        (0x07, 0x49) => (0x52, true),
        (0x07, 0x4a) => (0x47, true),
        (0x07, 0x4b) => (0x49, true),
        (0x07, 0x4c) => (0x53, true),
        (0x07, 0x4d) => (0x4f, true),
        (0x07, 0x4e) => (0x51, true),
        (0x07, 0x4f) => (0x4d, true),
        (0x07, 0x50) => (0x4b, true),
        (0x07, 0x51) => (0x50, true),
        (0x07, 0x52) => (0x48, true),
        (0x07, 0x53) => (0x45, true),
        (0x07, 0x54) => (0x35, true),
        (0x07, 0x55) => (0x37, false),
        (0x07, 0x56) => (0x4a, false),
        (0x07, 0x57) => (0x4e, false),
        (0x07, 0x58) => (0x1c, true),
        (0x07, 0x59) => (0x4f, false),
        (0x07, 0x5a) => (0x50, false),
        (0x07, 0x5b) => (0x51, false),
        (0x07, 0x5c) => (0x4b, false),
        (0x07, 0x5d) => (0x4c, false),
        (0x07, 0x5e) => (0x4d, false),
        (0x07, 0x5f) => (0x47, false),
        (0x07, 0x60) => (0x48, false),
        (0x07, 0x61) => (0x49, false),
        (0x07, 0x62) => (0x52, false),
        (0x07, 0x63) => (0x53, false),
        (0x07, 0x64) => (0x56, false),
        (0x07, 0x65) => (0x5d, true),
        (0x07, 0x67) => (0x59, false),
        (0x07, 0x68..=0x72) => (0x64 + (usage_id - 0x68), false),
        (0x07, 0x73) => (0x76, false),
        (0x07, 0x87) => (0x73, false),
        (0x07, 0x88) => (0x70, false),
        (0x07, 0x89) => (0x7d, false),
        (0x07, 0x8a) => (0x79, false),
        (0x07, 0x8b) => (0x7b, false),
        (0x07, 0x8c) => (0x5c, false),
        (0x07, 0xe0) => (0x1d, false),
        (0x07, 0xe1) => (0x2a, false),
        (0x07, 0xe2) => (0x38, false),
        (0x07, 0xe3) => (0x5b, true),
        (0x07, 0xe4) => (0x1d, true),
        (0x07, 0xe5) => (0x36, false),
        (0x07, 0xe6) => (0x38, true),
        (0x07, 0xe7) => (0x5c, true),
        (0x0c, 0x00b5) => (0x19, true),
        (0x0c, 0x00b6) => (0x10, true),
        (0x0c, 0x00b7) => (0x24, true),
        (0x0c, 0x00cd) => (0x22, true),
        (0x0c, 0x00e2) => (0x20, true),
        (0x0c, 0x00e9) => (0x30, true),
        (0x0c, 0x00ea) => (0x2e, true),
        _ => return None,
    };
    Some(WindowsScanCode { code, extended })
}

fn letter_scan_code(usage_id: u16) -> Option<u16> {
    const CODES: [u16; 26] = [
        0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18,
        0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c,
    ];
    CODES.get(usize::from(usage_id - 0x04)).copied()
}

fn number_scan_code(usage_id: u16) -> Option<u16> {
    const CODES: [u16; 10] = [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b];
    CODES.get(usize::from(usage_id - 0x1e)).copied()
}

#[cfg(windows)]
mod native {
    use std::mem::size_of;

    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY,
        KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE,
        MOUSEEVENTF_MOVE_NOCOALESCE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL,
        MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT, SendInput,
    };

    use super::{
        ForceReleaseReport, ForceReleaseSpec, InputSink, InputSwitchState, PointerButton,
        StatefulInput, VIEWFLOW_INPUT_TAG, WindowsInputError, WindowsScanCode, force_release_specs,
    };
    use viewflow_protocol::{InputEvent, InputEventKind};

    const XBUTTON1: u32 = 1;
    const XBUTTON2: u32 = 2;

    /// Scoped to the synchronous injection call so async worker threads retain
    /// their original awareness policy on success and every error path.
    struct DpiAwarenessGuard(windows_sys::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT);

    impl DpiAwarenessGuard {
        #[allow(unsafe_code)]
        fn per_monitor_v2() -> Result<Self, WindowsInputError> {
            use windows_sys::Win32::UI::HiDpi::{
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext,
            };
            let previous =
                unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
            if previous.is_null() {
                return Err(WindowsInputError::SendInputFailed);
            }
            Ok(Self(previous))
        }
    }

    impl Drop for DpiAwarenessGuard {
        #[allow(unsafe_code)]
        fn drop(&mut self) {
            unsafe {
                windows_sys::Win32::UI::HiDpi::SetThreadDpiAwarenessContext(self.0);
            }
        }
    }

    type NativeRequest = (
        Option<InputEvent>,
        Option<super::DesktopPointerDisplay>,
        std::sync::mpsc::SyncSender<Result<(), WindowsInputError>>,
    );

    /// The desktop handle belongs to this OS thread, never a migrating async task.
    #[allow(unsafe_code)]
    fn bind_input_desktop(previous: usize) -> Result<usize, WindowsInputError> {
        use windows_sys::Win32::System::StationsAndDesktops::{
            OpenInputDesktop, SetThreadDesktop, CloseDesktop, DESKTOP_READOBJECTS,
        };
        let desktop = unsafe { OpenInputDesktop(0, 0, DESKTOP_READOBJECTS | windows_sys::Win32::Foundation::GENERIC_WRITE) };
        if desktop.is_null() {
            eprintln!("Viewflow input desktop open failed: {}", std::io::Error::last_os_error());
            return Err(WindowsInputError::SendInputFailed);
        }
        if unsafe { SetThreadDesktop(desktop) } == 0 {
            eprintln!("Viewflow input desktop bind failed: {}", std::io::Error::last_os_error());
            unsafe { CloseDesktop(desktop); }
            return Err(WindowsInputError::SendInputFailed);
        }
        if previous != 0 && previous != desktop as usize { unsafe { CloseDesktop(previous as _); } }
        if previous == 0 {
            eprintln!("atlas-input-desktop-bound handle={}", desktop as usize);
        }
        Ok(desktop as usize)
    }

    #[derive(Debug)]
    pub struct WindowsInputBackend {
        requests: Option<std::sync::mpsc::Sender<NativeRequest>>,
        worker: Option<std::thread::JoinHandle<usize>>,
        desktop_display: Option<super::DesktopPointerDisplay>,
    }

    impl Default for WindowsInputBackend {
        fn default() -> Self { Self::new() }
    }
    impl WindowsInputBackend {
        pub fn new() -> Self {
            let (send, receive) = std::sync::mpsc::channel::<NativeRequest>();
            let worker = std::thread::Builder::new().name("viewflow-native-input".into()).spawn(move || {
                let mut backend = DirectWindowsInputBackend::new();
                let mut desktop = 0;
                while let Ok((event, display, reply)) = receive.recv() {
                    let result = match bind_input_desktop(desktop) {
                        Ok(bound) => {
                            desktop = bound;
                            backend.desktop_display = display;
                            match event {
                                Some(event) => backend.apply(&event),
                                None => backend.release_all(),
                            }
                        }
                        Err(error) => Err(error),
                    };
                    let _ = reply.send(result);
                }
                let _ = backend.release_all();
                desktop
            });
            match worker {
                Ok(worker) => Self { requests: Some(send), worker: Some(worker), desktop_display: None },
                Err(error) => {
                    eprintln!("Viewflow input worker failed to start: {error}");
                    Self { requests: None, worker: None, desktop_display: None }
                }
            }
        }
        pub fn set_desktop_display(&mut self, display: super::DesktopPointerDisplay) {
            self.desktop_display = Some(display);
        }
        fn request(&mut self, event: Option<InputEvent>) -> Result<(), WindowsInputError> {
            let (reply, result) = std::sync::mpsc::sync_channel(1);
            self.requests.as_ref().ok_or(WindowsInputError::SendInputFailed)?
                .send((event, self.desktop_display, reply)).map_err(|_| WindowsInputError::SendInputFailed)?;
            result.recv().map_err(|_| WindowsInputError::SendInputFailed)?
        }
        pub fn apply(&mut self, event: &InputEvent) -> Result<(), WindowsInputError> { self.request(Some(*event)) }
        pub fn release_all(&mut self) -> Result<(), WindowsInputError> { self.request(None) }
    }
    impl Drop for WindowsInputBackend {
        #[allow(unsafe_code)]
        fn drop(&mut self) {
            self.requests.take();
            if let Some(worker) = self.worker.take() {
                if let Ok(desktop) = worker.join() {
                    if desktop != 0 {
                        // The owning thread has exited; the handle is no longer bound.
                        unsafe { windows_sys::Win32::System::StationsAndDesktops::CloseDesktop(desktop as _); }
                    }
                }
            }
        }
    }

    /// Windows input injector. This must run in the interactive desktop session;
    /// `SendInput` cannot cross UIPI into a higher-integrity target.
    #[derive(Debug)]
    pub struct DirectWindowsInputBackend {
        touchpad: crate::windows_touchpad::WindowsTouchpad,
        input: StatefulInput<SendInputSink>,
        desktop_display: Option<super::DesktopPointerDisplay>,
    }

    impl Default for DirectWindowsInputBackend {
        fn default() -> Self {
            Self::new()
        }
    }

    impl DirectWindowsInputBackend {
        #[must_use]
        pub fn new() -> Self {
            Self {
                input: StatefulInput::new(SendInputSink),
                touchpad: crate::windows_touchpad::WindowsTouchpad::default(),
                desktop_display: None,
            }
        }

        pub fn set_desktop_display(&mut self, display: super::DesktopPointerDisplay) {
            self.desktop_display = Some(display);
        }

        /// Injects one validated protocol event.
        ///
        /// # Errors
        ///
        /// Returns an error for unsupported HID usages, invalid deltas, or a
        /// failed `SendInput` call.
        #[allow(unsafe_code)]
        pub fn apply(&mut self, event: &InputEvent) -> Result<(), WindowsInputError> {
            if let viewflow_protocol::InputEventKind::DesktopPointerPosition(position) = event.event
            {
                let display = self
                    .desktop_display
                    .ok_or(WindowsInputError::DeltaOutOfRange)?;
                let (x, y) = display.native_position(position)?;
                // Desktop positions set the system pointer directly. A successful
                // SendInput insertion alone does not establish that the pointer
                // moved before the next ordered button transition.
                let _dpi = DpiAwarenessGuard::per_monitor_v2()?;
                unsafe { windows_sys::Win32::Foundation::SetLastError(0); }
                if unsafe { windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(x, y) } == 0 {
                    eprintln!("Viewflow SetCursorPos failed: {}", std::io::Error::last_os_error());
                    return Err(WindowsInputError::SendInputFailed);
                }
                if event.sequence == 1 {
                    let mut actual = windows_sys::Win32::Foundation::POINT { x: 0, y: 0 };
                    let read = unsafe { windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut actual) };
                    eprintln!("atlas-cursor-native generation={} requested_x={} requested_y={} actual_x={} actual_y={} read_ok={}",
                        event.lease_generation, x, y, actual.x, actual.y, read);
                }
                return Ok(());
            }
            if let InputEventKind::Touchpad(frame) = event.event { return self.touchpad.apply(frame); }
            if matches!(event.event, InputEventKind::ReleaseAll) { return self.release_all(); }
            self.input.apply(event)
        }

        /// Releases every key and pointer button still held by the remote peer.
        ///
        /// # Errors
        ///
        /// Returns `SendInputFailed` if Windows rejects a release. State for
        /// successfully released inputs is removed even if a later release fails.
        pub fn release_all(&mut self) -> Result<(), WindowsInputError> {
            let touchpad = self.touchpad.release_all();
            let keys = self.input.release_all();
            touchpad.and(keys)
        }
    }

    #[derive(Debug)]
    struct SendInputSink;

    impl InputSink for SendInputSink {
        fn relative_motion(&mut self, delta_x: i32, delta_y: i32) -> Result<(), WindowsInputError> {
            send(mouse_input(
                delta_x,
                delta_y,
                0,
                MOUSEEVENTF_MOVE | MOUSEEVENTF_MOVE_NOCOALESCE,
            ))
        }

        fn button(
            &mut self,
            button: PointerButton,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            send(button_input(button, state))
        }

        fn wheel(&mut self, vertical: i32, horizontal: i32) -> Result<(), WindowsInputError> {
            match (vertical != 0, horizontal != 0) {
                (true, true) => send_batch(&[
                    mouse_input(0, 0, wheel_delta_data(vertical), MOUSEEVENTF_WHEEL),
                    mouse_input(0, 0, wheel_delta_data(horizontal), MOUSEEVENTF_HWHEEL),
                ]),
                (true, false) => send(mouse_input(
                    0,
                    0,
                    wheel_delta_data(vertical),
                    MOUSEEVENTF_WHEEL,
                )),
                (false, true) => send(mouse_input(
                    0,
                    0,
                    wheel_delta_data(horizontal),
                    MOUSEEVENTF_HWHEEL,
                )),
                (false, false) => Ok(()),
            }
        }

        fn key(
            &mut self,
            scan_code: WindowsScanCode,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            send(keyboard_input(scan_code, state))
        }

        fn cancel_windows_key(
            &mut self,
            scan_code: WindowsScanCode,
        ) -> Result<(), WindowsInputError> {
            // 0xE8 is unassigned. Mark forced cleanup as a chord cancellation,
            // not a lone Win tap. The preview already passes this replay tag
            // through its hook, so the mask cannot enter source input.
            // Normal physical key-up continues through apply_key unchanged.
            let mask = |up| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: 0xe8,
                        wScan: 0,
                        dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                        time: 0,
                        dwExtraInfo: 0x5646_4d57,
                    },
                },
            };
            let result = send_batch(&[
                mask(false),
                mask(true),
                keyboard_input(scan_code, InputSwitchState::Released),
            ]);
            if result.is_err() {
                // A partial SendInput batch must not retain even the mask key.
                let _ = send(mask(true));
            }
            result
        }
    }

    const fn wheel_delta_data(delta: i32) -> u32 {
        u32::from_ne_bytes(delta.to_ne_bytes())
    }

    /// Sends explicit key-up and button-up events for every input supported by
    /// the Viewflow Windows backend, independently of tracked connection state.
    ///
    /// # Errors
    ///
    /// Returns `SendInputFailed` unless Windows accepts the complete release
    /// batch. Callers must not publish a completion receipt after an error.
    pub fn force_release_all_supported() -> Result<ForceReleaseReport, WindowsInputError> {
        let inputs = force_release_specs()
            .into_iter()
            .map(|release| match release {
                ForceReleaseSpec::Key(scan_code) => {
                    keyboard_input(scan_code, InputSwitchState::Released)
                }
                ForceReleaseSpec::Button(button) => {
                    button_input(button, InputSwitchState::Released)
                }
            })
            .collect::<Vec<_>>();
        // Submit each release separately.  A single oversized or mixed
        // keyboard/mouse SendInput batch can be rejected as a whole on real
        // interactive desktops, which would leave every key in an uncertain
        // state.  Per-event completion preserves the all-or-error contract
        // while avoiding that all-or-nothing Windows boundary.
        let requested_input_count =
            u32::try_from(inputs.len()).expect("force-release input count fits u32");
        let mut inserted_input_count = 0_u32;
        for input in &inputs {
            let report = send_batch_report(std::slice::from_ref(input))?;
            inserted_input_count = inserted_input_count
                .checked_add(report.inserted_input_count)
                .expect("force-release input count fits u32");
        }
        Ok(ForceReleaseReport {
            requested_input_count,
            inserted_input_count,
        })
    }

    fn keyboard_input(scan_code: WindowsScanCode, state: InputSwitchState) -> INPUT {
        let mut flags = KEYEVENTF_SCANCODE;
        if scan_code.extended {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if state == InputSwitchState::Released {
            flags |= KEYEVENTF_KEYUP;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: keyboard_input_fields(scan_code.code, flags),
            },
        }
    }

    fn button_input(button: PointerButton, state: InputSwitchState) -> INPUT {
        let (data, down, up) = match button {
            PointerButton::Left => (0, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
            PointerButton::Middle => (0, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
            PointerButton::Right => (0, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            PointerButton::Back => (XBUTTON1, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP),
            PointerButton::Forward => (XBUTTON2, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP),
        };
        let flags = match state {
            InputSwitchState::Pressed => down,
            InputSwitchState::Released => up,
        };
        mouse_input(0, 0, data, flags)
    }

    fn keyboard_input_fields(scan_code: u16, flags: u32) -> KEYBDINPUT {
        KEYBDINPUT {
            wVk: 0,
            wScan: scan_code,
            dwFlags: flags,
            time: 0,
            dwExtraInfo: VIEWFLOW_INPUT_TAG,
        }
    }

    fn mouse_input(delta_x: i32, delta_y: i32, data: u32, flags: u32) -> INPUT {
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: mouse_input_fields(delta_x, delta_y, data, flags),
            },
        }
    }

    fn mouse_input_fields(delta_x: i32, delta_y: i32, data: u32, flags: u32) -> MOUSEINPUT {
        MOUSEINPUT {
            dx: delta_x,
            dy: delta_y,
            mouseData: data,
            dwFlags: flags,
            time: 0,
            dwExtraInfo: VIEWFLOW_INPUT_TAG,
        }
    }

    fn send(input: INPUT) -> Result<(), WindowsInputError> {
        send_batch(&[input])
    }

    fn send_batch(inputs: &[INPUT]) -> Result<(), WindowsInputError> {
        send_batch_report(inputs).map(|_| ())
    }

    #[allow(unsafe_code)]
    fn send_batch_report(inputs: &[INPUT]) -> Result<ForceReleaseReport, WindowsInputError> {
        debug_assert!(!inputs.is_empty());
        let input_count = u32::try_from(inputs.len()).expect("INPUT batch length fits u32");
        let input_size = i32::try_from(size_of::<INPUT>()).expect("INPUT size fits i32");
        // SAFETY: every element is a fully initialized INPUT value, the slice
        // remains valid for the duration of the call, and `input_size` exactly
        // matches the ABI type Windows expects.
        let inserted = unsafe { SendInput(input_count, inputs.as_ptr(), input_size) };
        if inserted != input_count {
            eprintln!(
                "Viewflow SendInput incomplete: requested={input_count} inserted={inserted} os_error={}",
                std::io::Error::last_os_error()
            );
        }
        send_input_result(input_count, inserted)?;
        Ok(ForceReleaseReport {
            requested_input_count: input_count,
            inserted_input_count: inserted,
        })
    }

    fn send_input_result(requested: u32, inserted: u32) -> Result<(), WindowsInputError> {
        if inserted == requested {
            Ok(())
        } else {
            Err(WindowsInputError::SendInputFailed)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn constructed_keyboard_and_mouse_inputs_have_viewflow_tag() {
            assert_eq!(
                keyboard_input_fields(0x1e, KEYEVENTF_SCANCODE).dwExtraInfo,
                VIEWFLOW_INPUT_TAG
            );
            assert_eq!(
                mouse_input_fields(1, -1, 0, MOUSEEVENTF_MOVE).dwExtraInfo,
                VIEWFLOW_INPUT_TAG
            );
        }

        #[test]
        fn force_release_fields_are_explicit_key_and_button_ups() {
            let key = keyboard_input_fields(
                0x1e,
                KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP,
            );
            assert_eq!(
                key.dwFlags,
                KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP
            );

            for (_, up) in [
                (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
                (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
                (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
                (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP),
            ] {
                assert_ne!(up, 0);
            }
        }

        #[test]
        fn force_release_requires_the_complete_send_input_batch() {
            assert_eq!(send_input_result(135, 135), Ok(()));
            assert_eq!(
                send_input_result(135, 134),
                Err(WindowsInputError::SendInputFailed)
            );
            assert_eq!(
                send_input_result(135, 0),
                Err(WindowsInputError::SendInputFailed)
            );
        }
    }
}

#[cfg(windows)]
pub use native::{WindowsInputBackend, force_release_all_supported};

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, collections::VecDeque, rc::Rc};

    use super::*;
    use viewflow_protocol::{
        Id128, InputEventKind, KeyboardHidUsage, PointerButtonEvent, RelativePointerMotion,
    };

    #[derive(Debug, Default)]
    struct RecordingSink {
        operations: Vec<String>,
        fail_after: Option<usize>,
    }

    impl RecordingSink {
        fn record(&mut self, operation: String) -> Result<(), WindowsInputError> {
            if self.fail_after == Some(self.operations.len()) {
                self.fail_after = None;
                return Err(WindowsInputError::SendInputFailed);
            }
            self.operations.push(operation);
            Ok(())
        }
    }

    impl InputSink for RecordingSink {
        fn relative_motion(&mut self, delta_x: i32, delta_y: i32) -> Result<(), WindowsInputError> {
            self.record(format!("move:{delta_x}:{delta_y}"))
        }

        fn button(
            &mut self,
            button: PointerButton,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            self.record(format!("button:{button:?}:{state:?}"))
        }

        fn wheel(&mut self, vertical: i32, horizontal: i32) -> Result<(), WindowsInputError> {
            self.record(format!("wheel:{vertical}:{horizontal}"))
        }

        fn key(
            &mut self,
            scan_code: WindowsScanCode,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            self.record(format!(
                "key:{}:{}:{state:?}",
                scan_code.code, scan_code.extended
            ))
        }
        fn cancel_windows_key(
            &mut self,
            scan_code: WindowsScanCode,
        ) -> Result<(), WindowsInputError> {
            self.record(format!("cancel-win:{}", scan_code.code))
        }
    }

    #[derive(Debug)]
    struct DropProbeSink {
        operations: Rc<RefCell<Vec<String>>>,
        release_failures: VecDeque<bool>,
        fail_releases_forever: bool,
    }

    impl DropProbeSink {
        fn new(
            operations: Rc<RefCell<Vec<String>>>,
            release_failures: impl IntoIterator<Item = bool>,
        ) -> Self {
            Self {
                operations,
                release_failures: release_failures.into_iter().collect(),
                fail_releases_forever: false,
            }
        }

        fn permanently_failing(operations: Rc<RefCell<Vec<String>>>) -> Self {
            Self {
                operations,
                release_failures: VecDeque::new(),
                fail_releases_forever: true,
            }
        }

        fn record(&self, operation: String) {
            self.operations.borrow_mut().push(operation);
        }

        fn finish_release(&mut self) -> Result<(), WindowsInputError> {
            if self.fail_releases_forever || self.release_failures.pop_front().unwrap_or(false) {
                Err(WindowsInputError::SendInputFailed)
            } else {
                Ok(())
            }
        }
    }

    impl InputSink for DropProbeSink {
        fn relative_motion(&mut self, delta_x: i32, delta_y: i32) -> Result<(), WindowsInputError> {
            self.record(format!("move:{delta_x}:{delta_y}"));
            Ok(())
        }

        fn button(
            &mut self,
            button: PointerButton,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            self.record(format!("button:{button:?}:{state:?}"));
            if state == InputSwitchState::Released {
                self.finish_release()
            } else {
                Ok(())
            }
        }

        fn wheel(&mut self, vertical: i32, horizontal: i32) -> Result<(), WindowsInputError> {
            self.record(format!("wheel:{vertical}:{horizontal}"));
            Ok(())
        }

        fn key(
            &mut self,
            scan_code: WindowsScanCode,
            state: InputSwitchState,
        ) -> Result<(), WindowsInputError> {
            self.record(format!(
                "key:{}:{}:{state:?}",
                scan_code.code, scan_code.extended
            ));
            if state == InputSwitchState::Released {
                self.finish_release()
            } else {
                Ok(())
            }
        }
        fn cancel_windows_key(
            &mut self,
            scan_code: WindowsScanCode,
        ) -> Result<(), WindowsInputError> {
            self.record(format!("cancel-win:{}", scan_code.code));
            self.finish_release()
        }
    }

    #[test]
    fn desktop_position_2x_uses_physical_virtual_screen_metrics() {
        let display = super::DesktopPointerDisplay {
            bounds: viewflow_protocol::DesktopRect {
                x_millidip: 0,
                y_millidip: 0,
                width_millidip: 1_920_000,
                height_millidip: 1_200_000,
            },
            native_x: 0,
            native_y: 0,
            scale_milli: 2000,
        };
        let (x, y) = display
            .native_position(viewflow_protocol::DesktopPointerPosition {
                x_millidip: 1_440_000,
                y_millidip: 900_000,
            })
            .unwrap();
        assert_eq!((x, y), (2880, 1800));
        let nx = super::normalize_desktop_pixel(x, 0, 3840).unwrap();
        let ny = super::normalize_desktop_pixel(y, 0, 2400).unwrap();
        assert_eq!((nx, ny), (49160, 49165));
        // Virtualized 1920x1200 metrics would wrongly reject a valid position.
        assert!(super::normalize_desktop_pixel(x, 0, 1920).is_err());
        assert!(super::normalize_desktop_pixel(y, 0, 1200).is_err());
    }

    #[test]
    fn desktop_position_maps_negative_origins_and_rejects_outside() {
        let display = super::DesktopPointerDisplay {
            bounds: viewflow_protocol::DesktopRect {
                x_millidip: -1_280_000,
                y_millidip: 20_000,
                width_millidip: 1_280_000,
                height_millidip: 720_000,
            },
            native_x: -1920,
            native_y: 30,
            scale_milli: 1500,
        };
        let point = |x, y| viewflow_protocol::DesktopPointerPosition {
            x_millidip: x,
            y_millidip: y,
        };
        assert_eq!(
            display.native_position(point(-1_280_000, 20_000)),
            Ok((-1920, 30))
        );
        assert_eq!(
            display.native_position(point(-640_000, 380_000)),
            Ok((-960, 570))
        );
        assert_eq!(display.native_position(point(-1, 739_999)), Ok((-1, 1109)));
        for invalid in [
            point(0, 20_000),
            point(-1_280_001, 20_000),
            point(-640_000, 740_000),
            point(i64::MIN, 0),
        ] {
            assert!(display.native_position(invalid).is_err());
        }
    }

    fn input(event: InputEventKind) -> InputEvent {
        InputEvent {
            lease_generation: 1,
            target_device: Id128(2),
            sequence: 1,
            sender_not_after_ns: 1,
            event,
        }
    }

    fn keyboard(usage_id: u16, state: InputSwitchState, repeat: bool) -> InputEvent {
        input(InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
            usage_page: 0x07,
            usage_id,
            state,
            repeat,
        }))
    }

    #[test]
    fn maps_letters_modifiers_navigation_and_consumer_keys() {
        assert_eq!(VIEWFLOW_INPUT_TAG, 0x5646_4c57);
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0x04),
            Some(WindowsScanCode {
                code: 0x1e,
                extended: false,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0xe4),
            Some(WindowsScanCode {
                code: 0x1d,
                extended: true,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0x50),
            Some(WindowsScanCode {
                code: 0x4b,
                extended: true,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x0c, 0x00e9),
            Some(WindowsScanCode {
                code: 0x30,
                extended: true,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0x73),
            Some(WindowsScanCode {
                code: 0x76,
                extended: false,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0x64),
            Some(WindowsScanCode {
                code: 0x56,
                extended: false,
            })
        );
        assert_eq!(
            hid_usage_to_windows_scan_code(0x07, 0x67),
            Some(WindowsScanCode {
                code: 0x59,
                extended: false,
            })
        );
        assert_eq!(hid_usage_to_windows_scan_code(0x07, 0x48), None);
        assert_eq!(hid_usage_to_windows_scan_code(0x07, 0xffff), None);
    }

    #[test]
    fn force_release_plan_covers_every_supported_usage_and_five_buttons() {
        let supported = supported_hid_usages().collect::<BTreeSet<_>>();
        assert_eq!(supported.len(), 131);
        for usage_page in [0x07, 0x0c] {
            for usage_id in 0..=u16::MAX {
                assert_eq!(
                    hid_usage_to_windows_scan_code(usage_page, usage_id).is_some(),
                    supported.contains(&(usage_page, usage_id)),
                    "coverage mismatch for HID {usage_page:#06x}:{usage_id:#06x}"
                );
            }
        }

        let releases = force_release_specs();
        assert_eq!(
            releases
                .iter()
                .filter(|release| matches!(release, ForceReleaseSpec::Key(_)))
                .count(),
            130
        );
        assert_eq!(releases.len(), 135);
        assert_eq!(
            &releases[130..],
            &[
                ForceReleaseSpec::Button(PointerButton::Left),
                ForceReleaseSpec::Button(PointerButton::Middle),
                ForceReleaseSpec::Button(PointerButton::Right),
                ForceReleaseSpec::Button(PointerButton::Back),
                ForceReleaseSpec::Button(PointerButton::Forward),
            ]
        );
    }

    #[test]
    fn injects_f24_down_and_up_with_set_one_scan_code() {
        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&keyboard(0x73, InputSwitchState::Pressed, false))
            .unwrap();
        state
            .apply(&keyboard(0x73, InputSwitchState::Released, false))
            .unwrap();
        assert_eq!(
            state.sink.operations,
            ["key:118:false:Pressed", "key:118:false:Released"]
        );
    }

    #[test]
    fn suppresses_duplicate_transitions_but_allows_key_repeat() {
        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, true))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Released, false))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Released, false))
            .unwrap();
        assert_eq!(state.sink.operations.len(), 3);
    }

    #[test]
    fn forced_win_cleanup_is_cancelled_but_normal_release_is_unchanged() {
        for usage in [0xe3, 0xe7] {
            let mut state = StatefulInput::new(RecordingSink::default());
            state
                .apply(&keyboard(usage, InputSwitchState::Pressed, false))
                .unwrap();
            state
                .apply(&keyboard(usage, InputSwitchState::Released, false))
                .unwrap();
            assert!(
                !state
                    .sink
                    .operations
                    .iter()
                    .any(|op| op.starts_with("cancel-win"))
            );
            state
                .apply(&keyboard(usage, InputSwitchState::Pressed, false))
                .unwrap();
            state.release_all().unwrap();
            assert!(
                state
                    .sink
                    .operations
                    .last()
                    .unwrap()
                    .starts_with("cancel-win")
            );
            assert!(state.pressed_keys.is_empty());
        }
    }

    #[test]
    fn release_all_clears_keys_and_buttons() {
        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&keyboard(0xe0, InputSwitchState::Pressed, false))
            .unwrap();
        state
            .apply(&input(InputEventKind::PointerButton(PointerButtonEvent {
                button: PointerButton::Left,
                state: InputSwitchState::Pressed,
            })))
            .unwrap();
        state.apply(&input(InputEventKind::ReleaseAll)).unwrap();
        assert!(state.pressed_keys.is_empty());
        assert!(state.pressed_buttons.is_empty());
        assert!(
            state
                .sink
                .operations
                .iter()
                .any(|value| value.contains("Released"))
        );
    }

    #[test]
    fn release_all_continues_after_failure_and_retains_only_failed_state() {
        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&input(InputEventKind::PointerButton(PointerButtonEvent {
                button: PointerButton::Left,
                state: InputSwitchState::Pressed,
            })))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        state.sink.fail_after = Some(state.sink.operations.len());

        assert_eq!(state.release_all(), Err(WindowsInputError::SendInputFailed));
        assert_eq!(state.pressed_buttons, [PointerButton::Left]);
        assert!(state.pressed_keys.is_empty());
        assert_eq!(
            state.sink.operations,
            [
                "button:Left:Pressed",
                "key:30:false:Pressed",
                "key:30:false:Released"
            ]
        );
    }

    #[test]
    fn drop_retries_a_transient_release_failure() {
        let operations = Rc::new(RefCell::new(Vec::new()));
        let sink = DropProbeSink::new(Rc::clone(&operations), [true, false]);
        let mut state = StatefulInput::new(sink);
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        operations.borrow_mut().clear();

        drop(state);

        assert_eq!(
            *operations.borrow(),
            ["key:30:false:Released", "key:30:false:Released"]
        );
    }

    #[test]
    fn drop_does_not_repeat_items_released_by_an_earlier_pass() {
        let operations = Rc::new(RefCell::new(Vec::new()));
        let sink = DropProbeSink::new(Rc::clone(&operations), [false, true, false]);
        let mut state = StatefulInput::new(sink);
        state
            .apply(&input(InputEventKind::PointerButton(PointerButtonEvent {
                button: PointerButton::Left,
                state: InputSwitchState::Pressed,
            })))
            .unwrap();
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        operations.borrow_mut().clear();

        drop(state);

        assert_eq!(
            *operations.borrow(),
            [
                "button:Left:Released",
                "key:30:false:Released",
                "key:30:false:Released"
            ]
        );
    }

    #[test]
    fn drop_bounds_permanently_failing_release_attempts() {
        let operations = Rc::new(RefCell::new(Vec::new()));
        let sink = DropProbeSink::permanently_failing(Rc::clone(&operations));
        let mut state = StatefulInput::new(sink);
        state
            .apply(&keyboard(0x04, InputSwitchState::Pressed, false))
            .unwrap();
        operations.borrow_mut().clear();

        drop(state);

        assert_eq!(operations.borrow().len(), DROP_RELEASE_ATTEMPTS);
        assert!(
            operations
                .borrow()
                .iter()
                .all(|operation| operation == "key:30:false:Released")
        );
    }

    #[test]
    fn failed_injection_does_not_commit_new_pressed_state() {
        let sink = RecordingSink {
            operations: Vec::new(),
            fail_after: Some(0),
        };
        let mut state = StatefulInput::new(sink);
        assert_eq!(
            state.apply(&keyboard(0x04, InputSwitchState::Pressed, false)),
            Err(WindowsInputError::SendInputFailed)
        );
        assert!(state.pressed_keys.is_empty());
    }

    #[test]
    fn rounds_motion_and_rejects_non_finite_values() {
        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&input(InputEventKind::PointerMotion(
                RelativePointerMotion {
                    delta_x_dip: 1.6,
                    delta_y_dip: -2.4,
                },
            )))
            .unwrap();
        state
            .apply(&input(InputEventKind::PointerMotion(
                RelativePointerMotion {
                    delta_x_dip: 0.6,
                    delta_y_dip: -0.6,
                },
            )))
            .unwrap();
        assert_eq!(state.sink.operations, ["move:2:-2", "move:0:-1"]);
        assert_eq!(
            state.apply(&input(InputEventKind::PointerMotion(
                RelativePointerMotion {
                    delta_x_dip: f64::NAN,
                    delta_y_dip: 0.0,
                },
            ))),
            Err(WindowsInputError::NonFiniteDelta)
        );
    }

    #[test]
    fn accumulates_high_resolution_wheel_detents() {
        use viewflow_protocol::PointerWheelEvent;

        let mut state = StatefulInput::new(RecordingSink::default());
        for _ in 0..9 {
            state
                .apply(&input(InputEventKind::PointerWheel(PointerWheelEvent {
                    vertical_delta_detents: 0.001,
                    horizontal_delta_detents: -0.001,
                })))
                .unwrap();
        }
        assert_eq!(state.sink.operations, ["wheel:1:-1"]);
        assert!(state.wheel_remainder.0 > 0.0);
        assert!(state.wheel_remainder.1 < 0.0);
    }

    #[test]
    fn dual_axis_wheel_is_one_sink_operation_and_commits_remainders_together() {
        use viewflow_protocol::PointerWheelEvent;

        let mut state = StatefulInput::new(RecordingSink::default());
        state
            .apply(&input(InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: 0.01,
                horizontal_delta_detents: -0.01,
            })))
            .unwrap();
        assert_eq!(state.sink.operations, ["wheel:1:-1"]);
        let committed_remainder = state.wheel_remainder;
        assert!(committed_remainder.0 > 0.0);
        assert!(committed_remainder.1 < 0.0);

        state.sink.fail_after = Some(state.sink.operations.len());
        assert_eq!(
            state.apply(&input(InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: 0.01,
                horizontal_delta_detents: -0.01,
            }))),
            Err(WindowsInputError::SendInputFailed)
        );
        assert_eq!(state.sink.operations, ["wheel:1:-1"]);
        assert_eq!(state.wheel_remainder, committed_remainder);
    }

    #[test]
    fn invalid_horizontal_wheel_delta_has_no_vertical_side_effect() {
        use viewflow_protocol::PointerWheelEvent;

        let mut state = StatefulInput::new(RecordingSink::default());
        assert_eq!(
            state.apply(&input(InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: 1.0,
                horizontal_delta_detents: f64::NAN,
            }))),
            Err(WindowsInputError::NonFiniteDelta)
        );
        assert!(state.sink.operations.is_empty());
        assert_eq!(state.wheel_remainder, (0.0, 0.0));
    }
}
