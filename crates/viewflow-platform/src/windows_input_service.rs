//! LocalSystem service supervising an input-only worker in the console session.
//! The normal receiver retains network authentication and lease/sequence validation.
#![allow(unsafe_code)]
use super::{
    windows_input::{DesktopPointerDisplay, WindowsInputBackend, WindowsInputError},
    windows_input_wire as wire,
};
use std::{
    fs::File,
    io::{self, Write},
    mem::{size_of, zeroed},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle},
    },
    ptr::{null, null_mut},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    time::{Duration, Instant},
};
use viewflow_protocol::InputEvent;
use windows_sys::Win32::{
    Foundation::*,
    Security::Authorization::*,
    Security::*,
    Storage::FileSystem::*,
    System::{Pipes::*, RemoteDesktop::*, Services::*, Threading::*},
};

const NAME: &str = "ViewflowInput";
const WATCHDOG: Duration = Duration::from_secs(5);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: AtomicUsize = AtomicUsize::new(0);
fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}
fn check(ok: i32) -> io::Result<()> {
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn failed(message: &str) -> io::Error {
    io::Error::other(message)
}
struct Handle(HANDLE);
impl Handle {
    fn new(h: HANDLE) -> io::Result<Self> {
        if h.is_null() || h == INVALID_HANDLE_VALUE {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(h))
        }
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn session() -> io::Result<u32> {
    let mut id = 0;
    unsafe {
        check(ProcessIdToSessionId(GetCurrentProcessId(), &mut id))?;
    }
    Ok(id)
}
fn pipe_name(id: u32) -> Vec<u16> {
    wide(format!(r"\\.\pipe\ViewflowInput-v2-{id}"))
}

struct Security(PSECURITY_DESCRIPTOR);
impl Security {
    fn new(sddl: &str) -> io::Result<Self> {
        let mut p = null_mut();
        unsafe {
            check(ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide(sddl).as_ptr(),
                SDDL_REVISION_1,
                &mut p,
                null_mut(),
            ))?;
        }
        Ok(Self(p))
    }
    fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0,
            bInheritHandle: 0,
        }
    }
}
impl Drop for Security {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
fn is_system(process: HANDLE) -> io::Result<bool> {
    let mut token = null_mut();
    unsafe {
        check(OpenProcessToken(process, TOKEN_QUERY, &mut token))?;
    }
    let token = Handle::new(token)?;
    // Aligned backing storage for TOKEN_USER and its inline SID.
    let mut info = [0usize; 64];
    let mut size = 0;
    unsafe {
        check(GetTokenInformation(
            token.0,
            TokenUser,
            info.as_mut_ptr().cast(),
            size_of_val(&info) as u32,
            &mut size,
        ))?;
        let user = &*(info.as_ptr().cast::<TOKEN_USER>());
        Ok(IsWellKnownSid(user.User.Sid, WinLocalSystemSid) != 0)
    }
}
fn no_data(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(232 | 536))
}
fn pause() {
    std::thread::sleep(Duration::from_millis(2));
}
// std::fs::File::read maps ERROR_NO_DATA to EOF on Windows. Preserve the
// native distinction between an idle nonblocking pipe and a disconnected peer.
fn read_pipe(file: &File, bytes: &mut [u8]) -> io::Result<usize> {
    let mut read = 0;
    unsafe {
        check(ReadFile(
            file.as_raw_handle(),
            bytes.as_mut_ptr(),
            bytes.len() as u32,
            &mut read,
            null_mut(),
        ))?;
    }
    Ok(read as usize)
}
fn read_poll(
    file: &mut File,
    bytes: &mut [u8],
    mut cancelled: impl FnMut() -> bool,
) -> io::Result<()> {
    let mut done = 0;
    while done < bytes.len() {
        if cancelled() {
            return Err(failed("input operation cancelled or watchdog expired"));
        }
        match read_pipe(file, &mut bytes[done..]) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => done += n,
            Err(e) if no_data(&e) => pause(),
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn write_poll(
    file: &mut File,
    bytes: &[u8],
    mut cancelled: impl FnMut() -> bool,
) -> io::Result<()> {
    let mut done = 0;
    while done < bytes.len() {
        if cancelled() {
            return Err(failed("input operation cancelled or watchdog expired"));
        }
        match file.write(&bytes[done..]) {
            Ok(0) => pause(),
            Ok(n) => done += n,
            Err(e) if no_data(&e) => pause(),
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[derive(Debug, Default)]
pub(crate) struct Client {
    pipe: Option<File>,
}
impl Client {
    fn connect() -> io::Result<File> {
        unsafe {
            let h = CreateFileW(
                pipe_name(session()?).as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null(),
                OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            );
            let h = Handle::new(h)?;
            let mut pid = 0;
            check(GetNamedPipeServerProcessId(h.0, &mut pid))?;
            let server = Handle::new(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid))?;
            let mut server_session = 0;
            check(ProcessIdToSessionId(pid, &mut server_session))?;
            if !is_system(server.0)? || server_session != session()? {
                return Err(failed("input broker identity/session mismatch"));
            }
            let mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
            check(SetNamedPipeHandleState(h.0, &mode, null(), null()))?;
            let f = File::from_raw_handle(h.0);
            std::mem::forget(h);
            Ok(f)
        }
    }
    pub(crate) fn request(
        &mut self,
        event: Option<InputEvent>,
        display: Option<DesktopPointerDisplay>,
    ) -> Result<(), WindowsInputError> {
        self.exchange(&wire::encode(event, display))
    }
    fn exchange(&mut self, request: &[u8; wire::REQUEST_SIZE]) -> Result<(), WindowsInputError> {
        let result = (|| -> io::Result<_> {
            if self.pipe.is_none() {
                self.pipe = Some(Self::connect()?);
            }
            let pipe = self.pipe.as_mut().unwrap();
            let start = Instant::now();
            write_poll(pipe, request, || start.elapsed() >= WATCHDOG)?;
            let mut reply = [0; 5];
            read_poll(pipe, &mut reply, || start.elapsed() >= WATCHDOG)?;
            Ok(wire::decode_result(reply))
        })();
        match result {
            Ok(r) => r,
            Err(e) => {
                // Never replay an uncertain key/button operation on reconnect.
                self.pipe.take();
                eprintln!("Viewflow input service unavailable: {e}");
                Err(WindowsInputError::SendInputFailed)
            }
        }
    }
}

fn probe_request() -> [u8; wire::REQUEST_SIZE] {
    let mut request = wire::encode(None, None);
    request[4] = 127;
    request
}
fn probe_secure_desktop() -> io::Result<()> {
    use windows_sys::Win32::System::StationsAndDesktops::{
        CloseDesktop, DESKTOP_READOBJECTS, OpenDesktopW,
    };
    // Only inspect access. Never switch the visible desktop or synthesize input.
    let desktop = unsafe {
        OpenDesktopW(
            wide("Winlogon").as_ptr(),
            0,
            0,
            DESKTOP_READOBJECTS | GENERIC_WRITE,
        )
    };
    if desktop.is_null() {
        return Err(io::Error::last_os_error());
    }
    unsafe { check(CloseDesktop(desktop)) }
}

fn stopped(event: HANDLE) -> bool {
    unsafe { WaitForSingleObject(event, 0) == WAIT_OBJECT_0 }
}
fn worker(sid: &str, stop_name: &str, parent_pid: u32) -> io::Result<()> {
    unsafe {
        if !is_system(GetCurrentProcess())? {
            return Err(failed("input worker requires LocalSystem"));
        }
    }
    let stop = Handle::new(unsafe {
        OpenEventW(SYNCHRONIZATION_SYNCHRONIZE, 0, wide(stop_name).as_ptr())
    })?;
    let parent = Handle::new(unsafe { OpenProcess(SYNCHRONIZATION_SYNCHRONIZE, 0, parent_pid) })?;
    let should_stop = || stopped(stop.0) || stopped(parent.0);
    // Only the configured receiver account and SYSTEM can connect; no network clients.
    let security = Security::new(&format!("D:P(A;;GA;;;SY)(A;;GRGW;;;{sid})"))?;
    let attrs = security.attributes();
    let h = unsafe {
        CreateNamedPipeW(
            pipe_name(session()?).as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            4096,
            4096,
            0,
            &attrs,
        )
    };
    let handle = Handle::new(h)?;
    let mut pipe = unsafe { File::from_raw_handle(handle.0) };
    std::mem::forget(handle);
    let mut backend = WindowsInputBackend::new_direct();
    while !should_stop() {
        let connected = unsafe { ConnectNamedPipe(h, null_mut()) };
        let error = unsafe { GetLastError() };
        if connected == 0 && error != ERROR_PIPE_CONNECTED {
            if error != ERROR_PIPE_LISTENING && error != ERROR_NO_DATA {
                return Err(io::Error::from_raw_os_error(error as i32));
            }
            if error == ERROR_NO_DATA {
                unsafe {
                    DisconnectNamedPipe(h);
                }
            }
            pause();
            continue;
        }
        let mut client_session = u32::MAX;
        if unsafe { GetNamedPipeClientSessionId(h, &mut client_session) } == 0 {
            pause();
            continue;
        }
        log(&format!(
            "input client connected session={client_session} worker_session={}",
            session()?
        ));
        if client_session == session()? {
            loop {
                let mut request = [0; wire::REQUEST_SIZE];
                if let Err(error) = read_poll(&mut pipe, &mut request, || should_stop()) {
                    log(&format!("input client read ended: {error}"));
                    break;
                }
                let result = if request == probe_request() {
                    probe_secure_desktop().map_err(|error| {
                        log(&format!("secure desktop probe: {error}"));
                        WindowsInputError::SendInputFailed
                    })
                } else {
                    wire::decode(&request).and_then(|(event, display)| {
                        backend.clear_desktop_display();
                        if let Some(d) = display {
                            backend.set_desktop_display(d);
                        }
                        backend.apply(&event)
                    })
                };
                let start = Instant::now();
                if write_poll(&mut pipe, &wire::encode_result(result), || {
                    should_stop() || start.elapsed() >= WATCHDOG
                })
                .is_err()
                {
                    break;
                }
            }
        }
        // Keep the same backend until all tracked releases succeed. A desktop
        // transition is recoverable and must not leak held state into a new client.
        let start = Instant::now();
        while backend.release_all().is_err() {
            if should_stop() && start.elapsed() >= WATCHDOG {
                return Err(failed("input release failed during service stop"));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        unsafe {
            DisconnectNamedPipe(h);
        }
    }
    Ok(())
}

fn privilege(token: HANDLE, name: &str) -> io::Result<()> {
    unsafe {
        let mut luid = zeroed();
        check(LookupPrivilegeValueW(
            null(),
            wide(name).as_ptr(),
            &mut luid,
        ))?;
        let p = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES {
                Luid: luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        SetLastError(0);
        check(AdjustTokenPrivileges(
            token,
            0,
            &p,
            0,
            null_mut(),
            null_mut(),
        ))?;
        if GetLastError() == ERROR_NOT_ALL_ASSIGNED {
            return Err(failed("service token lacks required privilege"));
        }
    }
    Ok(())
}
struct Child {
    process: Handle,
    stop: Handle,
    session: u32,
}
impl Child {
    fn launch(id: u32, sid: &str) -> io::Result<Self> {
        unsafe {
            let mut t = null_mut();
            check(OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ALL_ACCESS,
                &mut t,
            ))?;
            let token = Handle::new(t)?;
            for name in [
                "SeTcbPrivilege",
                "SeAssignPrimaryTokenPrivilege",
                "SeIncreaseQuotaPrivilege",
            ] {
                privilege(token.0, name)?;
            }
            let mut t = null_mut();
            check(DuplicateTokenEx(
                token.0,
                TOKEN_ALL_ACCESS,
                null(),
                SecurityImpersonation,
                TokenPrimary,
                &mut t,
            ))?;
            let token = Handle::new(t)?;
            check(SetTokenInformation(
                token.0,
                TokenSessionId,
                (&id as *const u32).cast(),
                size_of::<u32>() as u32,
            ))?;
            let stop_name = format!("Global\\ViewflowInputStop-{}-{id}", GetCurrentProcessId());
            let sec = Security::new("D:P(A;;GA;;;SY)")?;
            let stop = Handle::new(CreateEventW(
                &sec.attributes(),
                1,
                0,
                wide(&stop_name).as_ptr(),
            ))?;
            check(ResetEvent(stop.0))?;
            let exe = std::env::current_exe()?;
            let mut command = wide(format!(
                "\"{}\" worker {sid} {stop_name} {}",
                exe.display(),
                GetCurrentProcessId()
            ));
            let mut desktop = wide("winsta0\\default");
            let mut startup: STARTUPINFOW = zeroed();
            startup.cb = size_of::<STARTUPINFOW>() as u32;
            startup.lpDesktop = desktop.as_mut_ptr();
            let mut process = zeroed();
            check(CreateProcessAsUserW(
                token.0,
                wide(&exe).as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_NO_WINDOW,
                null(),
                null(),
                &startup,
                &mut process,
            ))?;
            let _thread = Handle::new(process.hThread)?;
            Ok(Self {
                process: Handle::new(process.hProcess)?,
                stop,
                session: id,
            })
        }
    }
    fn exited(&self) -> bool {
        stopped(self.process.0)
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        unsafe {
            SetEvent(self.stop.0);
            // This watchdog is for a hung OS worker, never a frame or input deadline.
            if WaitForSingleObject(self.process.0, 6000) == WAIT_TIMEOUT {
                TerminateProcess(self.process.0, 1);
                WaitForSingleObject(self.process.0, 1000);
            }
        }
    }
}
fn report(state: u32, error: u32) {
    let h = STATUS.load(Ordering::Relaxed) as SERVICE_STATUS_HANDLE;
    if !h.is_null() {
        let s = SERVICE_STATUS {
            dwServiceType: SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState: state,
            dwControlsAccepted: if state == SERVICE_RUNNING {
                SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
            } else {
                0
            },
            dwWin32ExitCode: error,
            dwServiceSpecificExitCode: 0,
            dwCheckPoint: u32::from(state == SERVICE_STOP_PENDING),
            dwWaitHint: if state == SERVICE_STOP_PENDING {
                10000
            } else {
                0
            },
        };
        unsafe {
            SetServiceStatus(h, &s);
        }
    }
}
unsafe extern "system" fn control(
    code: u32,
    _: u32,
    _: *mut core::ffi::c_void,
    _: *mut core::ffi::c_void,
) -> u32 {
    if code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN {
        STOP.store(true, Ordering::Relaxed);
        report(SERVICE_STOP_PENDING, 0);
    }
    NO_ERROR
}
fn supervise(sid: &str) -> io::Result<()> {
    if !unsafe { is_system(GetCurrentProcess())? } {
        return Err(failed("service requires LocalSystem"));
    }
    let mut child: Option<Child> = None;
    while !STOP.load(Ordering::Relaxed) {
        let id = unsafe { WTSGetActiveConsoleSessionId() };
        if child
            .as_ref()
            .is_some_and(|c| c.session != id || c.exited())
        {
            child.take();
        }
        if child.is_none() && id != u32::MAX {
            match Child::launch(id, sid) {
                Ok(c) => child = Some(c),
                Err(e) => {
                    log(&format!("worker launch failed: {e}"));
                }
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    drop(child);
    Ok(())
}
fn log(message: &str) {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(parent.join("input-service.log"))
            {
                let _ = writeln!(f, "{:?} {message}", std::time::SystemTime::now());
            }
        }
    }
}
unsafe extern "system" fn service_main(_: u32, _: *mut *mut u16) {
    let h =
        unsafe { RegisterServiceCtrlHandlerExW(wide(NAME).as_ptr(), Some(control), null_mut()) };
    if h.is_null() {
        return;
    }
    STATUS.store(h as usize, Ordering::Relaxed);
    report(SERVICE_RUNNING, 0);
    let args: Vec<_> = std::env::args().collect();
    let result = args
        .get(2)
        .ok_or_else(|| failed("missing receiver SID"))
        .and_then(|sid| supervise(sid));
    let code = if let Err(e) = result {
        log(&e.to_string());
        ERROR_SERVICE_SPECIFIC_ERROR
    } else {
        0
    };
    report(SERVICE_STOPPED, code);
}
/// Entry point for the dedicated service executable. No network or UI code runs here.
pub fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() == 2 && args[1] == "probe" {
        Client::default()
            .exchange(&probe_request())
            .map_err(|e| failed(&format!("input service probe failed: {e:?}")))?;
        println!(
            "input-service-ready session={} secure-desktop-access=ok input-injected=false",
            session()?
        );
        return Ok(());
    }
    // Validate SID syntax before using it in the service's ACL or child command.
    let sid = args
        .get(2)
        .ok_or_else(|| failed("usage: vf-input-service service <receiver-SID>"))?;
    if !sid.starts_with("S-1-")
        || !sid
            .bytes()
            .all(|c| c == b'S' || c == b'-' || c.is_ascii_digit())
    {
        return Err(failed("invalid receiver SID"));
    }
    let result = match args.get(1).map(String::as_str) {
        Some("worker") if args.len() == 5 => worker(
            sid,
            &args[3],
            args[4].parse().map_err(|_| failed("invalid parent PID"))?,
        ),
        Some("service") if args.len() == 3 => {
            let mut name = wide(NAME);
            let entries = [
                SERVICE_TABLE_ENTRYW {
                    lpServiceName: name.as_mut_ptr(),
                    lpServiceProc: Some(service_main),
                },
                SERVICE_TABLE_ENTRYW {
                    lpServiceName: null_mut(),
                    lpServiceProc: None,
                },
            ];
            unsafe { check(StartServiceCtrlDispatcherW(entries.as_ptr())) }
        }
        _ => Err(failed("usage: vf-input-service service <receiver-SID>")),
    };
    if let Err(e) = &result {
        log(&e.to_string());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_pipe_is_not_disconnect() {
        // Only local pipe I/O: no service install, desktop switch or OS input.
        let name = wide(format!(
            r"\\.\pipe\ViewflowInput-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let server = Handle::new(unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                0,
                null(),
            )
        })
        .unwrap();
        unsafe {
            ConnectNamedPipe(server.0, null_mut());
        }
        let client = Handle::new(unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null(),
                OPEN_EXISTING,
                0,
                null_mut(),
            )
        })
        .unwrap();
        unsafe {
            ConnectNamedPipe(server.0, null_mut());
        }
        let mut server_file = unsafe { File::from_raw_handle(server.0) };
        std::mem::forget(server);
        let mut client_file = unsafe { File::from_raw_handle(client.0) };
        std::mem::forget(client);
        let mut bytes = [0; 4];
        assert_eq!(
            read_pipe(&server_file, &mut bytes)
                .unwrap_err()
                .raw_os_error(),
            Some(ERROR_NO_DATA as i32)
        );
        assert!(read_poll(&mut server_file, &mut bytes, || true).is_err());
        client_file.write_all(b"test").unwrap();
        read_poll(&mut server_file, &mut bytes, || false).unwrap();
        assert_eq!(&bytes, b"test");
        drop(client_file);
        let error = read_pipe(&server_file, &mut bytes).unwrap_err();
        assert!(
            !no_data(&error),
            "closed pipe must not be treated as idle: {error}"
        );
    }
}
