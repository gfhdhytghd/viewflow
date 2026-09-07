#!/usr/bin/python3.14
import fcntl
import hashlib
import os
import stat
import subprocess
import sys

OPERATION_ID = "55d06e8f96aa4adc9010e53612979374"
LAUNCHER = "/home/wilf/data/viewflow/deploy/launch-failed-pre-mutation-abort-55d06e8f-replay4-schema2-formal.sh"
LAUNCHER_SHA256 = "af054335e059f75329f9c656d4abd4c427879566baab1b4a10bc583cb518d64b"
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-55d06e8f-replay4-schema2-manifest.json"
MANIFEST_SHA256 = "0b93a56956528b618eff14e09e28ae6cef15a8a9e9b3403ac6c8049962c6904b"
APPROVAL = "/home/wilf/.local/state/viewflow/deployments/55d06e8f96aa4adc9010e53612979374/failed-pre-mutation-abort-replay4-schema2-execution-approval.json"
TRUSTED = {
    "/usr/bin/env": "08392d72874da4f88c619ee717f2b4a5f28ba0534ff8cf1083fb2edc37d6475f",
    "/usr/bin/python3.14": "d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c",
    "/usr/bin/bash": "575e03ac834b739349a4484de481abcd06a6f7193cefc795260a32a1943f20a5",
    "/usr/bin/bwrap": "7c44fa8e7326e62e81ab3f70ff682bfc0eb3b447b39cf9fbb779a31948364762",
}
REQUIRED_SEALS = (
    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
)
INNER_LAUNCHER_LOADER = """import fcntl,hashlib,os,sys
path,expected,*args=sys.argv[1:]
with open(path,"rb") as stream:data=stream.read()
if hashlib.sha256(data).hexdigest()!=expected:raise SystemExit(65)
fd=os.memfd_create("viewflow-schema2-abort-launcher",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
view=memoryview(data)
while view:
 written=os.write(fd,view)
 if written<=0:raise SystemExit(74)
 view=view[written:]
os.fsync(fd);os.lseek(fd,0,os.SEEK_SET)
required=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
fcntl.fcntl(fd,fcntl.F_ADD_SEALS,required)
if fcntl.fcntl(fd,fcntl.F_GET_SEALS)!=required:raise SystemExit(74)
os.set_inheritable(fd,True)
limit=os.sysconf("SC_OPEN_MAX");os.closerange(3,fd);os.closerange(fd+1,limit)
os.execve("/usr/bin/bash",["/usr/bin/bash",f"/proc/self/fd/{fd}",*args],{"HOME":"/home/wilf","PATH":"/usr/bin:/bin"})"""


def die(code: int) -> None:
    raise SystemExit(code)


def read_exact(path: str, expected: str, uid: int, mode: int, links: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (
            stat.S_ISREG(before.st_mode)
            and before.st_uid == uid
            and stat.S_IMODE(before.st_mode) == mode
            and before.st_nlink == links
        ):
            die(66)
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1048576, before.st_size - len(data)))
            if not chunk:
                die(65)
            data += chunk
        current = os.stat(path, follow_symlinks=False)
        if not (
            len(data) == before.st_size
            and hashlib.sha256(data).hexdigest() == expected
            and (current.st_dev, current.st_ino, current.st_uid, current.st_nlink)
            == (before.st_dev, before.st_ino, before.st_uid, before.st_nlink)
        ):
            die(65)
        return data
    finally:
        os.close(fd)


def seal(data: bytes) -> int:
    fd = os.memfd_create(
        "viewflow-schema2-abort-launcher", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING
    )
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            die(74)
        view = view[written:]
    os.fsync(fd)
    os.lseek(fd, 0, os.SEEK_SET)
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, REQUIRED_SEALS)
    if fcntl.fcntl(fd, fcntl.F_GET_SEALS) != REQUIRED_SEALS:
        die(74)
    return fd


def validate_self(expected_sha: str) -> None:
    if not sys.argv[0].startswith("/proc/self/fd/"):
        die(64)
    try:
        fd = int(sys.argv[0].rsplit("/", 1)[1])
    except ValueError:
        die(64)
    info = os.fstat(fd)
    data = os.pread(fd, info.st_size, 0)
    if not (
        hashlib.sha256(data).hexdigest() == expected_sha
        and fcntl.fcntl(fd, fcntl.F_GET_SEALS) == REQUIRED_SEALS
    ):
        die(65)


def main() -> None:
    mode = ""
    approval_sha = ""
    gate_sha = ""
    args = iter(sys.argv[1:])
    for item in args:
        if item == "--offline-preflight" and not mode:
            mode = "offline-preflight"
        elif item == "--execute" and not mode:
            mode = "execute"
        elif item == "--approval-sha256" and not approval_sha:
            approval_sha = next(args, "")
        elif item == "--gate-sha256" and not gate_sha:
            gate_sha = next(args, "")
        else:
            die(64)
    if mode not in {"offline-preflight", "execute"}:
        die(64)
    if len(gate_sha) != 64 or any(c not in "0123456789abcdef" for c in gate_sha):
        die(64)
    if mode == "execute" and (
        len(approval_sha) != 64
        or any(c not in "0123456789abcdef" for c in approval_sha)
    ):
        die(64)
    if mode == "offline-preflight" and approval_sha:
        die(64)
    if os.getuid() != 1000 or os.environ.get("HOME") != "/home/wilf":
        die(66)
    validate_self(gate_sha)
    for path, expected in TRUSTED.items():
        read_exact(path, expected, 0, 0o755, 1)
    read_exact(MANIFEST, MANIFEST_SHA256, 1000, 0o600, 1)
    launcher_fd = seal(read_exact(LAUNCHER, LAUNCHER_SHA256, 1000, 0o700, 1))
    if mode == "execute":
        read_exact(APPROVAL, approval_sha, 1000, 0o600, 1)
    elif os.path.lexists(APPROVAL):
        die(69)
    os.set_inheritable(launcher_fd, True)
    common_launcher_args = [
        "--launcher-sha256",
        LAUNCHER_SHA256,
        "--gate-sha256",
        gate_sha,
    ]
    if mode == "execute":
        sandbox_launcher_args = [*common_launcher_args, "--sandbox-preflight"]
        execute_launcher_args = [
            *common_launcher_args,
            "--execute",
            "--approval-sha256",
            approval_sha,
        ]
    else:
        sandbox_launcher_args = [*common_launcher_args, "--sandbox-preflight"]
        execute_launcher_args = [*common_launcher_args, "--offline-host-preflight"]
    bwrap_argv = [
        "/usr/bin/bwrap",
        "--die-with-parent",
        "--new-session",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--dir",
        "/tmp/viewflow-schema2-formal",
        "--ro-bind-data",
        str(launcher_fd),
        "/tmp/viewflow-schema2-formal/launcher.sh",
        "--clearenv",
        "--setenv",
        "HOME",
        "/home/wilf",
        "--setenv",
        "PATH",
        "/usr/bin:/bin",
        "--",
        "/usr/bin/python3.14",
        "-I",
        "-E",
        "-c",
        INNER_LAUNCHER_LOADER,
        "/tmp/viewflow-schema2-formal/launcher.sh",
        LAUNCHER_SHA256,
        *sandbox_launcher_args,
    ]
    clean_env = {"HOME": "/home/wilf", "PATH": "/usr/bin:/bin"}
    subprocess.run(bwrap_argv, env=clean_env, pass_fds=(launcher_fd,), check=True)
    direct_argv = [
        "/usr/bin/python3.14",
        "-I",
        "-E",
        "-c",
        INNER_LAUNCHER_LOADER,
        f"/proc/self/fd/{launcher_fd}",
        LAUNCHER_SHA256,
        *execute_launcher_args,
    ]
    if mode == "offline-preflight":
        subprocess.run(direct_argv, env=clean_env, pass_fds=(launcher_fd,), check=True)
        print("schema2 abort bwrap structural and host sealed offline preflight passed")
        return
    for name in os.listdir("/proc/self/fd"):
        fd = int(name)
        if fd >= 3 and fd != launcher_fd:
            try:
                os.close(fd)
            except OSError:
                pass
    os.execve("/usr/bin/python3.14", direct_argv, clean_env)


if __name__ == "__main__":
    main()
