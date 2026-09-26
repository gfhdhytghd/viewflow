"""Local, allowlisted connection recipes; never execute a remote-supplied config."""
import base64
import copy

from pairing_protocol import endpoint, validate_device


def geometry(device, x=0):
    display = device['display']
    return dict(x=x, y=0, width=display['width'], height=display['height'], scale=display['scale'])


def build_profile(local, record):
    validate_device(local)
    peer = validate_device(record['device'])
    platform, remote_platform = local['platform'], peer['platform']
    server = 'vf-' + peer['id'] + '.local'
    remote = lambda service: endpoint(record['host'], peer['ports'][service])
    any_host = '::' if ':' in record['host'] else '0.0.0.0'
    bind = lambda service: endpoint(any_host, local['ports'][service])
    local_width = round(local['display']['width'] / local['display']['scale'])
    peer_width = round(peer['display']['width'] / peer['display']['scale'])
    peer_height = round(peer['display']['height'] / peer['display']['scale'])
    presentation_scale = max(1, round(local['display']['scale']))
    # Native tiles carry source-global coordinates. Translate the remote
    # parking viewport back onto this computer, not further off its screen.
    incoming_origin = -round(peer['display']['width'] / presentation_scale) if remote_platform == 'windows' else -peer_width
    incoming_y = 0
    if remote_platform != 'windows' and peer.get('share_origin'):
        incoming_origin, incoming_y = [-value for value in peer['share_origin']]
    if remote_platform == 'windows' and peer.get('share_bounds'):
        incoming_origin = -round(peer['share_bounds'][0] / presentation_scale)
        incoming_y = -round(peer['share_bounds'][1] / presentation_scale)
    if platform == 'macos':
        return dict(version=1, name=peer['name'], deviceID=local['id'], pairingDeviceID=peer['id'],
            certificatePEM=record['certificate'], privateKeyPEM=record['private_key'], authorityPEM=record['authority'],
            inputBind=bind('input'), windowsBind=bind('windows'), clipboardBind=bind('clipboard'),
            windowDestinations=[dict(id=peer['id'], address=remote('windows'), serverName=server,
                                     captureScale=max(1, round(peer['display']['scale'])), codec='h264')],
            clipboardRemote=dict(address=remote('clipboard'), serverName=server) if local['id'] < peer['id'] else None,
            windowParking=dict(serial=local.get('share_serial', 1), width=peer_width, height=peer_height,
                               x=local.get('share_origin', [local_width, 0])[0], y=local.get('share_origin', [local_width, 0])[1]),
            presentationScale=presentation_scale,
            presentationOriginX=incoming_origin, presentationOriginY=incoming_y, frameRate=60, maxWindows=8,
            performanceMode='frame-rate')
    profile = dict(version=2, platform=platform, name=peer['name'], peerID=peer['id'],
                   components=[], configs={}, files={})
    tls = {}
    for field, key, filename in [('certificate', 'certificate', 'device.pem'),
                                  ('private_key', 'private_key', 'device.key'),
                                  ('certificate_authority', 'authority', 'authority.pem')]:
        profile['files'][filename] = base64.b64encode(record[key].encode()).decode()
        tls[field] = '${profile}/' + filename

    def component(name, title, program, config=None, args=None):
        if config is not None: profile['configs'][name + '.json'] = dict(tls, **config)
        profile['components'].append(dict(id=name, title=title, program=program,
            args=args if args is not None else ['--config', '${profile}/' + name + '.json'], enabled=True))

    clipboard = dict(bind=bind('clipboard'))
    if local['id'] < peer['id']: clipboard.update(remote=remote('clipboard'), server_name=server)
    component('clipboard', '剪贴板同步', 'vf-clipboard-peer', clipboard)
    native = 'viewflow_linux_reverse' if platform == 'linux' else 'viewflow-windows-windows'
    # Incoming source coordinates begin just beyond the source's physical screen.
    presenter_args = [str(incoming_origin), str(incoming_y), str(presentation_scale)] if platform == 'linux' else ['--scale', str(presentation_scale), '--origin-x', str(incoming_origin), '--origin-y', str(incoming_y)]
    if remote_platform != 'linux' or platform == 'linux':
        component('windows-receive', '接收窗口', 'vf-window-peer', dict(bind=bind('windows'), role='presenter',
            backend=dict(native='${program:' + native + '}', args=presenter_args)))
        if platform == 'linux' and remote_platform == 'macos':
            # Mac metadata carries logical points; Windows metadata carries
            # physical pixels. Select the matching geometry and HID path.
            profile['components'][-1]['environment'] = {'VIEWFLOW_REVERSE_MAC_SHADOW': '1'}
    if platform == 'windows' and local.get('share_bounds'):
        component('windows-share', '共享 Windows 窗口', 'vf-window-peer', dict(bind=endpoint(any_host, 0),
            remote=remote('windows'), server_name=server, role='source',
            backend=dict(native='${program:viewflow_windows_reverse}',
                         args=list(map(str, local['share_bounds'])))))
    elif platform == 'windows':
        profile['notice'] = '正在启动接收窗口与剪贴板；共享 Windows 窗口需要一个已启用的虚拟显示器。'
    if platform == 'linux' or remote_platform == 'linux':
        linux = local if platform == 'linux' else peer
        receiver = peer if platform == 'linux' else local
        origin = round(linux['display']['width'] / linux['display']['scale'])
        display = geometry(receiver, origin)
        if linux.get('share_origin'):
            display.update(x=linux['share_origin'][0], y=linux['share_origin'][1])
        media = dict(stream_id=record['stream_id'], geometry_epoch=1, config_generation=1,
                     width=2048, height=2048, max_width=8192, max_height=4096, max_tiles=8,
                     max_encoded_bytes=134217728, max_decoded_bytes=268435456, refresh_hz=60)
        devices = dict(owner_device=receiver['id'], source_device=linux['id'])
        if platform == 'linux':
            source = dict(desktop=dict(topology_generation=1, local_display=geometry(local),
                remote_display=display, hyprland_socket='${profile}/pending-hyprland.sock',
                native_control_dir='${profile}/native-control', auto_enroll=True, max_enrolled_windows=8, candidates=[]),
                pointer=dict(devices=devices, native_socket='${profile}/pending-input.sock', wheel=True, direct_keyboard=True),
                capture_provider='viewflow', disposition_recovery=True, bind=bind('atlas'),
                remote=remote('atlas' if remote_platform == 'windows' else 'input'), server_name=server,
                compositor_pid=1, fps=60, startup_timeout_ms=10000, media_idle_timeout_ms=3000, media=media, windows=[])
            if remote_platform != 'windows':
                source['native_cursor'] = dict(x=0, y=0, width=peer_width, height=peer_height)
            component('desktop-share', '共享桌面与输入', 'paired-linux-session', source,
                ['--config', '${profile}/desktop-share.json', '--peer-platform', remote_platform,
                 '--window-remote', remote('windows'), '--runtime', '${profile}/session',
                 '--bundle', '${bundle}'])
        elif platform == 'windows':
            component('desktop-receive', '接收 Linux 桌面与输入', 'vf-media-peer',
                dict(desktop=dict(display=display, native_x=0, native_y=0), pointer=dict(devices, wheel=True, direct_keyboard=True),
                     disposition_recovery=True, input_recovery=True, bind=bind('atlas'), expected_peer_ip=record['host'].split('%', 1)[0],
                     native_presenter='${program:viewflow_windows_composition_preview}', **media,
                     startup_timeout_ms=10000, media_idle_timeout_ms=3000, clock_silence_timeout_ms=3000),
                ['receive', '--config', '${profile}/desktop-receive.json'])
    return profile


def build_group_profile(state):
    """Compose only the current group's star links into one runtime profile.

    Each transport link has separate certificates/ports, but the frontend owns
    one group and reconciles its workers together. Adding a member leaves the
    existing link's paths, identity, geometry and arguments unchanged.
    """
    group, links = state.get('group'), state.get('links', [])
    if not group or not links: return None
    from pairing_service import validate_group
    local = state['device']
    validate_group(group, group['host_id'], local['id'])
    if state['role'] == 'host':
        expected = {m['device']['id'] for m in group['members']} - {local['id']}
    else: expected = {group['host_id']}
    if {record['device']['id'] for record in links} != expected:
        raise ValueError('连接记录与当前连接组成员不一致。')
    if 'connected' in state:
        links = [record for record in links if record['device']['id'] in state['connected']]
    if not links: return None
    profiles = []
    for record in sorted(links, key=lambda item: item['slot']):
        if record['group_id'] != group['id']: raise ValueError('连接记录不属于当前连接组。')
        profiles.append(build_profile(record['local_device'], record))
    common = dict(groupID=group['id'], groupRole=state['role'],
                  groupHostID=group['host_id'], name=group['members'][0]['device']['name'][:96] + ' · Viewflow')
    if local['platform'] == 'macos':
        for link in profiles:
            for destination in link['windowDestinations']:
                destination['viewport'] = copy.deepcopy(link['windowParking'])
        # Native workers select the matching link identity rather than trying
        # to serve two peers with one pair's certificate or one port.
        profile = copy.deepcopy(profiles[0])
        profile.update(common, groupConnections=profiles)
        return profile
    result = dict(version=2, platform=local['platform'], components=[], configs={}, files={}, **common)
    notices = []
    for record, profile in zip(sorted(links, key=lambda item: item['slot']), profiles):
        prefix = record['device']['id'] + '-'
        def scoped(value):
            if isinstance(value, str): return value.replace('${profile}/', '${profile}/' + prefix)
            if isinstance(value, list): return [scoped(item) for item in value]
            if isinstance(value, dict): return {key: scoped(item) for key, item in value.items()}
            return value
        result['files'].update({prefix + name: value for name, value in profile['files'].items()})
        result['configs'].update({prefix + name: scoped(value) for name, value in profile['configs'].items()})
        for item in profile['components']:
            item = scoped(item)
            item['id'] = prefix + item['id']
            item['title'] = record['device']['name'] + ' · ' + item['title']
            item['peerID'] = record['device']['id']
            if item['program'] == 'paired-linux-session':
                item['args'] += ['--route', 'gui-' + local['id'][:16] + '-' + str(record['slot'])]
            result['components'].append(item)
        if profile.get('notice'): notices.append(profile['notice'])
    if notices: result['notice'] = '\n'.join(dict.fromkeys(notices))
    return result
