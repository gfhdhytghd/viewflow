"""One host-owned group: one host and at most two clients.

Only the current group's authenticated links may produce a runtime profile.
Legacy peer lists are archived, never run alongside the group.
"""
import copy
import ipaddress
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import threading
import time

import ifaddr
from zeroconf import IPVersion, ServiceBrowser, ServiceInfo, Zeroconf

import pairing_protocol as wire
from display_arrangement import arrange

SERVICE = '_viewflow._tcp.local.'
MAX_MEMBERS = 3


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.' + secrets.token_hex(6))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False)
    os.replace(temporary, path)


def local_addresses():
    addresses = set()
    for adapter in ifaddr.get_adapters():
        for entry in adapter.ips:
            value = entry.ip
            host = value if isinstance(value, str) else value[0]
            ip = ipaddress.ip_address(host.split('%', 1)[0])
            if ip.is_loopback or ip.is_unspecified or ip.is_multicast: continue
            if ip.version == 6 and ip.is_link_local:
                scope = value[2] if not isinstance(value, str) else 0
                if not scope: continue
                host = str(ip) + '%' + str(scope)
            addresses.add(host)
    return sorted(addresses, key=address_rank)


def address_rank(value):
    ip = ipaddress.ip_address(value.split('%', 1)[0])
    return (2 if ip.is_link_local else 0 if ip.version == 6 else 1, value)



def allocate_ports(excluded=()):
    sockets, ports = [], []
    try:
        while len(ports) < 4:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind(('0.0.0.0', 0)); sockets.append(sock)
            port = sock.getsockname()[1]
            if port not in excluded: ports.append(port)
        return dict(zip(('windows', 'atlas', 'clipboard', 'input'), ports))
    finally:
        for sock in sockets: sock.close()


def validate_group(value, host_id, local_id):
    wire.valid_id(value['id'])
    if value['host_id'] != host_id: raise ValueError('连接组主机身份不匹配。')
    members = value['members']
    if not isinstance(members, list) or not 1 <= len(members) <= MAX_MEMBERS:
        raise ValueError('连接组最多包含三台电脑。')
    for member in members:
        position = member.get('position')
        if position is not None and (not isinstance(position, list) or len(position) != 2 or any(type(v) is not int or abs(v) > 100000 for v in position)):
            raise ValueError('显示器坐标无效。')
    ids = [wire.validate_device(m['device'])['id'] for m in members]
    slots = [m['slot'] for m in members]
    if len(set(ids)) != len(ids) or ids[0] != host_id or local_id not in ids:
        raise ValueError('连接组成员无效。')
    if slots[0] != 0 or any(type(s) is not int or not 0 <= s < MAX_MEMBERS for s in slots) or len(set(slots)) != len(slots):
        raise ValueError('连接组位置无效。')
    return copy.deepcopy(value)


class PairingService:
    def __init__(self, directory, platform, display, *, name=None, port=wire.PORT,
                 host='', discovery=True, auto_resume=True):
        self.directory = Path(directory)
        self.events = queue.Queue()
        self.lock = threading.RLock()
        self.join_lock = threading.Lock()
        self.connect_lock = threading.Lock()
        self.closed = threading.Event()
        self.slots = threading.BoundedSemaphore(8)
        self.paused = False
        self.connected = set()
        self.wakeup = threading.Event()
        self.code, self.warning = '', ''
        self.failures, self.nearby, self.last_seen = {}, {}, {}
        self.active_sockets = set()
        self.browser = self.zeroconf = self.advertisement = None
        identity_path = self.directory / 'identity.json'
        if identity_path.exists():
            identity = json.loads(identity_path.read_text(encoding='utf-8'))
            wire.valid_id(identity['id'])
        else:
            identity = dict(id=secrets.token_hex(16), ports=allocate_ports())
            write_private(identity_path, identity)
        self.device = wire.validate_device(dict(identity, platform=platform,
            name=(name or socket.gethostname())[:120], display=display))
        self.state_path = self.directory / 'group.json'
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text(encoding='utf-8'))
            self._validate_state()
        else:
            self.state = dict(version=2, role='', group=None, links={}, retired={})
            legacy = self.directory / 'peers'
            if legacy.exists():
                archive = self.directory / 'legacy' / ('peers-' + str(time.time_ns()))
                archive.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                legacy.rename(archive)
                self.warning = '旧版配对已归档。请选择本机角色后重新配对。'
            self._save()
        if self.state["role"] == "host" and self.state["group"]:
            self._normalize_layout()
            self._save()
        dualstack = not host and socket.has_dualstack_ipv6()
        listen_host = '::' if dualstack else host
        def listen(selected_port):
            return socket.create_server((listen_host, selected_port),
                family=socket.AF_INET6 if dualstack or ':' in host else socket.AF_INET, dualstack_ipv6=dualstack)
        try: self.listener = listen(port)
        except OSError:
            if port != wire.PORT: raise
            self.listener = listen(0)
        self.port = self.listener.getsockname()[1]
        self.listener.settimeout(0.5)
        threading.Thread(target=self._accept, daemon=True).start()
        if discovery:
            try:
                self.zeroconf = Zeroconf(ip_version=IPVersion.All)
                self._advertise()
                self.browser = ServiceBrowser(self.zeroconf, SERVICE, self)
            except Exception as error:
                self.warning = '本地发现不可用；仍可输入主机地址。' + str(error)
        if self.state['group']: self._emit('restored')
        if auto_resume: threading.Thread(target=self._resume_loop, daemon=True).start()

    def _validate_state(self):
        state = self.state
        if state.get('version') != 2 or state.get('role') not in ('', 'host', 'client'):
            raise ValueError('本机连接组设置无效。')
        group, links = state.get('group'), state.get('links', {})
        if not group:
            if links: raise ValueError('连接不属于任何连接组。')
            return
        if state['role'] not in ('host', 'client'): raise ValueError('连接组缺少本机角色。')
        validate_group(group, group['host_id'], self.device['id'])
        ids = {m['device']['id'] for m in group['members']} - {self.device['id']}
        expected = ids if state['role'] == 'host' else {group['host_id']}
        if set(links) != expected or (state['role'] == 'host') != (group['host_id'] == self.device['id']):
            raise ValueError('连接组角色或成员不一致。')
        for identity, record in links.items():
            if wire.validate_device(record['device'])['id'] != identity or record['group_id'] != group['id']:
                raise ValueError('连接记录不属于当前连接组。')
            if wire.validate_device(record['local_device'])['id'] != self.device['id']:
                raise ValueError('连接记录的本机身份不匹配。')

    @property
    def peers(self): return self.state['links']

    def _save(self): write_private(self.state_path, self.state)

    def _emit(self, reason):
        self.events.put(dict(type='group', reason=reason, **self.connection_state()))

    def connection_state(self):
        with self.lock:
            return copy.deepcopy(dict(role=self.state['role'], group=self.state['group'],
                                      links=list(self.peers.values()), device=self.device,
                                      connected=list(self.connected) if not self.paused else [], paused=self.paused))

    def display_layout(self):
        group = self.state['group']
        if not group: return []
        edge = 0
        result = []
        for member in sorted(group['members'], key=lambda m: m['slot']):
            device = member['device']; display = device['display']
            position = member.get('position')
            if position is None and self.state['role'] == 'host' and device['id'] in self.peers:
                position = self.peers[device['id']]['local_device'].get('share_origin')
            x, y = position or [edge, 0]
            width, height = (round(display[k] / display['scale']) for k in ('width', 'height'))
            result.append(dict(id=device['id'], name=device['name'], x=x, y=y, width=width, height=height,
                host=device['id'] == group['host_id']))
            edge = max(edge, x + width)
        return result

    def _apply_layout(self, record):
        layout = {d['id']: d for d in self.display_layout()}
        local, peer = layout[self.device['id']], layout[record['device']['id']]
        record['local_device']['share_origin'] = [peer['x'] - local['x'], peer['y'] - local['y']]
        record['device']['share_origin'] = [local['x'] - peer['x'], local['y'] - peer['y']]
        record['device']['share_serial'] = 1

    def _normalize_layout(self, identity=None, x=None, y=None):
        if self.state['role'] != 'host' or not self.state['group']: return
        layout = arrange(self.display_layout(), identity, x, y)
        positions = {d['id']: [d['x'], d['y']] for d in layout}
        for member in self.state['group']['members']:
            member['position'] = positions[member['device']['id']]
        for record in self.peers.values(): self._apply_layout(record)

    def set_display_position(self, identity, x, y):
        if any(type(v) is not int or abs(v) > 100000 for v in (x, y)):
            raise ValueError('显示器坐标无效。')
        with self.lock:
            if self.state['role'] != 'host' or not self.state['group']:
                raise ValueError('请在主机上调整显示器位置。')
            if identity not in self.peers: raise ValueError('请选择连接组中的从机屏幕。')
            self._normalize_layout(identity, x, y)
            self._save()
        self._changed('updated')

    def _public_group(self):
        group = copy.deepcopy(self.state['group'])
        for member in group['members']:
            identity = member['device']['id']
            member['online'] = identity == self.device['id'] or time.monotonic() - self.last_seen.get(identity, -100) < 12
        return group

    def _advertise(self):
        if not self.zeroconf: return
        with self.lock:
            group = self.state['group']
            props = {k: str(self.device[k]) for k in ('id', 'name', 'platform')}
            props.update(version=str(wire.VERSION), role=self.state['role'],
                         group=group['id'] if group else '', members=str(len(group['members']) if group else 0))
            info = ServiceInfo(SERVICE, self.device['id'] + '.' + SERVICE,
                addresses=[ipaddress.ip_address(a.split('%', 1)[0]).packed for a in local_addresses()], port=self.port,
                properties=props, server='vf-' + self.device['id'] + '.local.')
        if self.advertisement: self.zeroconf.update_service(info)
        else: self.zeroconf.register_service(info)
        self.advertisement = info

    def _changed(self, reason):
        self._emit(reason)
        try: self._advertise()
        except Exception as error: self.warning = '本地发现更新失败；仍可输入主机地址。' + str(error)

    def snapshot(self):
        with self.lock:
            group = self.state['group']
            members = []
            for member in (group['members'] if group else []):
                device = member['device']; identity = device['id']
                members.append(dict(id=identity, name=device['name'], platform=device['platform'],
                    role='host' if identity == group['host_id'] else 'client', local=identity == self.device['id'],
                    address=self.peers.get(identity, {}).get('address', ''),
                    online=identity == self.device['id'] or time.monotonic() - self.last_seen.get(identity, -100) < 12
                        or (self.state['role'] == 'client' and identity != group['host_id'] and member.get('online', False))))
            machines = []
            if self.state['role'] == 'client' and not group:
                machines = [dict(item, paired=False, online=True) for item in self.nearby.values() if item['role'] == 'host']
            return dict(role=self.state['role'], groupID=group['id'] if group else '',
                hostID=group['host_id'] if group else '', members=members, count=len(members), maximum=MAX_MEMBERS,
                machines=sorted(machines, key=lambda item: item['name']), code=self.code,
                name=self.device['name'], port=self.port, addresses=[wire.endpoint(a, self.port) for a in local_addresses()],
                warning=self.warning, paused=self.paused, displays=self.display_layout())

    def _retire(self, identity, record):
        self.state['retired'][record['group_id'] + ':' + identity] = dict(secret=record['secret'])
        # Revocation receipts cannot produce a connection or runtime profile.
        while len(self.state['retired']) > 32:
            del self.state['retired'][next(iter(self.state['retired']))]

    def set_role(self, role):
        if role not in ('host', 'client'): raise ValueError('请选择主机或从机。')
        with self.lock:
            if role == self.state['role']: return
        self.leave_group(new_role=role)

    def leave_group(self, new_role=None):
        with self.lock:
            role, group = self.state['role'], self.state['group']
            target_role = new_role or role
        if role == 'client' and group:
            try: self.reconnect(mode='leave')
            except (OSError, ValueError): pass
        with self.lock:
            if role == 'host':
                for identity, record in self.peers.items(): self._retire(identity, record)
            self.state.update(role=target_role, links={}, group=None)
            if target_role == 'host':
                self.state['group'] = dict(id=secrets.token_hex(16), host_id=self.device['id'],
                    members=[dict(device=copy.deepcopy(self.device), slot=0)])
            self.code = ''; self.warning = ''; self.last_seen.clear(); self.connected.clear(); self.paused = False
            self._save()
        self._changed('reset')

    def remove_member(self, identity):
        with self.lock:
            if self.state['role'] != 'host': raise ValueError('只有主机可以移除成员。')
            record = self.peers.get(identity)
            if not record: raise ValueError('该电脑不在当前连接组中。')
            self._remove(identity, record)
        self._changed('removed')

    def _remove(self, identity, record):
        self._retire(identity, record)
        del self.peers[identity]
        self.state['group']['members'] = [m for m in self.state['group']['members'] if m['device']['id'] != identity]
        self.last_seen.pop(identity, None); self.connected.discard(identity)
        self._normalize_layout(); self._save()

    def show_code(self):
        with self.lock:
            if self.state['role'] != 'host': raise ValueError('只有主机可以显示配对码。')
            if len(self.peers) >= MAX_MEMBERS - 1: raise ValueError('连接组已满，最多三台电脑。')
            self.code = f'{secrets.randbelow(1000000):06d}'; self.failures.clear()
            return self.code

    def cancel_code(self):
        with self.lock: self.code = ''

    def add_service(self, zc, kind, name): self.update_service(zc, kind, name)

    def update_service(self, zc, kind, name):
        info = zc.get_service_info(kind, name, timeout=1500)
        if not info: return
        try:
            fields = {key.decode(): value.decode() for key, value in info.properties.items() if value is not None}
            identity = wire.valid_id(fields['id']); addresses = sorted(info.parsed_scoped_addresses(IPVersion.All), key=address_rank)
            if identity == self.device['id'] or not addresses or fields.get('version') != str(wire.VERSION): return
            if fields.get('platform') not in ('linux', 'windows', 'macos'): return
            if fields.get('role') not in ('host', 'client', ''): return
            with self.lock:
                self.nearby[identity] = dict(id=identity, name=fields.get('name', identity)[:120],
                    platform=fields['platform'], address=wire.endpoint(addresses[0], info.port),
                    addresses=[wire.endpoint(a, info.port) for a in addresses],
                    role=fields['role'], count=int(fields.get('members', '0')), service=name)
        except (ValueError, KeyError, UnicodeError): return

    def remove_service(self, zc, kind, name):
        with self.lock:
            self.nearby = {key: item for key, item in self.nearby.items() if item['service'] != name}

    def _accept(self):
        while not self.closed.is_set():
            try: sock, remote = self.listener.accept()
            except socket.timeout: continue
            except OSError: return
            if not self.slots.acquire(blocking=False): sock.close(); continue
            threading.Thread(target=self._serve, args=(sock, wire.socket_host(remote)), daemon=True).start()

    def _serve(self, sock, host):
        try:
            with sock:
                with self.lock: self.active_sockets.add(sock)
                sock.settimeout(15)
                hello = wire.receive(sock)
                peer_id = wire.valid_id(hello['id']); mode = hello.get('mode')
                if hello.get('version') != wire.VERSION or peer_id == self.device['id']:
                    raise ValueError('请更新两端 Viewflow 后再配对。')
                if mode not in ('pair', 'resume', 'leave', 'pause'): raise ValueError('invalid pairing mode')
                with self.lock:
                    record = self.peers.get(peer_id) if mode != 'pair' and self.state['role'] == 'host' else None
                    retired = self.state['retired'].get(str(hello.get('group')) + ':' + peer_id) if mode != 'pair' else None
                    if record and record['group_id'] != hello.get('group'): record = None
                    password = (record or retired or {}).get('secret', '') if mode != 'pair' else self.code
                    if mode == 'pair' and self.state['role'] != 'host': password = ''
                    failures = [t for t in self.failures.get(host, []) if time.monotonic() - t < 60]
                    if not password or (mode == 'pair' and len(failures) >= 6): raise ValueError('pairing unavailable')
                    if mode == 'pair': self.failures[host] = failures + [time.monotonic()]
                wire.send(sock, dict(version=wire.VERSION, id=self.device['id']))
                channel = wire.authenticate(sock, password, self.device['id'], peer_id, False)
                request = channel.receive()
                if retired and not record: channel.send(dict(status='left')); return
                device = wire.validate_device(request['device'])
                if device['id'] != peer_id or request.get('role') != 'client': raise ValueError('只有从机可以加入主机。')
                port = request['pairing_port']
                if type(port) is not int or not 1 <= port <= 65535: raise ValueError('invalid pairing port')
                if mode == 'pair': self._join(channel, device, host, port, request, password); return
                with self.lock:
                    current = self.peers.get(peer_id)
                    if self.state['role'] != 'host' or not current or current['secret'] != password:
                        channel.send(dict(status='left')); return
                    was_connected = peer_id in self.connected
                    if mode == 'pause' or (self.paused and mode == 'resume'):
                        self.connected.discard(peer_id)
                        channel.send(dict(status='paused'))
                        self._emit('disconnected')
                        return
                    if mode == 'leave':
                        self._remove(peer_id, current); channel.send(dict(status='left'))
                    else:
                        self.connected.add(peer_id)
                        previous = copy.deepcopy(current)
                        current.update(device=device, host=host, address=wire.endpoint(host, port))
                        self._update_member(device)
                        self._normalize_layout()
                        changed = not was_connected or previous != current
                        self.last_seen[peer_id] = time.monotonic(); self._update_member(device); self._save()
                        channel.send(dict(status='ok', group=self._public_group(), device=current['local_device'], peer_device=current['device']))
                if mode == 'leave': self._changed('removed')
                elif changed: self._changed('connected' if not was_connected else 'updated')
        except Exception:
            # Wrong codes/scans must not replace the foreground group's status.
            pass
        finally:
            with self.lock: self.active_sockets.discard(sock)
            self.slots.release()

    def _update_member(self, device):
        for member in self.state['group']['members']:
            if member['device']['id'] == device['id']: member['device'] = copy.deepcopy(device)

    def _join(self, channel, device, host, port, request, password):
        # Serialize admission, not live sessions: simultaneous submissions may
        # not exceed the three-computer group limit.
        with self.join_lock:
            peer_id = device['id']
            with self.lock:
                if self.state['role'] != 'host' or password != self.code:
                    channel.send(dict(status='error', message='配对码已更换，请重新输入。')); return
                previous = self.peers.get(peer_id)
                if not previous and len(self.peers) >= MAX_MEMBERS - 1:
                    channel.send(dict(status='error', message='连接组已满，最多三台电脑。')); return
                group = copy.deepcopy(self.state['group'])
                occupied = {m['slot'] for m in group['members'] if m['device']['id'] != peer_id}
                slot = previous['slot'] if previous else next(s for s in (1, 2) if s not in occupied)
                group['members'] = [m for m in group['members'] if m['device']['id'] != peer_id]
                group['members'].append(dict(device=device, slot=slot)); group['members'].sort(key=lambda m: m['slot'])
                excluded = {p for r in self.peers.values() for p in r['local_device']['ports'].values()}
                local = dict(self.device, ports=allocate_ports(excluded))
                # Existing members keep their desktop positions when a third
                # computer joins or another member leaves.
                edge = round(self.device['display']['width'] / self.device['display']['scale'])
                for other in self.peers.values():
                    origin = other['local_device'].get('share_origin', [edge, 0])
                    display = other['device']['display']
                    edge = max(edge, origin[0] + round(display['width'] / display['scale']))
                local['share_origin'] = previous['local_device'].get('share_origin', [edge, 0]) if previous else [edge, 0]
                local['share_serial'] = slot
            key = wire.new_key()
            issued = wire.issue_pair(self.device['id'], key, peer_id, request['public_key'])
            record = dict(device=device, local_device=local, slot=slot, group_id=group['id'],
                secret=secrets.token_hex(32), private_key=wire.private_key_pem(key),
                certificate=issued['local_certificate'], authority=issued['authority'],
                stream_id=secrets.token_hex(16), host=host, address=wire.endpoint(host, port))
            # Save before responding; lost final acknowledgements can resume.
            # A repeat join by the same device repairs a lost first response.
            with self.lock:
                if not self.state['group'] or self.state['group']['id'] != group['id']:
                    channel.send(dict(status='left')); return
                self.peers[peer_id] = record; self.state['group'] = group; self.connected.add(peer_id)
                for member in self.state['group']['members']:
                    if member['device']['id'] == peer_id: member['position'] = local['share_origin']
                self._normalize_layout(); self._save()
            self._changed('joined')
            channel.send(dict(status='ok', group=group, device=local, peer_device=record['device'], slot=slot,
                certificate=issued['peer_certificate'], authority=issued['authority'],
                secret=record['secret'], stream_id=record['stream_id']))
            if channel.receive() != {'ready': True}: raise ValueError('pairing not acknowledged')
            with self.lock:
                self.last_seen[peer_id] = time.monotonic(); self.failures.pop(host, None)
                if len(self.peers) >= MAX_MEMBERS - 1: self.code = ''
            channel.send(dict(saved=True))

    def connect(self, target, code='', peer_id=None):
        try:
            with self.connect_lock:
                with self.lock: alternatives = self.nearby.get(peer_id, {}).get('addresses', [])
                last = None
                for candidate in dict.fromkeys([target, *alternatives]):
                    try: return self._connect(candidate, code, peer_id, 'pair')
                    except (OSError, ValueError) as error: last = error
                if last: raise last
        except ValueError:
            raise
        except Exception as error:
            raise ValueError('无法加入主机，请检查配对码、地址，以及两端 Viewflow 版本。') from error

    def disconnect(self):
        with self.lock:
            self.paused = True
            self.connected.clear()
        self._emit('disconnected')
        try: self.reconnect(mode='pause')
        except (OSError, ValueError): pass

    def restart_connection(self):
        self.disconnect()
        with self.lock: self.paused = False
        self.wakeup.set()
        self._emit('waiting')
        if self.state['role'] == 'client':
            try: self.reconnect()
            except (OSError, ValueError):
                self.warning = '暂时无法联系主机，正在重连；连接组保留。'

    def reconnect(self, mode='resume'):
        with self.connect_lock:
            with self.lock:
                if self.state['role'] != 'client' or not self.state['group'] or (self.paused and mode == 'resume'): return
                identity = self.state['group']['host_id']; record = self.peers[identity]
                found = self.nearby.get(identity, {})
                candidates = found.get('addresses', [found.get('address', record['address'])])
                targets = list(dict.fromkeys([*candidates, record['address']]))
            last = None
            for target in targets:
                try: return self._connect(target, '', identity, mode)
                except (OSError, ValueError) as error: last = error
            if last: raise last


    def _connect(self, target, code, peer_id, mode):
        with self.lock:
            if self.state['role'] != 'client': raise ValueError('请先将本机设为从机。')
            existing_group = copy.deepcopy(self.state['group']); previous = self.peers.get(peer_id)
            if existing_group:
                if not previous: raise ValueError('本机已加入一个连接组，请先退出后再加入其他主机。')
                if mode == 'pair': mode = 'resume'
            if mode != 'pair' and not previous: raise ValueError('本机尚未加入连接组。')
        if mode == 'pair' and (len(code) != 6 or not code.isascii() or not code.isdigit()):
            raise ValueError('请输入主机显示的六位配对码。')
        host, port = wire.address(target); key = wire.new_key() if mode == 'pair' else None
        with socket.create_connection((host, port), timeout=15 if mode == 'pair' else 3) as sock:
            sock.settimeout(15)
            with self.lock: self.active_sockets.add(sock)
            try:
                wire.send(sock, dict(version=wire.VERSION, id=self.device['id'], mode=mode,
                    group=existing_group['id'] if existing_group else None))
                reply = wire.receive(sock); remote_id = wire.valid_id(reply['id'])
                if reply.get('version') != wire.VERSION: raise ValueError('请更新两端 Viewflow 后再配对。')
                if remote_id == self.device['id'] or (peer_id and remote_id != peer_id):
                    raise ValueError('所选主机身份不匹配。')
                channel = wire.authenticate(sock, code if mode == 'pair' else previous['secret'],
                    self.device['id'], remote_id, True)
                channel.send(dict(role='client', device=self.device, pairing_port=self.port,
                    public_key=wire.public_key(key) if key else None))
                response = channel.receive()
                if response.get('status') == 'error': raise ValueError(response['message'])
                if response.get('status') == 'paused':
                    with self.lock: self.connected.clear()
                    self._emit('disconnected')
                    return
                if response.get('status') == 'left':
                    with self.lock: self.state.update(group=None, links={}); self._save()
                    self._emit('left'); return
                if response.get('status') != 'ok': raise ValueError('主机未接受配对。')
                group = validate_group(response['group'], remote_id, self.device['id'])
                device = wire.validate_device(response['device'])
                if device['id'] != remote_id: raise ValueError('主机身份发生变化。')
                if mode == 'pair':
                    wire.validate_certificate(response['certificate'], response['authority'], key, self.device['id'])
                    if not isinstance(response['secret'], str) or len(response['secret']) != 64: raise ValueError('invalid reconnect secret')
                    wire.valid_id(response['stream_id'])
                    record = {k: response[k] for k in ('certificate', 'authority', 'secret', 'stream_id', 'slot')}
                    record.update(private_key=wire.private_key_pem(key), local_device=copy.deepcopy(self.device), group_id=group['id'])
                else: record = copy.deepcopy(previous)
                record['local_device'] = wire.validate_device(copy.deepcopy(response.get('peer_device', self.device)))
                if record['local_device']['id'] != self.device['id']: raise ValueError('本机显示器身份不匹配。')
                record.update(device=device, address=wire.endpoint(host, port), host=wire.socket_host(sock.getpeername()))
                with self.lock:
                    if self.state['role'] != 'client' or self.state['group'] != existing_group:
                        raise ValueError('本机角色或连接组已更改，请重试。')
                    newly_connected = remote_id not in self.connected
                    if self.paused and mode == 'resume': return
                    self.connected.add(remote_id)
                    changed = newly_connected or self.state['group'] != group or self.peers.get(remote_id) != record
                    self.state.update(group=group, links={remote_id: record}); self._save()
                    self.last_seen[remote_id] = time.monotonic(); self.warning = ''
                if changed or mode == 'pair': self._changed('joined' if mode == 'pair' else 'connected' if newly_connected else 'updated')
                if mode == 'pair':
                    channel.send(dict(ready=True))
                    if channel.receive() != {'saved': True}: raise ValueError('主机尚未确认配对，请重连。')
                return record
            finally:
                with self.lock: self.active_sockets.discard(sock)

    def _resume_loop(self):
        while not self.closed.is_set():
            try: self.reconnect()
            except Exception:
                # Transient control failures never tear down media/input.
                with self.lock:
                    if self.state['role'] == 'client' and self.state['group']:
                        self.warning = '暂时无法联系主机，正在重连；连接组保留。'
            self.wakeup.wait(3)
            self.wakeup.clear()

    def close(self):
        self.closed.set(); self.wakeup.set(); self.listener.close()
        with self.lock:
            for sock in tuple(self.active_sockets):
                try: sock.shutdown(socket.SHUT_RDWR)
                except OSError: pass
                sock.close()
        if self.browser: self.browser.cancel()
        if self.zeroconf:
            if self.advertisement:
                try: self.zeroconf.unregister_service(self.advertisement)
                except Exception: pass
            self.zeroconf.close()
