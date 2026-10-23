//! Native Precision Touchpad injection. No shortcut emulation or touchscreen mapping.
#![allow(unsafe_code)]

use super::windows_input::WindowsInputError;
use viewflow_protocol::{TouchpadContact, TouchpadFrame};
use windows_sys::Win32::{
    Foundation::POINT,
    System::LibraryLoader::{GetModuleHandleW, GetProcAddress},
    UI::{
        Controls::{DestroySyntheticPointerDevice, HSYNTHETICPOINTERDEVICE, POINTER_FEEDBACK_NONE, POINTER_TYPE_INFO},
        Input::Pointer::{InjectSyntheticPointerInput, POINTER_FLAG_CONFIDENCE, POINTER_FLAG_INCONTACT, POINTER_FLAG_INRANGE},
    },
};

const PT_TOUCHPAD: i32 = 5;

// Added after the SDK used by windows-sys 0.61. Resolve at runtime so older
// Windows installations can still start the ordinary input receiver.
#[repr(C)]
struct CreationParams {
    pointer_type: i32,
    max_count: u32,
    feedback_mode: i32,
    monitor: *mut core::ffi::c_void,
    width: u32,
    height: u32,
    options: u32,
}
type CreateDevice = unsafe extern "system" fn(*const CreationParams) -> HSYNTHETICPOINTERDEVICE;

#[derive(Debug)]
pub(crate) struct WindowsTouchpad {
    device: HSYNTHETICPOINTERDEVICE,
    state: crate::touchpad_state::TouchpadState,
    diagnostic_frames: u64,
    diagnostic_failures: u64,
    diagnostic_count: u8,
}

impl Default for WindowsTouchpad {
    fn default() -> Self {
        Self { device: core::ptr::null_mut(), state: crate::touchpad_state::TouchpadState::default(), diagnostic_frames: 0, diagnostic_failures: 0, diagnostic_count: u8::MAX }
    }
}

impl WindowsTouchpad {
    fn create(&mut self, frame: TouchpadFrame) -> Result<(), WindowsInputError> {
        let name: Vec<u16> = "user32.dll\0".encode_utf16().collect();
        let module = unsafe { GetModuleHandleW(name.as_ptr()) };
        let address = unsafe { GetProcAddress(module, c"CreateSyntheticPointerDevice2".as_ptr().cast()) }
            .ok_or(WindowsInputError::UnsupportedHidUsage { usage_page: 0x0d, usage_id: 5 })?;
        let create: CreateDevice = unsafe { core::mem::transmute(address) };
        let params = CreationParams {
            pointer_type: PT_TOUCHPAD, max_count: 5, feedback_mode: POINTER_FEEDBACK_NONE,
            monitor: core::ptr::null_mut(), width: frame.width, height: frame.height,
            // Physical size + gesture only. Existing pointer/button events
            // continue to drive the cursor and clicks exactly once.
            options: 3,
        };
        self.device = unsafe { create(&params) };
        if self.device.is_null() { return Err(WindowsInputError::SendInputFailed); }
        self.state.previous = TouchpadFrame { width: frame.width, height: frame.height, ..TouchpadFrame::default() };
        Ok(())
    }

    fn inject(device: HSYNTHETICPOINTERDEVICE, contacts: impl Iterator<Item = (TouchpadContact, bool)>) -> Result<(), WindowsInputError> {
        let mut inputs = Vec::with_capacity(5);
        for (c, touching) in contacts {
            let mut info = POINTER_TYPE_INFO { r#type: PT_TOUCHPAD, ..POINTER_TYPE_INFO::default() };
            let pointer = unsafe { &mut info.Anonymous.touchInfo.pointerInfo };
            pointer.pointerType = PT_TOUCHPAD;
            pointer.pointerId = c.id;
            pointer.pointerFlags = POINTER_FLAG_CONFIDENCE | if touching { POINTER_FLAG_INCONTACT | POINTER_FLAG_INRANGE } else { 0 };
            pointer.ptHimetricLocation = POINT { x: c.x as i32, y: c.y as i32 };
            // Zero requests the system's timestamp; capture clock drift is not
            // an input admission condition. FIFO ordering preserves lifetimes.
            inputs.push(info);
        }
        if !inputs.is_empty() && unsafe { InjectSyntheticPointerInput(device, inputs.as_ptr(), inputs.len() as u32) } == 0 {
            eprintln!("Viewflow touchpad injection failed: {}", std::io::Error::last_os_error());
            return Err(WindowsInputError::SendInputFailed);
        }
        Ok(())
    }

    pub(crate) fn apply(&mut self, frame: TouchpadFrame) -> Result<(), WindowsInputError> {
        self.diagnostic_frames += 1;
        let result = self.apply_frame(frame);
        let native_error = std::io::Error::last_os_error();
        if result.is_err() { self.diagnostic_failures += 1; }
        if self.diagnostic_count != frame.count || (result.is_err() && self.diagnostic_failures.is_power_of_two()) {
            use std::io::Write;
            let message = format!("touchpad frames={} count={} size={}x{} device={} failures={} result={result:?} native_error={native_error}",
                self.diagnostic_frames, frame.count, frame.width, frame.height, !self.device.is_null(), self.diagnostic_failures);
            eprintln!("{message}");
            // Service workers have no stderr reader. Keep contact-count and API
            // results alongside the executable; never record contact locations.
            if let Ok(exe) = std::env::current_exe() {
                if let Some(parent) = exe.parent() {
                    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(parent.join("touchpad.log")) {
                        let _ = writeln!(file, "{:?} {message}", std::time::SystemTime::now());
                    }
                }
            }
        }
        self.diagnostic_count = frame.count;
        result
    }

    fn apply_frame(&mut self, frame: TouchpadFrame) -> Result<(), WindowsInputError> {
        frame.validate().map_err(|_| WindowsInputError::DeltaOutOfRange)?;
        if !self.device.is_null() && (frame.width, frame.height) != (self.state.previous.width, self.state.previous.height) {
            self.release_all()?;
            self.destroy();
        }
        if self.device.is_null() {
            if frame.count == 0 { return Ok(()); }
            self.create(frame)?;
        }
        let device = self.device;
        self.state.apply(frame, |contacts| Self::inject(device, contacts.iter().copied()))
    }

    pub(crate) fn release_all(&mut self) -> Result<(), WindowsInputError> {
        if self.device.is_null() { return Ok(()); }
        let empty = TouchpadFrame { count: 0, ..self.state.previous };
        let device = self.device;
        self.state.apply(empty, |contacts| Self::inject(device, contacts.iter().copied()))
    }

    fn destroy(&mut self) {
        if !self.device.is_null() {
            unsafe { DestroySyntheticPointerDevice(self.device); }
            self.device = core::ptr::null_mut();
        }
    }
}

impl Drop for WindowsTouchpad {
    fn drop(&mut self) {
        let _ = self.release_all();
        self.destroy();
    }
}
