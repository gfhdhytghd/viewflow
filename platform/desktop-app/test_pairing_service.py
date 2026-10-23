import concurrent.futures
import json
from pathlib import Path
import tempfile
import unittest

from pairing_service import PairingService


class PairingServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def service(self, name, platform='linux', role=None):
        service = PairingService(self.root / name, platform,
            dict(width=1920, height=1080, scale=1), name=name,
            port=0, host='127.0.0.1', discovery=False, auto_resume=False)
        self.addCleanup(service.close)
        if role: service.set_role(role)
        return service

    def join(self, host, client, code=None):
        return client.connect(f'127.0.0.1:{host.port}', code or host.show_code(), host.device['id'])

    def test_numeric_gap_is_normalized_in_saved_and_runtime_positions(self):
        from pairing_profiles import build_group_profile
        host, client = self.service('gap-host', role='host'), self.service('gap-client', 'macos', 'client')
        self.join(host, client)
        host.set_display_position(client.device['id'], 4000, 222)
        client.reconnect()
        member=next(m for m in host.state['group']['members'] if m['device']['id']==client.device['id'])
        self.assertEqual(member['position'],[1920,222])
        source=build_group_profile(host.connection_state())['configs'][client.device['id']+'-desktop-share.json']
        self.assertEqual((source['desktop']['remote_display']['x'],source['desktop']['remote_display']['y']),(1920,222))
        self.assertEqual(client.peers[host.device['id']]['device']['share_origin'],[1920,222])

    def test_ipv6_pair_resume_and_runtime_addresses(self):
        import socket
        from pairing_profiles import build_group_profile
        if not socket.has_ipv6: self.skipTest('IPv6 not available')
        host = PairingService(self.root/'v6host', 'linux', dict(width=1920,height=1080,scale=1),
            port=0, host='::1', discovery=False, auto_resume=False)
        self.addCleanup(host.close); host.set_role('host')
        client = self.service('v6client', 'macos', 'client')
        client.connect(f'[::1]:{host.port}', host.show_code(), host.device['id'])
        client.reconnect()
        self.assertEqual(client.peers[host.device['id']]['host'], '::1')
        self.assertEqual(host.peers[client.device['id']]['host'], '::1')
        profile = build_group_profile(client.connection_state())
        self.assertTrue(profile['windowsBind'].startswith('[::]:'))
        self.assertTrue(profile['windowDestinations'][0]['address'].startswith('[::1]:'))

    def test_discovery_failure_falls_back_to_saved_address(self):
        host, client = self.service('fallback-host', role='host'), self.service('fallback-client', role='client')
        self.join(host, client)
        client.nearby[host.device['id']] = dict(address='[::1]:1', addresses=['[::1]:1'])
        client.reconnect()
        self.assertTrue(client.connected)

    def test_display_positions_sync_both_directions_and_persist(self):
        from pairing_profiles import build_group_profile
        host, mac = self.service('layout-host', role='host'), self.service('layout-mac', 'macos', 'client')
        win = self.service('layout-win', 'windows', 'client')
        win.device['share_bounds'] = [-1920,0,0,1080]
        self.join(host, mac); self.join(host, win)
        stable = dict(host.peers[win.device['id']]['local_device'])
        host.set_display_position(mac.device['id'], -1920, 240)
        mac.reconnect()
        self.assertEqual(host.peers[win.device['id']]['local_device']['share_origin'], [1920,0])
        self.assertEqual(host.peers[win.device['id']]['local_device']['ports'], stable['ports'])
        source = build_group_profile(host.connection_state())['configs'][mac.device['id']+'-desktop-share.json']
        self.assertEqual((source['desktop']['remote_display']['x'],source['desktop']['remote_display']['y']), (-1920,240))
        receiver = build_group_profile(mac.connection_state())
        self.assertEqual((receiver['presentationOriginX'],receiver['presentationOriginY']), (1920,-240))
        self.assertEqual((receiver['windowParking']['x'],receiver['windowParking']['y']), (1920,-240))
        self.assertEqual(host.snapshot()['displays'], mac.snapshot()['displays'])
        before = host.connection_state(); mac.reconnect()
        self.assertEqual(host.connection_state(), before)
        host.close()
        restored = self.service('layout-host')
        self.assertEqual(restored.snapshot()['displays'], host.snapshot()['displays'])
        with self.assertRaises(ValueError): mac.set_display_position(host.device['id'], 0, 0)
        with self.assertRaises(ValueError): restored.set_display_position(mac.device['id'], 100001, 0)

    def test_manual_disconnect_retains_pairing_and_reconnect_restores_both_sides(self):
        from pairing_profiles import build_group_profile
        host, client = self.service('host', role='host'), self.service('client', role='client')
        self.join(host, client)
        group = client.snapshot()['groupID']
        client.disconnect()
        self.assertTrue(client.snapshot()['paused'])
        self.assertIsNone(build_group_profile(client.connection_state()))
        self.assertIsNone(build_group_profile(host.connection_state()))
        client.reconnect()  # polling cannot override explicit disconnect
        self.assertFalse(client.connected)
        client.restart_connection()
        self.assertEqual(client.snapshot()['groupID'], group)
        self.assertIsNotNone(build_group_profile(client.connection_state()))
        self.assertIsNotNone(build_group_profile(host.connection_state()))
        host.disconnect()
        client.reconnect()
        self.assertFalse(client.connected)
        host.restart_connection()  # host waits; only client initiates
        self.assertFalse(host.connected)
        client.reconnect()
        self.assertTrue(host.connected)
        self.assertTrue(client.connected)

    def test_client_startup_resumes_without_button_and_host_waits(self):
        import time
        host, client = self.service('host', role='host'), self.service('client', role='client')
        self.join(host, client)
        client.disconnect(); client.close()
        restored = PairingService(self.root/'client', 'linux', dict(width=1920,height=1080,scale=1),
            port=0, host='127.0.0.1', discovery=False)
        self.addCleanup(restored.close)
        for _ in range(100):
            if restored.connected: break
            time.sleep(.02)
        self.assertTrue(restored.connected)
        self.assertFalse(restored.paused)
        self.assertTrue(host.connected)

    def test_one_host_two_clients_and_isolated_links(self):
        host = self.service('host', role='host')
        mac = self.service('mac', 'macos', 'client')
        win = self.service('win', 'windows', 'client')
        code = host.show_code()
        first = self.join(host, mac, code)
        self.assertEqual(host.code, code)  # The second client uses the displayed code too.
        second = self.join(host, win, code)
        self.assertEqual(host.code, '')
        mac.reconnect()
        groups = [s.snapshot()['groupID'] for s in (host, mac, win)]
        self.assertEqual(len(set(groups)), 1)
        self.assertEqual([s.snapshot()['count'] for s in (host, mac, win)], [3, 3, 3])
        self.assertEqual(len(host.peers), 2)
        self.assertEqual(len(mac.peers), 1)
        self.assertEqual(len(win.peers), 1)
        local_ports = [set(r['local_device']['ports'].values()) for r in host.peers.values()]
        self.assertFalse(local_ports[0] & local_ports[1])
        self.assertNotEqual(first['private_key'], host.peers[mac.device['id']]['private_key'])
        self.assertNotEqual(first['authority'], second['authority'])
        self.assertEqual(host.snapshot()['machines'], [])
        self.assertEqual(mac.snapshot()['machines'], [])
        with self.assertRaises(ValueError): host.show_code()

    def test_roles_are_enforced_in_service_not_only_ui(self):
        host, client = self.service('host', role='host'), self.service('client', role='client')
        with self.assertRaises(ValueError): client.show_code()
        with self.assertRaises(ValueError): host.connect(f'127.0.0.1:{client.port}', '123456')
        unset = self.service('unset')
        with self.assertRaises(ValueError): unset.show_code()
        with self.assertRaises(ValueError): self.join(host, unset)

    def test_client_cannot_join_a_second_group(self):
        first, second = self.service('first', role='host'), self.service('second', role='host')
        client = self.service('client', role='client')
        self.join(first, client)
        original = client.connection_state()
        with self.assertRaisesRegex(ValueError, '先退出'): self.join(second, client)
        self.assertEqual(client.connection_state(), original)
        self.assertEqual(len(second.peers), 0)

    def test_simultaneous_admission_never_exceeds_three(self):
        host = self.service('host', role='host')
        clients = [self.service(f'client{i}', role='client') for i in range(3)]
        code = host.show_code()
        def join(client):
            try: self.join(host, client, code); return True
            except Exception: return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            results = list(executor.map(join, clients))
        self.assertEqual(sum(results), 2)
        self.assertEqual(host.snapshot()['count'], 3)
        self.assertEqual(sum(bool(client.peers) for client in clients), 2)

    def test_restart_and_resume_without_code(self):
        host = self.service('host', role='host'); client = self.service('client', role='client')
        original = self.join(host, client)
        group_id = host.snapshot()['groupID']
        host.close()
        host = self.service('host')
        self.assertEqual(host.snapshot()['groupID'], group_id)
        client.nearby[host.device['id']] = dict(address=f'127.0.0.1:{host.port}')
        resumed = client.reconnect()
        self.assertEqual(resumed['certificate'], original['certificate'])
        self.assertEqual(host.snapshot()['count'], 2)

    def test_wrong_code_and_identity_do_not_join(self):
        host = self.service('host', role='host'); client = self.service('client', role='client')
        code = host.show_code(); wrong = '000000' if code != '000000' else '111111'
        with self.assertRaises(Exception): self.join(host, client, wrong)
        with self.assertRaises(ValueError): client.connect(f'127.0.0.1:{host.port}', code, 'f'*32)
        self.assertFalse(client.peers)
        self.assertFalse(host.peers)
        self.assertEqual(host.code, code)

    def test_remove_dissolve_and_role_change_clear_only_current_group(self):
        host = self.service('host', role='host'); one = self.service('one', role='client')
        two = self.service('two', role='client')
        self.join(host, one); self.join(host, two)
        second_link = host.peers[two.device['id']].copy()
        host.remove_member(one.device['id']); one.reconnect(); two.reconnect()
        self.assertFalse(one.peers)
        self.assertEqual(host.peers[two.device['id']], second_link)
        self.assertEqual(two.snapshot()['count'], 2)
        host.set_role('client'); two.reconnect()
        self.assertFalse(two.peers)
        self.assertIsNone(host.state['group'])
        self.assertIsNone(two.state['group'])

    def test_client_leave_frees_slot(self):
        host = self.service('host', role='host'); client = self.service('client', role='client')
        self.join(host, client); client.leave_group()
        self.assertEqual(host.snapshot()['count'], 1)
        self.assertEqual(client.snapshot()['role'], 'client')
        self.assertFalse(client.peers)

    def test_host_unavailable_keeps_group(self):
        host = self.service('host', role='host'); client = self.service('client', role='client')
        self.join(host, client); before = client.connection_state(); host.close()
        with self.assertRaises(OSError): client.reconnect()
        self.assertEqual(client.connection_state(), before)

    def test_legacy_peers_are_archived_and_never_activated(self):
        legacy = self.root / 'migrated' / 'peers'; legacy.mkdir(parents=True)
        (legacy / 'old.json').write_text(json.dumps(dict(secret='old')))
        service = self.service('migrated')
        self.assertFalse(service.peers)
        self.assertEqual(service.snapshot()['role'], '')
        self.assertFalse(legacy.exists())
        self.assertEqual(len(list((self.root / 'migrated/legacy').glob('peers-*/old.json'))), 1)


if __name__ == '__main__': unittest.main()
