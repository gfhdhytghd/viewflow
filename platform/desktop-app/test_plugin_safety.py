import struct
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import plugin_safety


def elf(needed):
    """A sectionless ELF64 fixture; only program headers carry loader metadata."""
    data = bytearray(1024)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 2)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 0, 0, 0x1000, 0, len(data), len(data), 1)
    entries, strings = [], bytearray(b'\0')
    for name in needed:
        entries.append((1, len(strings)))
        strings += name.encode() + b'\0'
    entries += [(5, 0x1000 + 512), (10, len(strings)), (0, 0)]
    struct.pack_into('<IIQQQQQQ', data, 120, 2, 0, 256, 0x1100, 0, 16 * len(entries), 16 * len(entries), 8)
    for i, entry in enumerate(entries):
        struct.pack_into('<qQ', data, 256 + i * 16, *entry)
    data[512:512 + len(strings)] = strings
    return data


class PluginSafetyTests(unittest.TestCase):
    def test_rejects_host_dependencies_before_hyprctl(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'plugin.so'
            path.write_bytes(elf(['libaquamarine.so.14', 'libc.so.6']))
            with patch('sys.argv', ['plugin_safety.py', str(path)]), patch('subprocess.run') as run:
                with self.assertRaisesRegex(ValueError, 'second host library'):
                    plugin_safety.main()
                run.assert_not_called()

    def test_sectionless_plugin_and_truncated_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'plugin.so'
            path.write_bytes(elf(['libEGL.so.1', 'libc.so.6']))
            self.assertEqual(plugin_safety.needed_libraries(path), ['libEGL.so.1', 'libc.so.6'])
            plugin_safety.validate_plugin_for_load(path)
            path.write_bytes(path.read_bytes()[:100])
            with self.assertRaises(ValueError):
                plugin_safety.validate_plugin_for_load(path)


if __name__ == '__main__':
    unittest.main()
