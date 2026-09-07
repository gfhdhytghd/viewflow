#![allow(unsafe_code)]

use std::{
    collections::BTreeSet,
    ffi::{OsStr, c_void},
    fs::File,
    io::{BufReader, Read, Write},
    mem::size_of,
    os::windows::{ffi::OsStrExt, io::FromRawHandle},
    path::{Path, PathBuf},
    ptr::null_mut,
    thread::{self, sleep},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use sha2::{Digest, Sha256};
use viewflow_platform::windows_input::{
    ForceReleaseReport, WindowsScanCode, force_release_all_supported, force_release_scan_codes,
};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, CompareObjectHandles, FILETIME, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
        LocalFree, SYSTEMTIME,
    },
    Security::{
        Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
            SDDL_REVISION_1,
        },
        GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER,
        TokenUser,
    },
    Storage::FileSystem::{
        CREATE_NEW, CreateFileW, FILE_ATTRIBUTE_NORMAL, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    },
    System::{
        RemoteDesktop::ProcessIdToSessionId,
        StationsAndDesktops::{
            CloseDesktop, DESKTOP_READOBJECTS, GetThreadDesktop, GetUserObjectInformationW, HDESK,
            OpenInputDesktop, SetThreadDesktop, UOI_NAME,
        },
        SystemInformation::GetSystemTime,
        Threading::{
            GetCurrentProcess, GetCurrentProcessId, GetCurrentThreadId, GetProcessTimes,
            OpenProcessToken,
        },
    },
    UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, MAPVK_VSC_TO_VK_EX, MapVirtualKeyW, VK_CONVERT, VK_KANA, VK_LBUTTON,
        VK_MBUTTON, VK_NONCONVERT, VK_NUMLOCK, VK_OEM_5, VK_OEM_102, VK_OEM_NEC_EQUAL, VK_RBUTTON,
        VK_SEPARATOR, VK_XBUTTON1, VK_XBUTTON2,
    },
};

const REQUIRED_SESSION_ID: u32 = 1;
const REQUIRED_INPUT_COUNT: u32 = 135;
const VERIFICATION_STABLE: Duration = Duration::from_millis(500);
const VERIFICATION_TIMEOUT: Duration = Duration::from_secs(3);
const VERIFICATION_POLL: Duration = Duration::from_millis(10);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ForceReleaseInputConfig {
    pub receipt: PathBuf,
    pub operation_id: String,
    pub linux_frozen_evidence_sha256: String,
}

#[derive(Debug, Serialize)]
struct ForceReleaseReceipt<'a> {
    schema_version: u32,
    state: &'static str,
    operation_id: &'a str,
    linux_frozen_evidence_sha256: &'a str,
    tool_executable_sha256: String,
    tool_pid: u32,
    tool_process_start_filetime: String,
    tool_session_id: u32,
    tool_user_sid: String,
    input_desktop: String,
    requested_input_count: u32,
    inserted_input_count: u32,
    verification_stable_ms: u64,
    completed_at_utc: String,
}

/// Releases the complete supported input domain and publishes a create-once
/// completion receipt after Windows reports every input continuously up.
pub fn force_release_input(config: &ForceReleaseInputConfig) -> Result<()> {
    super::validate_lower_sha256(
        &config.linux_frozen_evidence_sha256,
        "frozen Linux evidence SHA-256 in force-release configuration",
    )?;
    validate_receipt_target(&config.receipt)?;

    let pid = current_pid();
    let session_id = current_session_id(pid)?;
    require_session_one(session_id)?;
    let process_start_filetime = current_process_start_filetime()?;
    let user_sid = current_user_sid()?;
    let executable = std::env::current_exe().context("failed to locate running viewflowd")?;
    let executable_sha256 = sha256_path(&executable)?;
    let input_desktop = InputDesktop::open()?;
    let input_desktop_name = input_desktop.name.clone();
    let desktop_handle_address = input_desktop.handle as usize;
    let worker = thread::Builder::new()
        .name("viewflow-force-release-input".into())
        .spawn(move || {
            // SAFETY: the owning thread retains the desktop handle until this
            // worker has terminated and joined.
            let desktop_handle = desktop_handle_address as HDESK;
            release_and_verify_on_bound_desktop(desktop_handle)
        });
    let release_result = match worker {
        Ok(worker) => worker
            .join()
            .map_err(|_| anyhow!("force-release input desktop thread panicked"))
            .and_then(|result| result),
        Err(error) => Err(anyhow!(error).context("failed to start force-release input thread")),
    };
    let close_result = input_desktop.close();
    let report = match (release_result, close_result) {
        (Ok(report), Ok(())) => report,
        (Err(error), Ok(())) => return Err(error),
        (Ok(_), Err(error)) => return Err(error),
        (Err(operation_error), Err(close_error)) => {
            return Err(anyhow!(
                "{operation_error:#}; additionally failed to close pinned input desktop: {close_error:#}"
            ));
        }
    };

    let receipt = ForceReleaseReceipt {
        schema_version: 3,
        state: "viewflow-force-release-completed",
        operation_id: &config.operation_id,
        linux_frozen_evidence_sha256: &config.linux_frozen_evidence_sha256,
        tool_executable_sha256: executable_sha256,
        tool_pid: pid,
        tool_process_start_filetime: process_start_filetime.to_string(),
        tool_session_id: session_id,
        tool_user_sid: user_sid.clone(),
        input_desktop: input_desktop_name,
        requested_input_count: report.requested_input_count,
        inserted_input_count: report.inserted_input_count,
        verification_stable_ms: u64::try_from(VERIFICATION_STABLE.as_millis()).unwrap(),
        completed_at_utc: completed_at_utc(),
    };
    write_owner_only_receipt(&config.receipt, &user_sid, &receipt)
}

fn release_and_verify_on_bound_desktop(desktop: HDESK) -> Result<ForceReleaseReport> {
    bind_thread_to_desktop(desktop)?;
    ensure_bound_input_desktop(desktop)?;

    let virtual_keys = verification_virtual_keys(&force_release_scan_codes())?;
    ensure_bound_input_desktop(desktop)?;
    let report = force_release_all_supported()
        .map_err(|error| anyhow!("stateless Windows input release failed: {error:?}"))?;
    ensure_bound_input_desktop(desktop)?;
    require_complete_batch(report)?;
    verify_all_up(&virtual_keys, desktop)?;
    ensure_bound_input_desktop(desktop)?;
    Ok(report)
}

fn validate_receipt_target(path: &Path) -> Result<()> {
    if path.file_name().is_none() {
        bail!("receipt path must name a file: {}", path.display());
    }
    match path.symlink_metadata() {
        Ok(_) => bail!("receipt already exists: {}", path.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect receipt {}", path.display()));
        }
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let metadata = parent
        .metadata()
        .with_context(|| format!("failed to inspect receipt directory {}", parent.display()))?;
    if !metadata.is_dir() {
        bail!("receipt parent is not a directory: {}", parent.display());
    }
    Ok(())
}

fn current_pid() -> u32 {
    // SAFETY: GetCurrentProcessId has no preconditions.
    unsafe { GetCurrentProcessId() }
}

fn current_session_id(pid: u32) -> Result<u32> {
    let mut session_id = 0;
    // SAFETY: `session_id` is valid writable storage for the duration of the call.
    if unsafe { ProcessIdToSessionId(pid, &mut session_id) } == 0 {
        return Err(std::io::Error::last_os_error()).context("ProcessIdToSessionId failed");
    }
    Ok(session_id)
}

fn require_session_one(session_id: u32) -> Result<()> {
    if session_id != REQUIRED_SESSION_ID {
        bail!("force-release-input requires Windows Session 1; current session is {session_id}");
    }
    Ok(())
}

fn current_process_start_filetime() -> Result<u64> {
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // SAFETY: the pseudo handle is valid and all FILETIME pointers are writable.
    if unsafe {
        GetProcessTimes(
            GetCurrentProcess(),
            &mut creation,
            &mut exit,
            &mut kernel,
            &mut user,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error()).context("GetProcessTimes failed");
    }
    Ok(filetime_value(creation))
}

fn filetime_value(value: FILETIME) -> u64 {
    (u64::from(value.dwHighDateTime) << 32) | u64::from(value.dwLowDateTime)
}

fn current_user_sid() -> Result<String> {
    let mut token = null_mut();
    // SAFETY: `token` is writable and the pseudo process handle is valid.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(std::io::Error::last_os_error()).context("OpenProcessToken failed");
    }
    let token = OwnedHandle(token);

    let mut required = 0;
    // SAFETY: a null information buffer with zero length is the documented
    // size-query form. `required` is writable.
    unsafe {
        GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut required);
    }
    if required < u32::try_from(size_of::<TOKEN_USER>()).unwrap() {
        bail!("GetTokenInformation returned an invalid TokenUser size");
    }
    let word_size = size_of::<usize>();
    let words = usize::try_from(required)
        .context("TokenUser size does not fit usize")?
        .div_ceil(word_size);
    let mut buffer = vec![0_usize; words];
    // SAFETY: the aligned buffer has at least `required` bytes and remains
    // alive while the returned TOKEN_USER and SID are inspected.
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            required,
            &mut required,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error()).context("GetTokenInformation failed");
    }
    // SAFETY: GetTokenInformation initialized TOKEN_USER at the aligned start
    // of `buffer`, and its SID remains owned by that live buffer.
    let sid = unsafe { (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid };
    let mut sid_string = null_mut();
    // SAFETY: `sid` is valid and `sid_string` receives LocalAlloc-owned text.
    if unsafe { ConvertSidToStringSidW(sid, &mut sid_string) } == 0 {
        return Err(std::io::Error::last_os_error()).context("ConvertSidToStringSidW failed");
    }
    let sid_string = LocalAllocation(sid_string.cast());
    wide_ptr_to_string(sid_string.0.cast())
}

fn sha256_path(path: &Path) -> Result<String> {
    let file = File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let mut reader = BufReader::new(file);
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = reader
            .read(&mut buffer)
            .with_context(|| format!("failed to read {}", path.display()))?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    let digest = digest.finalize();
    Ok(format!("{digest:x}"))
}

struct InputDesktop {
    handle: HDESK,
    name: String,
}

impl InputDesktop {
    fn open() -> Result<Self> {
        // SAFETY: arguments request a non-inheritable handle to the current
        // session's input desktop.  GENERIC_WRITE intentionally maps to the
        // complete desktop write-right set; SetThreadDesktop makes subsequent
        // input operations use the rights granted to this handle.
        let handle = unsafe { OpenInputDesktop(0, 0, DESKTOP_READOBJECTS | GENERIC_WRITE) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error()).context("OpenInputDesktop failed");
        }
        match desktop_name(handle) {
            Ok(name) if name == "Default" => Ok(Self { handle, name }),
            Ok(name) => {
                // SAFETY: `handle` was returned by OpenInputDesktop.
                unsafe { CloseDesktop(handle) };
                bail!(
                    "force-release-input requires the interactive Default desktop; current input desktop is {name:?}"
                )
            }
            Err(error) => {
                // SAFETY: `handle` was returned by OpenInputDesktop.
                unsafe { CloseDesktop(handle) };
                Err(error)
            }
        }
    }

    fn close(mut self) -> Result<()> {
        let handle = std::mem::replace(&mut self.handle, null_mut());
        // SAFETY: the desktop worker has terminated, so this owned handle is
        // no longer assigned to a live thread.
        if unsafe { CloseDesktop(handle) } == 0 {
            return Err(std::io::Error::last_os_error()).context("CloseDesktop failed");
        }
        Ok(())
    }
}

impl Drop for InputDesktop {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            // SAFETY: this fallback owns the handle and runs only when the
            // checked close path was not consumed.
            unsafe { CloseDesktop(self.handle) };
        }
    }
}

fn bind_thread_to_desktop(expected: HDESK) -> Result<()> {
    // SAFETY: `expected` remains open in the owning thread until this fresh
    // worker has terminated and joined.
    if unsafe { SetThreadDesktop(expected) } == 0 {
        return Err(std::io::Error::last_os_error()).context("SetThreadDesktop failed");
    }
    ensure_thread_desktop(expected)
}

fn ensure_thread_desktop(expected: HDESK) -> Result<()> {
    // SAFETY: GetCurrentThreadId has no preconditions and the returned desktop
    // handle is borrowed from Windows for the lifetime of the thread.
    let current = unsafe { GetThreadDesktop(GetCurrentThreadId()) };
    if current.is_null() {
        return Err(std::io::Error::last_os_error()).context("GetThreadDesktop failed");
    }
    ensure_same_desktop(expected, current, "thread desktop")
}

fn ensure_bound_input_desktop(expected: HDESK) -> Result<()> {
    ensure_thread_desktop(expected)?;
    let current_input = InputDesktop::open()?;
    let identity_result = ensure_same_desktop(expected, current_input.handle, "input desktop");
    let close_result = current_input.close();
    identity_result?;
    close_result
}

fn ensure_same_desktop(expected: HDESK, actual: HDESK, context: &str) -> Result<()> {
    // SAFETY: both handles are live desktop handles while this comparison runs.
    if unsafe { CompareObjectHandles(expected.cast(), actual.cast()) } == 0 {
        bail!("{context} is not the pinned interactive Default desktop");
    }
    Ok(())
}

fn desktop_name(handle: HDESK) -> Result<String> {
    let mut required_bytes = 0;
    // SAFETY: this is the documented size-query form and `required_bytes` is writable.
    unsafe {
        GetUserObjectInformationW(handle.cast(), UOI_NAME, null_mut(), 0, &mut required_bytes);
    }
    if required_bytes < 2 || required_bytes % 2 != 0 {
        bail!("GetUserObjectInformationW returned an invalid desktop name size");
    }
    let mut buffer = vec![0_u16; usize::try_from(required_bytes / 2).unwrap()];
    // SAFETY: the buffer contains `required_bytes` writable bytes and the
    // desktop handle stays live for the call.
    if unsafe {
        GetUserObjectInformationW(
            handle.cast(),
            UOI_NAME,
            buffer.as_mut_ptr().cast(),
            required_bytes,
            &mut required_bytes,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error())
            .context("GetUserObjectInformationW(UOI_NAME) failed");
    }
    let length = buffer
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(buffer.len());
    String::from_utf16(&buffer[..length]).context("input desktop name is not valid UTF-16")
}

fn verification_virtual_keys(scan_codes: &[WindowsScanCode]) -> Result<Vec<i32>> {
    let mut keys = BTreeSet::new();
    for scan_code in scan_codes {
        let mapped_scan = if scan_code.extended {
            0xe000 | u32::from(scan_code.code)
        } else {
            u32::from(scan_code.code)
        };
        // SAFETY: MapVirtualKeyW accepts every u32 code and has no pointer arguments.
        let mapped_virtual_key = unsafe { MapVirtualKeyW(mapped_scan, MAPVK_VSC_TO_VK_EX) };
        // Some physical keys have stable Win32 VK identities but are absent
        // from the active keyboard layout's scan-code map. Keep those
        // identities exact; a generic non-extended fallback could
        // misidentify unrelated E0 keys such as PrintScreen.
        let virtual_key = if mapped_virtual_key == 0 {
            explicit_layout_independent_virtual_key(*scan_code).map_or(0, u32::from)
        } else {
            mapped_virtual_key
        };
        if virtual_key == 0 {
            bail!(
                "MapVirtualKeyW failed for scan code {:#04x} (extended={})",
                scan_code.code,
                scan_code.extended
            );
        }
        keys.insert(i32::try_from(virtual_key).context("virtual key does not fit i32")?);
    }
    keys.extend([
        i32::from(VK_LBUTTON),
        i32::from(VK_MBUTTON),
        i32::from(VK_RBUTTON),
        i32::from(VK_XBUTTON1),
        i32::from(VK_XBUTTON2),
    ]);
    Ok(keys.into_iter().collect())
}

fn explicit_layout_independent_virtual_key(scan_code: WindowsScanCode) -> Option<u16> {
    match (scan_code.code, scan_code.extended) {
        (0x45, true) => Some(VK_NUMLOCK),
        (0x59, false) => Some(VK_OEM_NEC_EQUAL),
        (0x5c, false) => Some(VK_SEPARATOR),
        (0x70, false) => Some(VK_KANA),
        (0x73, false) => Some(VK_OEM_102),
        (0x79, false) => Some(VK_CONVERT),
        (0x7b, false) => Some(VK_NONCONVERT),
        (0x7d, false) => Some(VK_OEM_5),
        _ => None,
    }
}

fn verify_all_up(virtual_keys: &[i32], desktop: HDESK) -> Result<()> {
    let started = Instant::now();
    let deadline = started + VERIFICATION_TIMEOUT;
    let mut stable_since = None;
    loop {
        ensure_bound_input_desktop(desktop)?;
        let now = Instant::now();
        let all_up = virtual_keys.iter().all(|virtual_key| {
            // SAFETY: GetAsyncKeyState accepts every virtual-key integer and
            // has no pointer arguments. Only the held-state high bit is used.
            unsafe { GetAsyncKeyState(*virtual_key) & i16::MIN == 0 }
        });
        ensure_bound_input_desktop(desktop)?;
        if verification_complete(&mut stable_since, now, all_up) {
            ensure_bound_input_desktop(desktop)?;
            return Ok(());
        }
        if now >= deadline {
            bail!(
                "input state did not remain fully up for {} ms within {} ms",
                VERIFICATION_STABLE.as_millis(),
                VERIFICATION_TIMEOUT.as_millis()
            );
        }
        sleep(VERIFICATION_POLL);
    }
}

fn verification_complete(stable_since: &mut Option<Instant>, now: Instant, all_up: bool) -> bool {
    if !all_up {
        *stable_since = None;
        return false;
    }
    let start = stable_since.get_or_insert(now);
    now.duration_since(*start) >= VERIFICATION_STABLE
}

fn require_complete_batch(report: ForceReleaseReport) -> Result<()> {
    if report.requested_input_count != REQUIRED_INPUT_COUNT
        || report.inserted_input_count != REQUIRED_INPUT_COUNT
    {
        bail!(
            "incomplete stateless input release: requested {}, inserted {}, expected {REQUIRED_INPUT_COUNT}",
            report.requested_input_count,
            report.inserted_input_count
        );
    }
    Ok(())
}

fn completed_at_utc() -> String {
    let mut now = SYSTEMTIME::default();
    // SAFETY: `now` is writable and GetSystemTime has no failure mode.
    unsafe { GetSystemTime(&mut now) };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
    )
}

fn write_owner_only_receipt(
    path: &Path,
    sid: &str,
    receipt: &ForceReleaseReceipt<'_>,
) -> Result<()> {
    validate_receipt_target(path)?;
    let mut bytes =
        serde_json::to_vec_pretty(receipt).context("failed to serialize force-release receipt")?;
    bytes.push(b'\n');
    let descriptor = SecurityDescriptor::for_sid(sid)?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .expect("validated receipt path has a file name")
        .to_string_lossy();

    let (temporary, mut file) = (0..64_u32)
        .find_map(|attempt| {
            let candidate = parent.join(format!(".{name}.{}.{attempt}.tmp", current_pid()));
            match create_owner_only_new_file(&candidate, descriptor.0) {
                Ok(file) => Some(Ok((candidate, file))),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => None,
                Err(error) => Some(Err(error)),
            }
        })
        .transpose()
        .context("failed to create owner-only temporary receipt")?
        .ok_or_else(|| anyhow!("could not allocate a unique temporary receipt name"))?;

    let write_result = (|| -> Result<()> {
        file.write_all(&bytes)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to flush {}", temporary.display()))?;
        drop(file);
        move_without_replace(&temporary, path)
    })();
    if write_result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    write_result
}

fn create_owner_only_new_file(
    path: &Path,
    descriptor: PSECURITY_DESCRIPTOR,
) -> std::io::Result<File> {
    let wide_path = wide_null(path.as_os_str());
    let attributes = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>()).unwrap(),
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    // SAFETY: the path and SECURITY_ATTRIBUTES remain valid for the call; a
    // successful handle is uniquely owned and immediately transferred to File.
    let handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            GENERIC_WRITE,
            0,
            &attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: CreateFileW returned a new owned file handle compatible with File.
    Ok(unsafe { File::from_raw_handle(handle) })
}

fn move_without_replace(source: &Path, destination: &Path) -> Result<()> {
    let source = wide_null(source.as_os_str());
    let destination = wide_null(destination.as_os_str());
    // SAFETY: both paths are valid null-terminated UTF-16 strings. Omitting
    // MOVEFILE_REPLACE_EXISTING makes publication create-once/fail-closed.
    if unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error())
            .context("failed to publish force-release receipt without replacement");
    }
    Ok(())
}

struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

impl SecurityDescriptor {
    fn for_sid(sid: &str) -> Result<Self> {
        let sddl = format!("O:{sid}D:P(A;;FA;;;{sid})");
        let sddl = wide_null(OsStr::new(&sddl));
        let mut descriptor = null_mut();
        // SAFETY: SDDL is valid null-terminated UTF-16 and `descriptor`
        // receives a LocalAlloc-owned security descriptor.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .context("failed to create owner-only receipt ACL");
        }
        Ok(Self(descriptor))
    }
}

impl Drop for SecurityDescriptor {
    fn drop(&mut self) {
        // SAFETY: the descriptor came from LocalAlloc and is freed exactly once.
        unsafe { LocalFree(self.0.cast()) };
    }
}

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: the token handle is owned and closed exactly once.
        unsafe { CloseHandle(self.0) };
    }
}

struct LocalAllocation(*mut c_void);

impl Drop for LocalAllocation {
    fn drop(&mut self) {
        // SAFETY: the pointer came from LocalAlloc and is freed exactly once.
        unsafe { LocalFree(self.0) };
    }
}

fn wide_ptr_to_string(pointer: *const u16) -> Result<String> {
    if pointer.is_null() {
        bail!("Windows returned a null UTF-16 string");
    }
    let mut length = 0;
    // SAFETY: callers provide a Windows-owned null-terminated string and keep
    // its allocation alive for the duration of this scan.
    unsafe {
        while *pointer.add(length) != 0 {
            length += 1;
        }
        String::from_utf16(std::slice::from_raw_parts(pointer, length))
            .context("Windows returned invalid UTF-16")
    }
}

fn wide_null(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_LINUX_EVIDENCE_SHA256: &str =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn session_gate_only_accepts_session_one() {
        assert!(require_session_one(1).is_ok());
        assert!(require_session_one(0).is_err());
        assert!(require_session_one(2).is_err());
    }

    #[test]
    fn complete_batch_requires_exactly_135_insertions() {
        assert!(
            require_complete_batch(ForceReleaseReport {
                requested_input_count: 135,
                inserted_input_count: 135,
            })
            .is_ok()
        );
        for report in [
            ForceReleaseReport {
                requested_input_count: 134,
                inserted_input_count: 134,
            },
            ForceReleaseReport {
                requested_input_count: 135,
                inserted_input_count: 134,
            },
            ForceReleaseReport {
                requested_input_count: 136,
                inserted_input_count: 136,
            },
        ] {
            assert!(require_complete_batch(report).is_err());
        }
    }

    #[test]
    fn verification_requires_a_continuous_500_milliseconds() {
        let start = Instant::now();
        let mut stable = None;
        assert!(!verification_complete(&mut stable, start, true));
        assert!(!verification_complete(
            &mut stable,
            start + Duration::from_millis(499),
            true
        ));
        assert!(!verification_complete(
            &mut stable,
            start + Duration::from_millis(500),
            false
        ));
        assert!(!verification_complete(
            &mut stable,
            start + Duration::from_millis(600),
            true
        ));
        assert!(verification_complete(
            &mut stable,
            start + Duration::from_millis(1100),
            true
        ));
    }

    #[test]
    fn sha256_stream_matches_known_vector() {
        let path = std::env::temp_dir().join(format!("viewflow-sha256-test-{}.txt", current_pid()));
        std::fs::write(&path, b"abc").unwrap();
        assert_eq!(
            sha256_path(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn receipt_schema_has_exact_security_evidence_fields() {
        let receipt = ForceReleaseReceipt {
            schema_version: 3,
            state: "viewflow-force-release-completed",
            operation_id: "deploy-20260829-abcdef",
            linux_frozen_evidence_sha256: TEST_LINUX_EVIDENCE_SHA256,
            tool_executable_sha256: "a".repeat(64),
            tool_pid: 42,
            tool_process_start_filetime: "100".into(),
            tool_session_id: 1,
            tool_user_sid: "S-1-5-21-1".into(),
            input_desktop: "Default".into(),
            requested_input_count: 135,
            inserted_input_count: 135,
            verification_stable_ms: 500,
            completed_at_utc: "2026-08-29T12:34:56.789Z".into(),
        };
        let value = serde_json::to_value(receipt).unwrap();
        assert_eq!(value["schema_version"], 3);
        assert_eq!(value["state"], "viewflow-force-release-completed");
        assert_eq!(value["tool_session_id"], 1);
        assert_eq!(value["tool_process_start_filetime"], "100");
        assert_eq!(value["requested_input_count"], 135);
        assert_eq!(value["inserted_input_count"], 135);
        assert_eq!(value["verification_stable_ms"], 500);
        assert_eq!(value["linux_frozen_evidence_sha256"], "b".repeat(64));
        let keys = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        assert_eq!(
            keys,
            BTreeSet::from([
                "completed_at_utc",
                "input_desktop",
                "inserted_input_count",
                "linux_frozen_evidence_sha256",
                "operation_id",
                "requested_input_count",
                "schema_version",
                "state",
                "tool_executable_sha256",
                "tool_pid",
                "tool_process_start_filetime",
                "tool_session_id",
                "tool_user_sid",
                "verification_stable_ms",
            ])
        );
    }

    #[test]
    fn process_start_filetime_serializes_as_a_lossless_u64_decimal_string() {
        let receipt = ForceReleaseReceipt {
            schema_version: 3,
            state: "viewflow-force-release-completed",
            operation_id: "deploy-20260829-abcdef",
            linux_frozen_evidence_sha256: TEST_LINUX_EVIDENCE_SHA256,
            tool_executable_sha256: "a".repeat(64),
            tool_pid: 42,
            tool_process_start_filetime: u64::MAX.to_string(),
            tool_session_id: 1,
            tool_user_sid: "S-1-5-21-1".into(),
            input_desktop: "Default".into(),
            requested_input_count: 135,
            inserted_input_count: 135,
            verification_stable_ms: 500,
            completed_at_utc: "2026-08-29T12:34:56.789Z".into(),
        };

        let value = serde_json::to_value(receipt).unwrap();
        assert_eq!(value["tool_process_start_filetime"], "18446744073709551615");
        assert!(value["tool_process_start_filetime"].is_string());
    }

    #[test]
    fn native_verification_plan_maps_the_complete_release_domain() {
        let scan_codes = force_release_scan_codes();
        assert_eq!(scan_codes.len(), 130);
        let virtual_keys = verification_virtual_keys(&scan_codes).unwrap();
        for button in [VK_LBUTTON, VK_MBUTTON, VK_RBUTTON, VK_XBUTTON1, VK_XBUTTON2] {
            assert!(virtual_keys.contains(&i32::from(button)));
        }
    }

    #[test]
    fn fresh_thread_binds_to_the_expected_desktop_object() {
        // SAFETY: this returns a borrowed handle to the test thread's desktop.
        let expected = unsafe { GetThreadDesktop(GetCurrentThreadId()) };
        assert!(!expected.is_null());
        let desktop_handle_address = expected as usize;
        let worker = thread::Builder::new()
            .name("viewflow-desktop-binding-test".into())
            .spawn(move || {
                let handle = desktop_handle_address as HDESK;
                bind_thread_to_desktop(handle)
            })
            .unwrap();
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn session_one_rechecks_the_active_default_desktop_object() {
        if current_session_id(current_pid()).unwrap() != REQUIRED_SESSION_ID {
            return;
        }
        let desktop = InputDesktop::open().unwrap();
        let desktop_handle_address = desktop.handle as usize;
        let worker = thread::Builder::new()
            .name("viewflow-active-desktop-test".into())
            .spawn(move || {
                let handle = desktop_handle_address as HDESK;
                bind_thread_to_desktop(handle)?;
                ensure_bound_input_desktop(handle)
            })
            .unwrap();
        worker.join().unwrap().unwrap();
        desktop.close().unwrap();
    }

    #[test]
    fn owner_only_receipt_is_create_once_and_not_overwritten() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "viewflow-force-release-receipt-test-{}-{unique}",
            current_pid()
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("receipt.json");
        let sid = current_user_sid().unwrap();
        let receipt = ForceReleaseReceipt {
            schema_version: 3,
            state: "viewflow-force-release-completed",
            operation_id: "deploy-20260829-abcdef",
            linux_frozen_evidence_sha256: TEST_LINUX_EVIDENCE_SHA256,
            tool_executable_sha256: "a".repeat(64),
            tool_pid: current_pid(),
            tool_process_start_filetime: "100".into(),
            tool_session_id: 1,
            tool_user_sid: sid.clone(),
            input_desktop: "Default".into(),
            requested_input_count: 135,
            inserted_input_count: 135,
            verification_stable_ms: 500,
            completed_at_utc: "2026-08-29T12:34:56.789Z".into(),
        };
        write_owner_only_receipt(&path, &sid, &receipt).unwrap();
        let original = std::fs::read(&path).unwrap();
        assert!(write_owner_only_receipt(&path, &sid, &receipt).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
