//! A small native Win32 endpoint for CPU-decoded proxy frames.
//!
//! This module deliberately stops at per-pixel-alpha presentation.  It does
//! not implement capture, GPU texture sharing, input forwarding, or backdrop
//! blur.  `UpdateLayeredWindow` requires premultiplied BGRA, so malformed
//! alpha data is rejected before it reaches GDI.

use std::{fmt, time::Duration};

/// A tightly-described, premultiplied BGRA8 frame.
///
/// `stride` may include row padding. Only the first `width * 4` bytes of each
/// row are pixels; padding is ignored by the Windows presenter.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BgraFrame {
    width: u32,
    height: u32,
    stride: usize,
    pixels: Vec<u8>,
}

#[allow(clippy::missing_errors_doc)]
impl BgraFrame {
    /// Validates dimensions, byte layout, and premultiplied alpha channels.
    pub fn new(
        width: u32,
        height: u32,
        stride: usize,
        pixels: Vec<u8>,
    ) -> Result<Self, ProxyError> {
        if width == 0 || height == 0 {
            return Err(ProxyError::ZeroDimensions);
        }
        if width > i32::MAX as u32 || height > i32::MAX as u32 {
            return Err(ProxyError::DimensionsTooLarge);
        }
        let pixel_bytes = (width as usize)
            .checked_mul(4)
            .ok_or(ProxyError::FrameSizeOverflow)?;
        if stride < pixel_bytes {
            return Err(ProxyError::StrideTooSmall {
                minimum: pixel_bytes,
                actual: stride,
            });
        }
        let expected_len = stride
            .checked_mul(height as usize)
            .ok_or(ProxyError::FrameSizeOverflow)?;
        if pixels.len() != expected_len {
            return Err(ProxyError::LengthMismatch {
                expected: expected_len,
                actual: pixels.len(),
            });
        }

        for row in 0..height as usize {
            let row_start = row * stride;
            for column in 0..width as usize {
                let offset = row_start + column * 4;
                let blue = pixels[offset];
                let green = pixels[offset + 1];
                let red = pixels[offset + 2];
                let alpha = pixels[offset + 3];
                if blue > alpha || green > alpha || red > alpha {
                    return Err(ProxyError::NonPremultipliedPixel { row, column });
                }
            }
        }

        Ok(Self {
            width,
            height,
            stride,
            pixels,
        })
    }

    #[must_use]
    pub const fn width(&self) -> u32 {
        self.width
    }

    #[must_use]
    pub const fn height(&self) -> u32 {
        self.height
    }

    #[must_use]
    pub const fn stride(&self) -> usize {
        self.stride
    }

    #[must_use]
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
}

/// Errors from frame validation or the native proxy endpoint.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProxyError {
    ZeroDimensions,
    DimensionsTooLarge,
    FrameSizeOverflow,
    StrideTooSmall { minimum: usize, actual: usize },
    LengthMismatch { expected: usize, actual: usize },
    NonPremultipliedPixel { row: usize, column: usize },
    InvalidLogicalSize,
    TargetSurfaceTooLarge { bytes: usize, maximum: usize },
    TitleContainsNul,
    UnsupportedPlatform,
    WrongOwnerThread,
    WindowClosed,
    NativeCallFailed(&'static str),
}

impl fmt::Display for ProxyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroDimensions => formatter.write_str("BGRA frame dimensions must be non-zero"),
            Self::DimensionsTooLarge => {
                formatter.write_str("BGRA frame dimensions exceed Win32 i32 limits")
            }
            Self::FrameSizeOverflow => formatter.write_str("BGRA frame byte size overflows usize"),
            Self::StrideTooSmall { minimum, actual } => {
                write!(formatter, "BGRA stride {actual} is smaller than {minimum}")
            }
            Self::LengthMismatch { expected, actual } => write!(
                formatter,
                "BGRA payload is {actual} bytes; expected {expected}"
            ),
            Self::NonPremultipliedPixel { row, column } => write!(
                formatter,
                "BGRA pixel at row {row}, column {column} is not premultiplied"
            ),
            Self::InvalidLogicalSize => formatter
                .write_str("logical proxy dimensions must be finite, positive Win32 pixels"),
            Self::TargetSurfaceTooLarge { bytes, maximum } => write!(
                formatter,
                "proxy target surface requires {bytes} bytes; maximum is {maximum} bytes"
            ),
            Self::TitleContainsNul => formatter.write_str("window title contains a NUL character"),
            Self::UnsupportedPlatform => {
                formatter.write_str("Windows proxy presentation is only available on Windows")
            }
            Self::WrongOwnerThread => {
                formatter.write_str("Windows proxy used from a thread other than its owner")
            }
            Self::WindowClosed => formatter.write_str("Windows proxy window has been closed"),
            Self::NativeCallFailed(call) => write!(formatter, "Win32 call failed: {call}"),
        }
    }
}

impl std::error::Error for ProxyError {}

/// Opt-in timings for one native proxy presentation.
///
/// These durations exclude decoding and DPI lookup. They do not overlap:
/// `resample`, surface allocation, pixel copy, and the Win32 call are timed
/// independently.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PresentationTiming {
    /// Pixels submitted to `UpdateLayeredWindow`.
    pub target_pixels: (u32, u32),
    /// Window DPI used for a logical presentation; `None` for physical input.
    pub dpi: Option<u32>,
    /// CPU time to resample a logical presentation, zero for a same-size or
    /// physical-pixel presentation.
    pub resample: Duration,
    /// Time spent checking/replacing the backing DIB. Includes the size check
    /// even when the surface is reused.
    pub surface_allocation: Duration,
    /// Time spent copying BGRA rows into the backing DIB.
    pub pixel_copy: Duration,
    /// Time spent inside `UpdateLayeredWindow`.
    pub update_layered_window: Duration,
}

/// Converts logical DIPs to physical Win32 pixels at `dpi`.
///
/// This is platform-independent so callers and tests can validate scaling
/// decisions without constructing an HWND.
#[cfg_attr(not(windows), allow(dead_code))]
fn logical_pixels(width_dip: f64, height_dip: f64, dpi: u32) -> Result<(u32, u32), ProxyError> {
    if !width_dip.is_finite()
        || !height_dip.is_finite()
        || width_dip <= 0.0
        || height_dip <= 0.0
        || dpi == 0
    {
        return Err(ProxyError::InvalidLogicalSize);
    }
    let scale = f64::from(dpi) / 96.0;
    let width = (width_dip * scale).round();
    let height = (height_dip * scale).round();
    if !width.is_finite()
        || !height.is_finite()
        || width < 1.0
        || height < 1.0
        || width > f64::from(i32::MAX)
        || height > f64::from(i32::MAX)
    {
        return Err(ProxyError::InvalidLogicalSize);
    }
    // Bounds above make these casts lossless and within Win32's signed range.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    Ok((width as u32, height as u32))
}

/// Area-resamples a premultiplied BGRA frame without changing its alpha
/// representation. It works for both downscaling and upscaling; the output is
/// bounded by an explicit byte budget rather than by a fixed resolution cap.
#[cfg_attr(not(windows), allow(dead_code))]
#[allow(clippy::similar_names, clippy::too_many_lines)] // Paired X/Y bounds keep the two-axis resampling math readable.
fn resample_premultiplied(
    frame: &BgraFrame,
    target_width: u32,
    target_height: u32,
) -> Result<BgraFrame, ProxyError> {
    const MAX_TARGET_SURFACE_BYTES: usize = 256 * 1024 * 1024;
    if target_width == 0 || target_height == 0 {
        return Err(ProxyError::ZeroDimensions);
    }
    let row_bytes = (target_width as usize)
        .checked_mul(4)
        .ok_or(ProxyError::FrameSizeOverflow)?;
    let len = row_bytes
        .checked_mul(target_height as usize)
        .ok_or(ProxyError::FrameSizeOverflow)?;
    // A logical-size control plane must not turn a modest decoded frame into
    // an unbounded CPU allocation. This is deliberately a byte budget, not a
    // display-resolution ceiling; ordinary high-DPI 4K proxy frames fit.
    if len > MAX_TARGET_SURFACE_BYTES {
        return Err(ProxyError::TargetSurfaceTooLarge {
            bytes: len,
            maximum: MAX_TARGET_SURFACE_BYTES,
        });
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(len)
        .map_err(|_| ProxyError::FrameSizeOverflow)?;
    pixels.resize(len, 0);

    if target_width >= frame.width() && target_height >= frame.height() {
        // Pixel-center bilinear interpolation avoids the blocky appearance of
        // a box filter when a proxy moves to a higher-DPI display. Interpolate
        // premultiplied components directly; convex weights preserve each
        // component's <= alpha invariant.
        for target_y in 0..target_height {
            let source_y = ((f64::from(target_y) + 0.5) * f64::from(frame.height())
                / f64::from(target_height)
                - 0.5)
                .clamp(0.0, f64::from(frame.height() - 1));
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let y0 = source_y.floor() as u32;
            let y1 = (y0 + 1).min(frame.height() - 1);
            let vertical = source_y - f64::from(y0);
            for target_x in 0..target_width {
                let source_x = ((f64::from(target_x) + 0.5) * f64::from(frame.width())
                    / f64::from(target_width)
                    - 0.5)
                    .clamp(0.0, f64::from(frame.width() - 1));
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let x0 = source_x.floor() as u32;
                let x1 = (x0 + 1).min(frame.width() - 1);
                let horizontal = source_x - f64::from(x0);
                let output = target_y as usize * row_bytes + target_x as usize * 4;
                for channel in 0..4 {
                    let sample = |x, y| {
                        frame.pixels()[y as usize * frame.stride() + x as usize * 4 + channel]
                    };
                    let top = f64::from(sample(x0, y0)) * (1.0 - horizontal)
                        + f64::from(sample(x1, y0)) * horizontal;
                    let bottom = f64::from(sample(x0, y1)) * (1.0 - horizontal)
                        + f64::from(sample(x1, y1)) * horizontal;
                    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                    {
                        pixels[output + channel] = (top * (1.0 - vertical) + bottom * vertical)
                            .round()
                            .clamp(0.0, 255.0)
                            as u8;
                    }
                }
            }
        }
        return BgraFrame::new(target_width, target_height, row_bytes, pixels);
    }

    let source_width = u128::from(frame.width());
    let source_height = u128::from(frame.height());
    let target_width_u128 = u128::from(target_width);
    let target_height_u128 = u128::from(target_height);
    let denominator = source_width * source_height;
    for target_y in 0..target_height {
        let y0 = u128::from(target_y) * source_height;
        let y1 = u128::from(target_y + 1) * source_height;
        let source_y_start =
            u32::try_from(y0 / target_height_u128).map_err(|_| ProxyError::FrameSizeOverflow)?;
        let source_y_end = u32::try_from((y1 - 1) / target_height_u128)
            .map_err(|_| ProxyError::FrameSizeOverflow)?;
        for target_x in 0..target_width {
            let x0 = u128::from(target_x) * source_width;
            let x1 = u128::from(target_x + 1) * source_width;
            let source_x_start =
                u32::try_from(x0 / target_width_u128).map_err(|_| ProxyError::FrameSizeOverflow)?;
            let source_x_end = u32::try_from((x1 - 1) / target_width_u128)
                .map_err(|_| ProxyError::FrameSizeOverflow)?;
            let mut sums = [0_u128; 4];
            for source_y in source_y_start..=source_y_end {
                let source_y0 = u128::from(source_y) * target_height_u128;
                let source_y1 = u128::from(source_y + 1) * target_height_u128;
                let overlap_y = source_y1.min(y1) - source_y0.max(y0);
                for source_x in source_x_start..=source_x_end {
                    let source_x0 = u128::from(source_x) * target_width_u128;
                    let source_x1 = u128::from(source_x + 1) * target_width_u128;
                    let overlap_x = source_x1.min(x1) - source_x0.max(x0);
                    let weight = overlap_x * overlap_y;
                    let offset = source_y as usize * frame.stride() + source_x as usize * 4;
                    for (channel, sum) in sums.iter_mut().enumerate() {
                        *sum += u128::from(frame.pixels()[offset + channel]) * weight;
                    }
                }
            }
            let output = target_y as usize * row_bytes + target_x as usize * 4;
            for (channel, sum) in sums.into_iter().enumerate() {
                // Equal rounding on premultiplied components and alpha keeps
                // component <= alpha because each component sum <= alpha sum.
                pixels[output + channel] = u8::try_from((sum + denominator / 2) / denominator)
                    .map_err(|_| ProxyError::FrameSizeOverflow)?;
            }
        }
    }
    BgraFrame::new(target_width, target_height, row_bytes, pixels)
}

#[cfg(not(windows))]
/// Placeholder retaining a portable API while making presentation unavailable.
#[derive(Debug)]
pub struct WindowsProxy {
    _private: (),
}

#[cfg(not(windows))]
#[allow(clippy::missing_errors_doc)]
impl WindowsProxy {
    pub fn new(_title: &str, _x: i32, _y: i32) -> Result<Self, ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn present(&mut self, _frame: &BgraFrame) -> Result<(), ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn present_profiled(
        &mut self,
        _frame: &BgraFrame,
    ) -> Result<PresentationTiming, ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn present_logical(
        &mut self,
        _frame: &BgraFrame,
        _width_dip: f64,
        _height_dip: f64,
    ) -> Result<(), ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn present_logical_profiled(
        &mut self,
        _frame: &BgraFrame,
        _width_dip: f64,
        _height_dip: f64,
    ) -> Result<PresentationTiming, ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn dpi(&self) -> Result<u32, ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn move_to(&mut self, _x: i32, _y: i32) -> Result<(), ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }

    pub fn pump_events(&mut self) -> Result<bool, ProxyError> {
        Err(ProxyError::UnsupportedPlatform)
    }
}

#[cfg(windows)]
mod native {
    use std::{
        marker::PhantomData,
        ptr,
        rc::Rc,
        time::{Duration, Instant},
    };

    use windows_sys::Win32::{
        Foundation::{HWND, POINT, SIZE},
        Graphics::Gdi::{
            BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, CreateCompatibleDC,
            CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, HBITMAP, HDC, HGDIOBJ,
            SelectObject,
        },
        System::Threading::GetCurrentThreadId,
        UI::HiDpi::{
            DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForWindow,
            SetThreadDpiAwarenessContext,
        },
        UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, DispatchMessageW, IsWindow, MSG, PM_REMOVE,
            PeekMessageW, PostQuitMessage, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOSIZE,
            SWP_NOZORDER, SetWindowPos, ShowWindow, TranslateMessage, ULW_ALPHA,
            UpdateLayeredWindow, WM_QUIT, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
            WS_POPUP,
        },
    };

    use super::{
        BgraFrame, PresentationTiming, ProxyError, logical_pixels, resample_premultiplied,
    };

    const STATIC_CLASS: &[u16] = &[
        b'S' as u16,
        b'T' as u16,
        b'A' as u16,
        b'T' as u16,
        b'I' as u16,
        b'C' as u16,
        0,
    ];

    /// A non-activating, owner-thread Win32 layered proxy window.
    ///
    /// The `Rc` marker intentionally makes the handle neither `Send` nor
    /// `Sync`: HWND/GDI lifetime and its message queue remain on this thread.
    #[derive(Debug)]
    pub struct WindowsProxy {
        hwnd: HWND,
        memory_dc: HDC,
        bitmap: HBITMAP,
        previous_bitmap: HGDIOBJ,
        bits: *mut u8,
        surface_size: Option<(u32, u32)>,
        x: i32,
        y: i32,
        owner_thread: u32,
        _thread_bound: PhantomData<Rc<()>>,
    }

    #[allow(clippy::missing_errors_doc)]
    impl WindowsProxy {
        pub fn new(title: &str, x: i32, y: i32) -> Result<Self, ProxyError> {
            let title = wide_nul(title)?;
            let _dpi_context = DpiAwarenessGuard::per_monitor_v2()?;
            // `STATIC` is a system-owned window class, so no process-global
            // class registration/unregistration is needed for each proxy.
            #[allow(unsafe_code)]
            let hwnd = unsafe {
                CreateWindowExW(
                    WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                    STATIC_CLASS.as_ptr(),
                    title.as_ptr(),
                    WS_POPUP,
                    x,
                    y,
                    1,
                    1,
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null(),
                )
            };
            if hwnd.is_null() {
                return Err(ProxyError::NativeCallFailed("CreateWindowExW"));
            }
            #[allow(unsafe_code)]
            let memory_dc = unsafe { CreateCompatibleDC(ptr::null_mut()) };
            if memory_dc.is_null() {
                #[allow(unsafe_code)]
                unsafe {
                    DestroyWindow(hwnd)
                };
                return Err(ProxyError::NativeCallFailed("CreateCompatibleDC"));
            }
            #[allow(unsafe_code)]
            unsafe {
                ShowWindow(hwnd, SW_SHOWNOACTIVATE)
            };
            Ok(Self {
                hwnd,
                memory_dc,
                bitmap: ptr::null_mut(),
                previous_bitmap: ptr::null_mut(),
                bits: ptr::null_mut(),
                surface_size: None,
                x,
                y,
                owner_thread: current_thread_id(),
                _thread_bound: PhantomData,
            })
        }

        pub fn present(&mut self, frame: &BgraFrame) -> Result<(), ProxyError> {
            self.present_profiled(frame).map(|_| ())
        }

        /// Presents a physical-pixel frame and returns timings for its native
        /// submission stages. This does not emit logs or enable global state.
        pub fn present_profiled(
            &mut self,
            frame: &BgraFrame,
        ) -> Result<PresentationTiming, ProxyError> {
            self.present_profiled_with_dpi(frame, None, Duration::ZERO)
        }

        fn present_profiled_with_dpi(
            &mut self,
            frame: &BgraFrame,
            dpi: Option<u32>,
            resample: Duration,
        ) -> Result<PresentationTiming, ProxyError> {
            self.ensure_owner_and_open()?;
            let allocation_started = Instant::now();
            if self.surface_size != Some((frame.width(), frame.height())) {
                self.create_surface(frame.width(), frame.height())?;
            }
            let surface_allocation = allocation_started.elapsed();
            let row_bytes = frame.width() as usize * 4;
            let width = i32::try_from(frame.width()).map_err(|_| ProxyError::DimensionsTooLarge)?;
            let height =
                i32::try_from(frame.height()).map_err(|_| ProxyError::DimensionsTooLarge)?;
            let copy_started = Instant::now();
            #[allow(unsafe_code)]
            unsafe {
                for row in 0..frame.height() as usize {
                    ptr::copy_nonoverlapping(
                        frame.pixels().as_ptr().add(row * frame.stride()),
                        self.bits.add(row * row_bytes),
                        row_bytes,
                    );
                }
            }
            let pixel_copy = copy_started.elapsed();

            let destination = POINT {
                x: self.x,
                y: self.y,
            };
            let size = SIZE {
                cx: width,
                cy: height,
            };
            let source = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION {
                BlendOp: 0,
                BlendFlags: 0,
                SourceConstantAlpha: u8::MAX,
                AlphaFormat: 1,
            };
            let _dpi_context = DpiAwarenessGuard::per_monitor_v2()?;
            let update_started = Instant::now();
            #[allow(unsafe_code)]
            let updated = unsafe {
                UpdateLayeredWindow(
                    self.hwnd,
                    ptr::null_mut(),
                    &raw const destination,
                    &raw const size,
                    self.memory_dc,
                    &raw const source,
                    0,
                    &raw const blend,
                    ULW_ALPHA,
                )
            };
            let update_layered_window = update_started.elapsed();
            if updated == 0 {
                return Err(ProxyError::NativeCallFailed("UpdateLayeredWindow"));
            }
            Ok(PresentationTiming {
                target_pixels: (frame.width(), frame.height()),
                dpi,
                resample,
                surface_allocation,
                pixel_copy,
                update_layered_window,
            })
        }

        /// Presents `frame` at a logical DIPs size for the monitor currently
        /// hosting this window. The target DPI is queried for every frame, so
        /// moving the proxy across monitors takes effect on the next present.
        pub fn present_logical(
            &mut self,
            frame: &BgraFrame,
            width_dip: f64,
            height_dip: f64,
        ) -> Result<(), ProxyError> {
            self.present_logical_profiled(frame, width_dip, height_dip)
                .map(|_| ())
        }

        /// Presents at a logical DIPs size and returns native submission
        /// timings. DPI lookup is intentionally excluded; CPU resampling is
        /// reported separately from the native submission stages.
        pub fn present_logical_profiled(
            &mut self,
            frame: &BgraFrame,
            width_dip: f64,
            height_dip: f64,
        ) -> Result<PresentationTiming, ProxyError> {
            self.ensure_owner_and_open()?;
            let dpi = self.dpi()?;
            let target = logical_pixels(width_dip, height_dip, dpi)?;
            if target == (frame.width(), frame.height()) {
                return self.present_profiled_with_dpi(frame, Some(dpi), Duration::ZERO);
            }
            let resample_started = Instant::now();
            let scaled = resample_premultiplied(frame, target.0, target.1)?;
            self.present_profiled_with_dpi(&scaled, Some(dpi), resample_started.elapsed())
        }

        /// Returns the DPI currently assigned to this proxy's window.
        pub fn dpi(&self) -> Result<u32, ProxyError> {
            self.ensure_owner_and_open()?;
            let _dpi_context = DpiAwarenessGuard::per_monitor_v2()?;
            #[allow(unsafe_code)]
            let dpi = unsafe { GetDpiForWindow(self.hwnd) };
            if dpi == 0 {
                return Err(ProxyError::NativeCallFailed("GetDpiForWindow"));
            }
            Ok(dpi)
        }

        pub fn move_to(&mut self, x: i32, y: i32) -> Result<(), ProxyError> {
            self.ensure_owner_and_open()?;
            let _dpi_context = DpiAwarenessGuard::per_monitor_v2()?;
            #[allow(unsafe_code)]
            let moved = unsafe {
                SetWindowPos(
                    self.hwnd,
                    ptr::null_mut(),
                    x,
                    y,
                    0,
                    0,
                    SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER,
                )
            };
            if moved == 0 {
                return Err(ProxyError::NativeCallFailed("SetWindowPos"));
            }
            self.x = x;
            self.y = y;
            Ok(())
        }

        /// Dispatches pending messages for the owner thread.
        ///
        /// Returns `false` if this proxy was closed or the thread received
        /// `WM_QUIT`. It never posts `WM_QUIT` while dropping one proxy.
        pub fn pump_events(&mut self) -> Result<bool, ProxyError> {
            self.ensure_owner()?;
            if !self.is_open() {
                return Ok(false);
            }
            loop {
                let mut message = MSG::default();
                #[allow(unsafe_code)]
                let has_message =
                    unsafe { PeekMessageW(&raw mut message, ptr::null_mut(), 0, 0, PM_REMOVE) };
                if has_message == 0 {
                    return Ok(self.is_open());
                }
                if message.message == WM_QUIT {
                    // `WM_QUIT` is thread-wide rather than window-specific.
                    // Put it back for an outer application loop; dropping this
                    // proxy never posts a quit message of its own.
                    #[allow(
                        unsafe_code,
                        clippy::cast_possible_truncation,
                        clippy::cast_possible_wrap
                    )]
                    unsafe {
                        PostQuitMessage(message.wParam as i32);
                    }
                    return Ok(false);
                }
                #[allow(unsafe_code)]
                unsafe {
                    TranslateMessage(&raw const message);
                    DispatchMessageW(&raw const message);
                }
                if !self.is_open() {
                    return Ok(false);
                }
            }
        }

        fn create_surface(&mut self, width: u32, height: u32) -> Result<(), ProxyError> {
            self.release_surface();
            let width_i32 = i32::try_from(width).map_err(|_| ProxyError::DimensionsTooLarge)?;
            let height_i32 = i32::try_from(height).map_err(|_| ProxyError::DimensionsTooLarge)?;
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: 40,
                    biWidth: width_i32,
                    // A negative height makes the DIB top-down, matching frame rows.
                    biHeight: -height_i32,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB,
                    ..BITMAPINFOHEADER::default()
                },
                ..BITMAPINFO::default()
            };
            let mut bits = ptr::null_mut();
            #[allow(unsafe_code)]
            let bitmap = unsafe {
                CreateDIBSection(
                    self.memory_dc,
                    &raw const info,
                    DIB_RGB_COLORS,
                    &raw mut bits,
                    ptr::null_mut(),
                    0,
                )
            };
            if bitmap.is_null() || bits.is_null() {
                if !bitmap.is_null() {
                    #[allow(unsafe_code)]
                    unsafe {
                        DeleteObject(bitmap);
                    }
                }
                return Err(ProxyError::NativeCallFailed("CreateDIBSection"));
            }
            #[allow(unsafe_code)]
            let previous_bitmap = unsafe { SelectObject(self.memory_dc, bitmap) };
            if previous_bitmap.is_null() || previous_bitmap == (-1_isize) as HGDIOBJ {
                #[allow(unsafe_code)]
                unsafe {
                    DeleteObject(bitmap)
                };
                return Err(ProxyError::NativeCallFailed("SelectObject"));
            }
            self.bitmap = bitmap;
            self.previous_bitmap = previous_bitmap;
            self.bits = bits.cast();
            self.surface_size = Some((width, height));
            Ok(())
        }

        fn ensure_owner(&self) -> Result<(), ProxyError> {
            if current_thread_id() != self.owner_thread {
                return Err(ProxyError::WrongOwnerThread);
            }
            Ok(())
        }

        fn ensure_owner_and_open(&self) -> Result<(), ProxyError> {
            self.ensure_owner()?;
            if !self.is_open() {
                return Err(ProxyError::WindowClosed);
            }
            Ok(())
        }

        fn is_open(&self) -> bool {
            !self.hwnd.is_null() && is_window(self.hwnd)
        }

        fn release_surface(&mut self) {
            if !self.bitmap.is_null() {
                #[allow(unsafe_code)]
                unsafe {
                    SelectObject(self.memory_dc, self.previous_bitmap);
                    DeleteObject(self.bitmap);
                }
            }
            self.bitmap = ptr::null_mut();
            self.previous_bitmap = ptr::null_mut();
            self.bits = ptr::null_mut();
            self.surface_size = None;
        }
    }

    /// Restores the calling thread's prior DPI awareness when it leaves scope.
    /// This deliberately avoids the process-wide DPI APIs: the embedding host
    /// may own windows with a different awareness policy.
    struct DpiAwarenessGuard(DPI_AWARENESS_CONTEXT);

    impl DpiAwarenessGuard {
        fn per_monitor_v2() -> Result<Self, ProxyError> {
            #[allow(unsafe_code)]
            let previous =
                unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
            if previous.is_null() {
                return Err(ProxyError::NativeCallFailed("SetThreadDpiAwarenessContext"));
            }
            Ok(Self(previous))
        }
    }

    impl Drop for DpiAwarenessGuard {
        fn drop(&mut self) {
            #[allow(unsafe_code)]
            unsafe {
                SetThreadDpiAwarenessContext(self.0);
            }
        }
    }

    impl Drop for WindowsProxy {
        fn drop(&mut self) {
            if current_thread_id() != self.owner_thread {
                return;
            }
            self.release_surface();
            if !self.memory_dc.is_null() {
                #[allow(unsafe_code)]
                unsafe {
                    DeleteDC(self.memory_dc)
                };
                self.memory_dc = ptr::null_mut();
            }
            if !self.hwnd.is_null() && is_window(self.hwnd) {
                #[allow(unsafe_code)]
                unsafe {
                    DestroyWindow(self.hwnd)
                };
            }
            self.hwnd = ptr::null_mut();
        }
    }

    fn wide_nul(value: &str) -> Result<Vec<u16>, ProxyError> {
        if value.encode_utf16().any(|unit| unit == 0) {
            return Err(ProxyError::TitleContainsNul);
        }
        Ok(value.encode_utf16().chain(std::iter::once(0)).collect())
    }

    fn current_thread_id() -> u32 {
        #[allow(unsafe_code)]
        unsafe {
            GetCurrentThreadId()
        }
    }

    fn is_window(hwnd: HWND) -> bool {
        #[allow(unsafe_code)]
        unsafe {
            IsWindow(hwnd) != 0
        }
    }
}

#[cfg(windows)]
pub use native::WindowsProxy;

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{
        BgraFrame, PresentationTiming, ProxyError, logical_pixels, resample_premultiplied,
    };

    #[test]
    fn presentation_timing_keeps_stage_durations_separate() {
        let timing = PresentationTiming {
            target_pixels: (1_556, 1_300),
            dpi: Some(192),
            resample: Duration::ZERO,
            surface_allocation: Duration::from_millis(1),
            pixel_copy: Duration::from_millis(2),
            update_layered_window: Duration::from_millis(3),
        };
        assert_eq!(timing.target_pixels, (1_556, 1_300));
        assert_eq!(timing.dpi, Some(192));
        assert_eq!(timing.resample, Duration::ZERO);
        assert_eq!(timing.pixel_copy, Duration::from_millis(2));
    }

    #[test]
    fn accepts_premultiplied_bgra_with_padding() {
        let frame = BgraFrame::new(
            1,
            2,
            8,
            vec![10, 20, 30, 30, 0, 0, 0, 0, 1, 2, 3, 3, 0, 0, 0, 0],
        );
        assert!(frame.is_ok());
    }

    #[test]
    fn rejects_short_stride() {
        let error = BgraFrame::new(2, 1, 7, vec![0; 7]).unwrap_err();
        assert_eq!(
            error,
            ProxyError::StrideTooSmall {
                minimum: 8,
                actual: 7
            }
        );
    }

    #[test]
    fn rejects_payload_length_mismatch() {
        let error = BgraFrame::new(1, 2, 4, vec![0; 7]).unwrap_err();
        assert_eq!(
            error,
            ProxyError::LengthMismatch {
                expected: 8,
                actual: 7
            }
        );
    }

    #[test]
    fn rejects_straight_alpha_pixels() {
        let error = BgraFrame::new(1, 1, 4, vec![1, 0, 0, 0]).unwrap_err();
        assert_eq!(
            error,
            ProxyError::NonPremultipliedPixel { row: 0, column: 0 }
        );
    }

    #[test]
    fn logical_dimensions_follow_window_dpi() {
        assert_eq!(logical_pixels(282.0, 131.0, 96), Ok((282, 131)));
        assert_eq!(logical_pixels(282.0, 131.0, 192), Ok((564, 262)));
    }

    #[test]
    fn logical_dimensions_reject_non_finite_and_overflowing_values() {
        assert_eq!(
            logical_pixels(f64::NAN, 1.0, 96),
            Err(ProxyError::InvalidLogicalSize)
        );
        assert_eq!(
            logical_pixels(1.0, f64::INFINITY, 96),
            Err(ProxyError::InvalidLogicalSize)
        );
        assert_eq!(
            logical_pixels(f64::MAX, 1.0, 96),
            Err(ProxyError::InvalidLogicalSize)
        );
    }

    #[test]
    fn area_downsample_preserves_premultiplied_alpha() {
        let frame = BgraFrame::new(
            2,
            2,
            8,
            vec![20, 10, 0, 20, 40, 20, 10, 40, 60, 30, 0, 60, 80, 40, 20, 80],
        )
        .unwrap();
        let output = resample_premultiplied(&frame, 1, 1).unwrap();
        assert_eq!(output.pixels(), &[50, 25, 8, 50]);
        assert!(
            output.pixels().chunks_exact(4).all(|pixel| {
                pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]
            })
        );
    }

    #[test]
    fn area_downsample_uses_fractional_coverage() {
        let frame = BgraFrame::new(
            3,
            1,
            12,
            vec![0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255],
        )
        .unwrap();
        let output = resample_premultiplied(&frame, 2, 1).unwrap();
        assert_eq!(output.pixels(), &[85, 85, 85, 255, 85, 85, 85, 255]);
    }

    #[test]
    fn area_resample_supports_higher_target_dpi() {
        let frame = BgraFrame::new(2, 1, 8, vec![0, 0, 0, 100, 100, 50, 0, 100]).unwrap();
        let output = resample_premultiplied(&frame, 4, 1).unwrap();
        assert_eq!(
            output.pixels(),
            &[
                0, 0, 0, 100, 25, 13, 0, 100, 75, 38, 0, 100, 100, 50, 0, 100
            ]
        );
        assert!(
            output.pixels().chunks_exact(4).all(|pixel| {
                pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]
            })
        );
    }
}
