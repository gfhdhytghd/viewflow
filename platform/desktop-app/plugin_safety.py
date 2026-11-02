"""Preflight Viewflow plugins before dlopen can run dependency constructors."""
import os
from pathlib import Path
import struct
import subprocess
import sys

HOST_LIBRARIES = ('libaquamarine.so', 'libhyprutils.so', 'libhyprgraphics.so',
                  'libhyprcursor.so', 'libhyprlang.so')


def needed_libraries(path):
    """Read DT_NEEDED from ELF64 program headers, including stripped plugins."""
    data = Path(path).read_bytes()
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError(f'{path}: expected a little-endian ELF64 plugin')
    try:
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, count = struct.unpack_from('<HH', data, 54)
        if phsize < 56 or phoff + phsize * count > len(data):
            raise ValueError('invalid program headers')
        segments, dynamic = [], None
        for i in range(count):
            kind, _, offset, address, _, size, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + phsize * i)
            if offset + size > len(data):
                raise ValueError('truncated segment')
            if kind == 1:
                segments.append((address, offset, size))
            elif kind == 2:
                dynamic = (offset, size)
        if dynamic is None:
            raise ValueError('missing dynamic segment')
        needed, strings, string_size = [], None, None
        for offset in range(dynamic[0], sum(dynamic), 16):
            tag, value = struct.unpack_from('<qQ', data, offset)
            if tag == 0:
                break
            if tag == 1:
                needed.append(value)
            elif tag == 5:
                strings = value
            elif tag == 10:
                string_size = value
        if strings is None or string_size is None:
            raise ValueError('missing dynamic strings')
        base = next(off + strings - addr for addr, off, size in segments
                    if addr <= strings and strings + string_size <= addr + size)
        names = []
        for index in needed:
            if index >= string_size:
                raise ValueError('invalid dependency name')
            end = data.index(b'\0', base + index, base + string_size)
            names.append(data[base + index:end].decode('ascii'))
        return names
    except (struct.error, StopIteration, UnicodeError) as error:
        raise ValueError(f'{path}: invalid ELF dynamic table') from error


def validate_plugin_for_load(path):
    foreign = [name for name in needed_libraries(path)
               if name.startswith(HOST_LIBRARIES)]
    if foreign:
        raise ValueError(f'Refusing legacy plugin {path}: directly links {", ".join(foreign)}. '
                         'A second host library can destroy the compositor backend on unload. '
                         'Rebuild with host libraries unresolved; do not hot-unload an already loaded legacy build.')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: plugin_safety.py PLUGIN')
    validate_plugin_for_load(sys.argv[1])
    subprocess.run([os.environ.get('HYPRCTL', 'hyprctl'), 'plugin', 'load', sys.argv[1]], check=True)


if __name__ == '__main__':
    main()
