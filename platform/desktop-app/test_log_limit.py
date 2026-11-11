import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from log_limit import LOG_LIMIT, ROTATE_AT, limit_log, open_log, previous_path


class LogLimitTest(unittest.TestCase):
    def test_small_log_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'peer.log'
            log.write_bytes(b'x' * 100)
            self.assertFalse(limit_log(log, rotate_at=1000))
            self.assertEqual(log.stat().st_size, 100)
            self.assertFalse(previous_path(log).exists())

    def test_rotation_keeps_newest_bytes_and_bounds_total(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'peer.log'
            log.write_bytes(b'a' * 600 + b'b' * 600)
            self.assertTrue(limit_log(log, rotate_at=1000))
            self.assertEqual(log.stat().st_size, 0)
            self.assertEqual(previous_path(log).read_bytes(), b'a' * 400 + b'b' * 600)

    def test_append_writer_continues_after_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'peer.log'
            with open_log(log) as stream:
                # A child inherits the append-mode descriptor, as the supervisors do.
                child = subprocess.Popen([sys.executable, '-c',
                    'import sys,time\nsys.stdout.write("x"*2000);sys.stdout.flush()\n'
                    'sys.stdin.readline()\nsys.stdout.write("tail");sys.stdout.flush()'],
                    stdin=subprocess.PIPE, stdout=stream, text=True)
                while log.stat().st_size < 2000:
                    pass
                self.assertTrue(limit_log(log, rotate_at=1000))
                child.communicate('\n', timeout=10)
            # No sparse gap at the old offset: the writer resumed at offset zero.
            self.assertEqual(log.read_bytes(), b'tail')

    def test_limit_is_twenty_mebibytes(self):
        self.assertEqual(LOG_LIMIT, 20 * 1024 * 1024)
        self.assertEqual(ROTATE_AT * 2, LOG_LIMIT)


if __name__ == '__main__':
    unittest.main()
