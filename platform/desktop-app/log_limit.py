"""Keep each component log, together with its one rotated copy, within 20 MiB.

Components write their output through an inherited append-mode descriptor that
the supervisor cannot reopen. The supervisor therefore copies the full log to
``<name>.previous`` and truncates the live file in place; append-mode writers
continue at the new end of file without a restart.
"""
from pathlib import Path
import shutil

LOG_LIMIT = 20 * 1024 * 1024
# The live log and its rotated copy each hold at most half of the limit.
ROTATE_AT = LOG_LIMIT // 2


def previous_path(path):
    path = Path(path)
    return path.with_name(path.name + '.previous')


def limit_log(path, rotate_at=ROTATE_AT):
    """Rotate ``path`` once it exceeds ``rotate_at`` bytes. Return True after a rotation."""
    path = Path(path)
    try:
        if path.stat().st_size <= rotate_at:
            return False
        previous = previous_path(path)
        with path.open('rb') as source, previous.open('wb') as target:
            # A writer may append while the copy runs; keep the copy bounded.
            shutil.copyfileobj(_bounded(source, rotate_at), target)
        previous.chmod(path.stat().st_mode & 0o777)
        with path.open('r+b') as live:
            live.truncate(0)
        return True
    except OSError:
        # Logging must never stop a component.
        return False


def _bounded(stream, limit):
    """Read only the newest ``limit`` bytes."""
    stream.seek(0, 2)
    size = stream.tell()
    stream.seek(max(0, size - limit))
    return stream


def open_log(path):
    """Open a component log for appending, rotating an oversized one first."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    limit_log(path)
    return path.open('ab')
