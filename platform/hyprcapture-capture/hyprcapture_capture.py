#!/usr/bin/env python3
"""One-shot, CPU-only HyprCapture window-artifact adapter.

This is deliberately not a streaming or performance capture path.  It writes
the plugin's private request-file protocol, invokes its documented Lua API,
then converts one raw straight-RGBA artifact to Viewflow's premultiplied BGRA
VFBG payload.  It never changes HyprCapture or global Hyprland settings.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import secrets
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

MAX_DIMENSION = 32768
MAX_ARTIFACT_BYTES = 512 * 1024 * 1024
MAX_JSON_BYTES = 8 * 1024 * 1024


class ContractError(RuntimeError):
    pass


def _private_root() -> Path:
    """Match HyprCapture's owner-only runtime-root naming convention."""
    name = f"hyprcapture-{os.geteuid()}"
    for base in (Path("/dev/shm"), Path("/tmp"), Path(tempfile.gettempdir())):
        try:
            base_stat = base.stat()
            if not stat.S_ISDIR(base_stat.st_mode):
                continue
            root = base / name
            root.mkdir(mode=0o700, exist_ok=True)
            root_stat = root.lstat()
            if (stat.S_ISDIR(root_stat.st_mode) and root_stat.st_uid == os.geteuid()
                    and stat.S_IMODE(root_stat.st_mode) == 0o700):
                return root.resolve(strict=True)
        except OSError:
            continue
    raise ContractError("unable to establish HyprCapture private runtime root")


def _inside_private_root(path: Path) -> Path:
    root = _private_root()
    try:
        candidate = path.absolute()
        relative = candidate.relative_to(root)
        current = root
        for component in relative.parts:
            current /= component
            if current.exists() and stat.S_ISLNK(current.lstat().st_mode):
                raise ContractError("private path contains a symlink")
    except (OSError, ValueError) as error:
        raise ContractError("path is outside the HyprCapture private runtime root") from error
    return candidate


def _safe_private_file(path: Path, maximum: int) -> bytes:
    path = _inside_private_root(path)
    try:
        st = path.lstat()
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) & 0o022
                or st.st_nlink != 1):
            raise ContractError("private file ownership or mode is unsafe")
        if st.st_size <= 0 or st.st_size > maximum:
            raise ContractError("private file size is invalid")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1
                    or stat.S_IMODE(opened.st_mode) & 0o022 or opened.st_ino != st.st_ino or opened.st_dev != st.st_dev
                    or opened.st_size != st.st_size):
                raise ContractError("private file changed during open")
            chunks: list[bytes] = []
            remaining = opened.st_size
            while remaining:
                chunk = os.read(fd, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) != opened.st_size or os.fstat(fd).st_size != opened.st_size:
                raise ContractError("private file changed during read")
            return data
        finally:
            os.close(fd)
    except OSError as error:
        raise ContractError("private file is unavailable") from error


def _number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not (minimum <= value <= maximum):
        raise ContractError(f"invalid {name}")
    return float(value)


def _rect(value: Any, name: str) -> dict[str, float]:
    if not isinstance(value, dict):
        raise ContractError(f"invalid {name}")
    return {key: _number(value.get(key), f"{name}.{key}", 1.0 if key in ("width", "height") else -1_000_000.0, 1_000_000.0)
            for key in ("x", "y", "width", "height")}


def make_request(window_address: str) -> dict[str, Any]:
    if not isinstance(window_address, str) or not window_address or len(window_address.encode()) > 4096:
        raise ContractError("window address is required and bounded")
    return {
        "id": secrets.token_hex(16),
        "defaults": {
            "mode": "window", "fullscreenScope": "all", "windowBackground": "transparent",
            "windowBorder": "keep", "windowShadow": "keep", "recordWindowBackend": "auto",
        },
        "mode": "window",
        "targetGeometry": {"x": 0, "y": 0, "width": 1, "height": 1},
        "windowAddress": window_address,
    }


def write_request(window_address: str) -> Path:
    root = _private_root()
    path = root / f"viewflow-window-{secrets.token_hex(16)}.json"
    data = json.dumps(make_request(window_address), separators=(",", ":")).encode()
    if len(data) > 64 * 1024:
        raise ContractError("request exceeds HyprCapture request limit")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    return path


def read_response(path: Path, expected_address: str) -> dict[str, Any]:
    try:
        response = json.loads(_safe_private_file(path, MAX_JSON_BYTES))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError("invalid HyprCapture response JSON") from error
    if not isinstance(response, dict) or not isinstance(response.get("defaults"), dict):
        raise ContractError("response is missing defaults")
    if response["defaults"].get("mode") != "window":
        raise ContractError("response mode is not window")
    for key, expected in (("windowBorder", "keep"), ("windowShadow", "keep"),
                          ("windowBackground", "transparent")):
        if response["defaults"].get(key) != expected:
            raise ContractError(f"response changed capture policy: {key}")
    windows = response.get("windows")
    if not isinstance(windows, list) or len(windows) != 1 or not isinstance(windows[0], dict):
        raise ContractError("response must contain exactly one window")
    window = windows[0]
    if window.get("address") != expected_address:
        raise ContractError("response window identity does not match the selected address")
    artifact = window.get("artifactPath")
    width, height = window.get("artifactWidth"), window.get("artifactHeight")
    if (not isinstance(artifact, str) or not artifact or type(width) is not int or type(height) is not int):
        raise ContractError("response artifact metadata is invalid")
    if width < 1 or height < 1 or width > MAX_DIMENSION or height > MAX_DIMENSION or width * height * 4 > MAX_ARTIFACT_BYTES:
        raise ContractError("response artifact exceeds bounded size")
    visible, full = _rect(window.get("visibleGeometry"), "visibleGeometry"), _rect(window.get("fullGeometry"), "fullGeometry")
    if window.get("artifactTopDown") is not True:
        raise ContractError("only top-down HyprCapture artifacts are supported")
    return {"path": Path(artifact), "width": width, "height": height, "visibleGeometry": visible, "fullGeometry": full}


def rgba_to_premultiplied_bgra(rgba: bytes) -> bytes:
    if len(rgba) % 4:
        raise ContractError("RGBA payload is not pixel-aligned")
    output = bytearray(len(rgba))
    for offset in range(0, len(rgba), 4):
        red, green, blue, alpha = rgba[offset:offset + 4]
        output[offset:offset + 4] = bytes(((blue * alpha + 127) // 255, (green * alpha + 127) // 255,
                                             (red * alpha + 127) // 255, alpha))
    return bytes(output)


def import_response(path: Path, expected_address: str, output: Path) -> dict[str, Any]:
    metadata = read_response(path, expected_address)
    expected = metadata["width"] * metadata["height"] * 4
    rgba = _safe_private_file(metadata["path"], expected)
    if len(rgba) != expected:
        raise ContractError("artifact byte length does not match dimensions")
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = rgba_to_premultiplied_bgra(rgba)
    frame = struct.pack(">4sBBHIII", b"VFBG", 1, 1, 0, metadata["width"], metadata["height"], metadata["width"] * 4) + payload
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(output, flags, 0o600)
    except FileExistsError as error:
        raise ContractError("output already exists; refusing to replace it") from error
    try:
        offset = 0
        while offset < len(frame):
            written = os.write(fd, frame[offset:])
            if written <= 0:
                raise ContractError("failed writing VFBG output")
            offset += written
    except BaseException:
        os.close(fd)
        # Retain a failed partial output; never unlink a potentially replaced
        # directory entry after releasing the descriptor.
        raise
    else:
        os.close(fd)
    metadata["pixelFormat"] = "VFBG-premultiplied-BGRA"
    return metadata


def capture(window_address: str, output: Path, timeout: float) -> dict[str, Any]:
    request = write_request(window_address)
    expression = f"hl.plugin.hyprcapture.window_capture({json.dumps(str(request))})"
    # The plugin owns request replacement. Preserve failure evidence too.
    result = subprocess.run(["hyprctl", "eval", expression], text=True, capture_output=True, timeout=timeout, check=False)
    if result.returncode or "error" in result.stderr.lower():
        raise ContractError("HyprCapture Lua invocation failed")
    deadline = time.monotonic() + timeout
    while not request.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not request.exists():
        raise ContractError("HyprCapture did not produce a response")
    return import_response(request, window_address, output)


def main() -> int:
    parser = argparse.ArgumentParser(description="one-shot CPU HyprCapture to premultiplied BGRA adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("request", "capture"):
        command = sub.add_parser(name)
        command.add_argument("--window-address", required=True)
    sub.choices["request"].add_argument("--print-path", action="store_true")
    sub.choices["capture"].add_argument("--output", required=True, type=Path)
    sub.choices["capture"].add_argument("--timeout", type=float, default=5.0)
    accept = sub.add_parser("import-response")
    accept.add_argument("--response", required=True, type=Path)
    accept.add_argument("--window-address", required=True)
    accept.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "request":
            print(write_request(args.window_address))
        elif args.command == "import-response":
            print(json.dumps(import_response(args.response, args.window_address, args.output), default=str))
        else:
            if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 30:
                raise ContractError("timeout must be in (0, 30]")
            print(json.dumps(capture(args.window_address, args.output, args.timeout), default=str))
    except ContractError as error:
        print(f"hyprcapture adapter: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
