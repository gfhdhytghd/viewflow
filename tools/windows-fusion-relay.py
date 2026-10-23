#!/usr/bin/env python3
"""Keep the existing authenticated SSH control channel warm for fusion actions."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath
import select
import socket
import subprocess
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True,type=Path)
    args=parser.parse_args();config=json.loads(args.config.read_text())
    spec=importlib.util.spec_from_file_location('fusion',Path(__file__).with_name('windows-fusion.py'))
    fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
    path=fusion.control_socket(config);path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    lock=open(str(path)+'.lock','w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    path.unlink(missing_ok=True)
    server=socket.socket(socket.AF_UNIX);server.bind(str(path));os.chmod(path,0o600);server.listen(8)
    peer=config['ssh'];directory=config['guest_directory']
    script=str(PureWindowsPath(directory).parent/'viewflow_fusion_relay.exe')
    command=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2',
             '-o','HostKeyAlias='+peer['host_key_alias'],peer['user']+'@'+peer['host'],
             '"'+script+'"','"'+directory+'"']
    process=None
    try:
        while True:
            connection,_=server.accept()
            with connection:
                connection.settimeout(30)
                try:
                    with connection.makefile('rb') as stream: line=stream.readline(2*1024*1024)
                    payload=json.loads(line)
                    if process is None or process.poll() is not None:
                        process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE)
                    # Never replay an action after writing it: a missing reply
                    # does not mean Windows did not process the original action.
                    process.stdin.write(json.dumps(payload,ensure_ascii=False).encode()+b'\n');process.stdin.flush()
                    if not select.select([process.stdout],[],[],25)[0]:raise TimeoutError('Windows control reply timed out; action may still be pending')
                    reply=process.stdout.readline(2*1024*1024)
                    if not reply:raise RuntimeError('Windows control connection ended; action may still be pending')
                    json.loads(reply.decode('utf-8-sig'))
                    connection.sendall(reply)
                except Exception as error:
                    if process is not None:
                        process.terminate()
                        try: process.wait(timeout=2)
                        except subprocess.TimeoutExpired:process.kill();process.wait()
                        process=None
                    try:connection.sendall(json.dumps({'ok':False,'error':str(error)}).encode()+b'\n')
                    except OSError:pass
    finally:
        if process is not None:process.terminate()
        server.close();path.unlink(missing_ok=True)


if __name__=='__main__':main()
