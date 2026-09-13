"""Platform-neutral bundle/profile model and independent component supervisor."""
from dataclasses import dataclass, field
import base64
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

PLATFORM = 'windows' if sys.platform == 'win32' else 'linux'
ROOT = Path(sys.executable).resolve().parent if getattr(sys, 'frozen', False) else Path(__file__).resolve().parent
DATA = Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'Viewflow' if PLATFORM == 'windows' else Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'viewflow/app'
SCRIPTS = {'desktop-autostart-linux': 'desktop-autostart-linux.py', 'native-trackpad-forward': 'linux_native_forward.py'}


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.next')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
    temporary.replace(path)


def safe_name(name):
    return isinstance(name, str) and bool(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,100}', name)) and name not in ('.', '..')


def load_manifest(root=ROOT):
    manifest = json.loads((root / 'bundle-manifest.json').read_text(encoding='utf-8'))
    if manifest.get('platform') != PLATFORM or manifest.get('schema_version') != 1:
        raise ValueError('安装包平台或版本不匹配')
    for name in manifest.get('scripts', []):
        if name not in SCRIPTS: raise ValueError('未知脚本组件')
    for name, relative in manifest['programs'].items():
        if not safe_name(name) or Path(relative).is_absolute() or '..' in Path(relative).parts:
            raise ValueError('安装包中的组件路径无效')
        if not (root / relative).is_file():
            raise ValueError(f'安装包缺少组件：{name}')
    for relative, expected in manifest.get('files', {}).items():
        path = Path(relative)
        if path.is_absolute() or '..' in path.parts: raise ValueError('安装包清单路径无效')
        with (root / path).open('rb') as stream: actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual != expected: raise ValueError(f'安装包组件校验失败：{relative}')
    return manifest


def validate_profile(profile, manifest):
    if profile.get('version') != 2 or profile.get('platform') != manifest['platform']:
        raise ValueError('配对文件平台或版本不匹配')
    if not isinstance(profile.get('name'), str) or not profile['name'].strip():
        raise ValueError('配对文件缺少名称')
    components = profile.get('components')
    if not isinstance(components, list) or not components:
        raise ValueError('配对文件没有连接组件')
    seen = set()
    for item in components:
        name = item.get('id')
        if not safe_name(name) or name in seen:
            raise ValueError('组件名称无效或重复')
        seen.add(name)
        if item.get('program') not in manifest['programs'] and item.get('program') not in manifest.get('scripts', []):
            raise ValueError(f'安装包不包含组件：{item.get("program")}')
        if not isinstance(item.get('args'), list) or not all(isinstance(x, str) and '\0' not in x for x in item['args']):
            raise ValueError('组件参数无效')
        environment = item.get('environment', {})
        if not isinstance(environment, dict) or not all(isinstance(k, str) and isinstance(v, str) and '\0' not in k+v and '=' not in k for k, v in environment.items()):
            raise ValueError('组件环境变量无效')
    for name, value in profile.get('files', {}).items():
        if not safe_name(name) or not isinstance(value, str):
            raise ValueError('配对附件名称无效')
        base64.b64decode(value, validate=True)
    for name in profile.get('configs', {}):
        if not safe_name(name) or name in profile.get('files', {}):
            raise ValueError('配置文件名称无效或与附件冲突')
    return profile


def expand(value, root, data, manifest):
    if isinstance(value, str):
        value = value.replace('${bundle}', str(root)).replace('${profile}', str(data))
        for name, relative in manifest['programs'].items():
            value = value.replace('${program:' + name + '}', str(root / relative))
        # Windows native peers accept forward slashes, but canonicalize fully
        # expanded filesystem tokens so diagnostics and plan round-trips agree.
        if PLATFORM == 'windows' and (value.startswith(str(root)) or value.startswith(str(data))):
            value = os.path.normpath(value)
        return value
    if isinstance(value, list):
        return [expand(x, root, data, manifest) for x in value]
    if isinstance(value, dict):
        return {k: expand(v, root, data, manifest) for k, v in value.items()}
    return value


def materialize(profile, manifest, root=ROOT, data=DATA):
    validate_profile(profile, manifest)
    for name, encoded in profile.get('files', {}).items():
        private_write(data / name, base64.b64decode(encoded, validate=True))
    for name, config in profile.get('configs', {}).items():
        private_write(data / name, json.dumps(expand(config, root, data, manifest), indent=2).encode())


def command(item, manifest, root=ROOT, data=DATA):
    program = item['program']
    if program in SCRIPTS:
        prefix = [str(root / ('Viewflow.exe' if PLATFORM == 'windows' else 'Viewflow')), '--run-script', program]
        if not getattr(sys, 'frozen', False):
            prefix = [sys.executable, str(ROOT / 'main.py'), '--run-script', program]
    else:
        prefix = [str(root / manifest['programs'][program])]
    return prefix + expand(item['args'], root, data, manifest)


def signal_console(pid):
    # Run only in a short-lived helper. Attaching the GUI itself would put it in
    # the worker's Ctrl-C broadcast group and could terminate the whole app.
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.FreeConsole()
    if not kernel.AttachConsole(pid): return False
    kernel.SetConsoleCtrlHandler(None, True)
    sent = bool(kernel.GenerateConsoleCtrlEvent(0, 0))
    time.sleep(0.2)  # Keep the ignore handler alive while the async event drains.
    # Do not restore Ctrl-C handling in this helper; exit detaches it.
    return sent


def windows_interrupt(process):
    if getattr(sys, 'frozen', False):
        argv = [sys.executable, '--signal-console', str(process.pid)]
    else:
        argv = [sys.executable, str(ROOT / 'main.py'), '--signal-console', str(process.pid)]
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW, timeout=5)
    return result.returncode == 0


def windows_resume(process):
    # Popen closes its initial thread handle. Find that suspended thread through
    # the documented Toolhelp API after assigning the process to its job.
    import ctypes as c
    from ctypes import wintypes as w
    class Entry(c.Structure):
        _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('thread', w.DWORD),
                    ('owner', w.DWORD), ('base_priority', w.LONG), ('delta_priority', w.LONG), ('flags', w.DWORD)]
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
    kernel.Thread32First.argtypes = [w.HANDLE, c.POINTER(Entry)]
    kernel.Thread32Next.argtypes = [w.HANDLE, c.POINTER(Entry)]
    kernel.OpenThread.restype = w.HANDLE
    kernel.ResumeThread.argtypes = [w.HANDLE]; kernel.ResumeThread.restype = w.DWORD
    kernel.CloseHandle.argtypes = [w.HANDLE]
    snapshot = kernel.CreateToolhelp32Snapshot(4, 0)
    if snapshot == w.HANDLE(-1).value: raise c.WinError(c.get_last_error())
    try:
        entry = Entry(); entry.size = c.sizeof(entry)
        more = kernel.Thread32First(snapshot, c.byref(entry))
        while more:
            if entry.owner == process.pid:
                thread = kernel.OpenThread(2, False, entry.thread)
                if not thread: raise c.WinError(c.get_last_error())
                try:
                    if kernel.ResumeThread(thread) == 0xffffffff: raise c.WinError(c.get_last_error())
                    return
                finally: kernel.CloseHandle(thread)
            more = kernel.Thread32Next(snapshot, c.byref(entry))
        raise OSError('cannot locate the worker initial thread')
    finally: kernel.CloseHandle(snapshot)


class WindowsJob:
    """Close the job after a worker exits so no native child can become orphaned."""
    def __init__(self, process):
        import ctypes as c
        from ctypes import wintypes as w
        class Basic(c.Structure):
            _fields_ = [('process_time', c.c_int64), ('job_time', c.c_int64), ('flags', w.DWORD),
                        ('minimum', c.c_size_t), ('maximum', c.c_size_t), ('active', w.DWORD),
                        ('affinity', c.c_size_t), ('priority', w.DWORD), ('scheduling', w.DWORD)]
        class IO(c.Structure):
            _fields_ = [(x, c.c_uint64) for x in ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]
        class Extended(c.Structure):
            _fields_ = [('basic', Basic), ('io', IO), ('process_memory', c.c_size_t), ('job_memory', c.c_size_t),
                        ('peak_process', c.c_size_t), ('peak_job', c.c_size_t)]
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.restype = w.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise c.WinError(c.get_last_error())
        limits = Extended(); limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, c.byref(limits), c.sizeof(limits)) or not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            error = c.WinError(c.get_last_error()); self.close(); raise error
    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle); self.handle = None


@dataclass
class Worker:
    item: dict
    argv: list
    data: Path
    environment: dict = field(default_factory=dict)
    desired: bool = False
    process: object = None
    output: object = None
    job: object = None
    status: str = '已停止'
    failures: int = 0
    next_start: float = 0
    started: float = 0
    stopping: object = None
    escalated: bool = False
    last_exit: object = None

    def tick(self, now=None):
        now = time.monotonic() if now is None else now
        if self.process is not None and self.process.poll() is not None:
            self.last_exit = self.process.returncode
            if self.job: self.job.close(); self.job = None
            if self.output: self.output.close(); self.output = None
            self.process = None; self.stopping = None
            if now - self.started > 30: self.failures = 0
            self.failures = min(self.failures + 1, 6)
            self.next_start = now + min(2 ** (self.failures - 1), 30)
            self.status = f'组件已退出，正在恢复（{self.last_exit}）' if self.desired else '已停止'
        if self.process is not None and self.stopping is not None:
            elapsed = now - self.stopping
            if elapsed > 15 and not self.escalated:
                if PLATFORM == 'windows': self.process.terminate()
                else: os.killpg(self.process.pid, signal.SIGTERM)
                self.escalated = True
            if elapsed > 17 and self.process.poll() is None:
                if self.job: self.job.close(); self.job = None
                if PLATFORM == 'windows': self.process.kill()
                else: os.killpg(self.process.pid, signal.SIGKILL)
        if not self.desired or self.process is not None or now < self.next_start:
            return
        try:
            log = self.data / 'logs' / (self.item['id'] + '.log')
            log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if log.exists() and log.stat().st_size > 5 * 1024 * 1024:
                log.replace(log.with_suffix('.previous'))
            self.output = os.fdopen(os.open(log, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600), 'ab')
            kwargs = {'start_new_session': True} if PLATFORM != 'windows' else {'creationflags': subprocess.CREATE_NEW_CONSOLE | 0x00000004}
            if PLATFORM == 'windows':
                import ctypes
                # The ignore-Ctrl-C attribute is inherited even by a new console.
                # Clear it before spawning so Rust's normal shutdown handler runs.
                ctypes.windll.kernel32.SetConsoleCtrlHandler(None, False)
                startup = subprocess.STARTUPINFO(); startup.dwFlags = subprocess.STARTF_USESHOWWINDOW; startup.wShowWindow = 0
                kwargs['startupinfo'] = startup
            self.process = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, stdout=self.output,
                stderr=subprocess.STDOUT, env=dict(os.environ, **self.environment), **kwargs)
            if PLATFORM == 'windows':
                self.job = WindowsJob(self.process)
                windows_resume(self.process)
            self.started = now; self.stopping = None; self.escalated = False; self.status = '正在运行'
        except Exception as error:
            if self.process is not None:
                self.process.kill(); self.process.wait(); self.process = None
            if self.output: self.output.close(); self.output = None
            self.failures = min(self.failures + 1, 6); self.next_start = now + min(2 ** (self.failures - 1), 30)
            self.status = f'启动失败：{error}'

    def stop(self):
        self.desired = False
        if self.process is None or self.process.poll() is not None or self.stopping is not None:
            return
        self.stopping = time.monotonic(); self.status = '正在结束连接'
        try:
            if PLATFORM == 'windows': windows_interrupt(self.process)
            else: os.killpg(self.process.pid, signal.SIGINT)
        except ProcessLookupError:
            pass


class InstanceLock:
    def __init__(self, data=DATA):
        data.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.stream = open(data / 'app.lock', 'a+b')
        self.stream.seek(0); self.stream.write(b'0'); self.stream.flush(); self.stream.seek(0)
        try:
            if PLATFORM == 'windows':
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.stream.close(); raise ValueError('Viewflow 已在运行，请使用已打开的应用。')
    def close(self): self.stream.close()
