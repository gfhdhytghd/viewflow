"""JSON-lines bridge for the macOS native app; stdout is protocol-only."""
import argparse
import json
import queue
import sys
import threading

from pairing_profiles import build_group_profile
from pairing_service import PairingService


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    parser.add_argument('--width', type=int, required=True)
    parser.add_argument('--height', type=int, required=True)
    parser.add_argument('--scale', type=float, required=True)
    args = parser.parse_args()
    commands = queue.Queue()
    def read_commands():
        try:
            for line in sys.stdin:
                if len(line) > 4096: continue
                try: commands.put(json.loads(line))
                except ValueError: pass
        finally: commands.put({'action': 'quit'})
    threading.Thread(target=read_commands, daemon=True).start()
    def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
    service = PairingService(args.directory, 'macos', dict(width=args.width, height=args.height, scale=args.scale))
    busy = threading.Event()
    def operation(command):
        try:
            action = command['action']
            if action == 'connect': service.connect(command['address'], command.get('code', ''), command.get('id') or None)
            elif action == 'setRole': service.set_role(command['role'])
            elif action == 'leaveGroup': service.leave_group()
            elif action == 'removeMember': service.remove_member(command['id'])
            elif action == 'reconnect': service.restart_connection()
            elif action == 'disconnect': service.disconnect()
            elif action == 'setDisplayPosition': service.set_display_position(command['id'], command['x'], command['y'])
        except Exception as error: service.events.put({'type': 'error', 'message': str(error)})
        finally: busy.clear()
    previous = None
    last_error = ''
    try:
        while True:
            try: command = commands.get(timeout=.2)
            except queue.Empty: command = {}
            action = command.get('action')
            if action == 'quit': break
            if action == 'showCode':
                try: service.show_code()
                except Exception as error: service.events.put(dict(type='error', message=str(error)))
            if action == 'cancelCode': service.cancel_code()
            if action in ('connect', 'setRole', 'leaveGroup', 'removeMember', 'reconnect', 'disconnect', 'setDisplayPosition') and not busy.is_set():
                last_error = ''
                busy.set()
                threading.Thread(target=operation, args=(command,), daemon=True).start()
            while True:
                try: event = service.events.get_nowait()
                except queue.Empty: break
                if event['type'] == 'group':
                    try: emit(dict(type='group', reason=event['reason'], profile=build_group_profile(event)))
                    except Exception as error:
                        last_error = str(error); emit(dict(type='error', message=last_error))
                else:
                    last_error = event.get('message', '')
                    emit(event)
            state = dict(type='state', busy=busy.is_set(), **service.snapshot())
            if last_error: state['warning'] = last_error
            if state != previous: emit(state); previous = state
    finally: service.close()


if __name__ == '__main__': main()
