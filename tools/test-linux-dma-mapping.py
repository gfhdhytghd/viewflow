#!/usr/bin/env python3
"""Offline Mapping broker validation; no udmabuf, QEMU or GPU access."""
import array
import ctypes
import fcntl
import importlib.util
import json
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('banks', ROOT/'tools/qemu-dma-banks-launch.py')
banks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(banks)


def main():
    with tempfile.TemporaryDirectory(prefix='viewflow-mapping-test-') as temporary:
        directory = Path(temporary)
        source = directory/'test.cpp'
        source.write_text('''#include "platform/linux-reverse/shared_mapping.hpp"
#include <iostream>
int main(int argc,char** argv){
 if(argc!=3)return 9;
 try {
  auto mapping=std::make_shared<viewflow::reverse::shm::Mapping>(argv[1]);
  bool wanted=std::string(argv[2])=="dma";
  if(mapping->supports_dma_buffers()!=wanted)return 8;
  // Invalid dimensions must return locally, without opening udmabuf.
  if(mapping->dma_buffer(0,0,1,mapping))return 7;
  std::cout<<"accepted\\n";return 0;
 } catch(const std::exception& e){std::cerr<<e.what()<<"\\n";return 2;}
}
''')
        binary = directory/'test'
        subprocess.run(['g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT), str(source), '-o', str(binary)], check=True)
        control_path = directory/'control'
        with control_path.open('w+b') as control_file:
            control_file.truncate(1 << 20)
            control = mmap.mmap(control_file.fileno(), 1 << 20)
            struct.pack_into('<QQI4II', control, 1024, banks.BANK_MAGIC, banks.CAPACITY, 0, 6 << 16, 7 << 16, 8 << 16, 9 << 16, 0)
            fds = [os.memfd_create('viewflow-test-bank', os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING) for _ in range(4)]
            try:
                for fd in fds:
                    os.ftruncate(fd, banks.CAPACITY)
                    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK)
                metadata = banks.initialize(control, fds, 123456789, 0, 10)
                path = str(directory/'broker.sock')
                env = dict(os.environ, VIEWFLOW_DMA_BANK_SOCKET=path)
                cases = []
                def run_case(name, payload, descriptors, expected):
                    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    listener.bind(path)
                    listener.listen(1)
                    def serve():
                        connection, _ = listener.accept()
                        with connection:
                            assert connection.recv(64).startswith(b'GET')
                            connection.sendmsg([payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', descriptors))])
                    worker = threading.Thread(target=serve)
                    worker.start()
                    result = subprocess.run([str(binary), str(control_path), 'dma'], env=env, capture_output=True, text=True, timeout=5)
                    worker.join(5)
                    listener.close()
                    os.unlink(path)
                    assert result.returncode == expected, (name, result.returncode, result.stderr)
                    cases.append({'case': name, 'exit': result.returncode})
                encoded = json.dumps(metadata).encode()+b'\n'
                run_case('four-bank-valid', encoded, fds, 0)
                libc = ctypes.CDLL(None, use_errno=True)
                for fd in fds:
                    with mmap.mmap(fd, banks.CAPACITY) as pixel_mapping:
                        address = ctypes.addressof(ctypes.c_char.from_buffer(pixel_mapping))
                        residency = (ctypes.c_ubyte * (banks.CAPACITY // mmap.PAGESIZE))()
                        assert libc.mincore(ctypes.c_void_p(address), ctypes.c_size_t(banks.CAPACITY), residency) == 0
                        assert not any(value & 1 for value in residency), 'Opening broker populated a bank'
                cases.append({'case': 'all-four-banks-zero-residency', 'exit': 0})
                run_case('wrong-order-identity', encoded, list(reversed(fds)), 2)
                run_case('missing-fd', encoded, fds[:3], 2)
                run_case('extra-fd', encoded, fds+[fds[0]], 2)
                run_case('truncated-json', encoded[:30], fds, 2)
                bad = dict(metadata, generation=99)
                run_case('wrong-generation', json.dumps(bad).encode()+b'\n', fds, 2)
                bad = dict(metadata, owner_uid=metadata['owner_uid']+1)
                run_case('wrong-owner', json.dumps(bad).encode()+b'\n', fds, 2)
                fcntl.fcntl(fds[0], fcntl.F_ADD_SEALS, 0x0010)  # F_SEAL_FUTURE_WRITE
                run_case('future-write-sealed-rejected', encoded, fds, 2)
                # Legacy bank files retain the previous behavior.
                struct.pack_into('<Q', control, 1032, 4096)
                struct.pack_into('<I', control, 1060, 0)
                for i in range(4):
                    with open(str(control_path)+f'.slot{i}', 'wb') as output:
                        output.truncate(4096)
                result = subprocess.run([str(binary), str(control_path), 'legacy'], env=env, capture_output=True, text=True)
                assert result.returncode == 0, result.stderr
                cases.append({'case': 'legacy-files', 'exit': 0})
                print(json.dumps({'passed': True, 'cases': cases}, indent=2))
            finally:
                control.close()
                for fd in fds:
                    os.close(fd)


if __name__ == '__main__':
    main()
