"""Three-machine runtime composition using real loopback pairing, no OS input."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from pairing_service import PairingService
from pairing_profiles import build_group_profile
from runtime import materialize, validate_profile, SCRIPTS

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / 'dist/Viewflow-linux-20260922-pairing-r3'


class GroupProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def service(self, name, platform, role):
        service = PairingService(self.root/name, platform, dict(width=1920, height=1080, scale=1),
            name=name, port=0, host='127.0.0.1', discovery=False, auto_resume=False)
        self.addCleanup(service.close)
        if platform == 'windows': service.device['share_bounds'] = [-1920, 0, 0, 1080]
        service.set_role(role)
        return service

    def join(self, host, client):
        client.connect(f'127.0.0.1:{host.port}', host.show_code(), host.device['id'])

    def manifest(self, platform):
        programs = {name: 'bin/'+name for name in ('vf-window-peer', 'vf-media-peer', 'vf-clipboard-peer',
            'viewflow_linux_reverse', 'viewflow-windows-windows', 'viewflow_windows_reverse', 'viewflow_windows_composition_preview')}
        return dict(platform=platform, programs=programs, scripts=list(SCRIPTS))

    def test_linux_host_keeps_first_link_when_third_computer_joins(self):
        host = self.service('host', 'linux', 'host')
        mac = self.service('mac', 'macos', 'client')
        win = self.service('win', 'windows', 'client')
        self.join(host, mac)
        before = build_group_profile(host.connection_state())
        self.join(host, win)
        after = build_group_profile(host.connection_state())
        for section in ('configs', 'files'):
            self.assertTrue(all(after[section][key] == value for key, value in before[section].items()))
        for component in before['components']: self.assertIn(component, after['components'])
        self.assertEqual(after['groupID'], before['groupID'])
        self.assertEqual(len(after['components']), 6)
        binds = [value['bind'] for value in after['configs'].values() if 'bind' in value]
        self.assertEqual(len(binds), len(set(binds)))
        routes = [item['args'][-1] for item in after['components'] if item['program'] == 'paired-linux-session']
        self.assertEqual(len(set(routes)), 2)
        origins = [value['desktop']['remote_display']['x'] for value in after['configs'].values() if 'desktop' in value]
        self.assertEqual(origins, [1920, 3840])
        windows = build_group_profile(win.connection_state())
        receive = next(v for v in windows['configs'].values() if 'native_presenter' in v)
        self.assertEqual(receive['desktop']['display']['x'], 3840)
        mac_profile = build_group_profile(mac.connection_state())
        self.assertEqual(mac_profile['presentationOriginX'], -1920)
        for profile in (after, windows):
            manifest = self.manifest(profile['platform'])
            validate_profile(profile, manifest)
            materialize(profile, manifest, BUNDLE, self.root/profile['platform'])

    def test_group_preserves_mac_receiver_geometry_mode_per_peer(self):
        host = self.service('host', 'linux', 'host')
        mac = self.service('mac', 'macos', 'client')
        win = self.service('win', 'windows', 'client')
        self.join(host, mac); self.join(host, win)
        profile = build_group_profile(host.connection_state())
        receivers = {c['id']: c for c in profile['components'] if c['id'].endswith('-windows-receive')}
        self.assertEqual(receivers[mac.device['id'] + '-windows-receive']['environment'],
                         {'VIEWFLOW_REVERSE_MAC_SHADOW': '1'})
        self.assertNotIn('VIEWFLOW_REVERSE_MAC_SHADOW',
                         receivers[win.device['id'] + '-windows-receive'].get('environment', {}))

    def test_native_group_has_distinct_link_identities_and_parking_displays(self):
        host = self.service('host', 'macos', 'host')
        one = self.service('one', 'linux', 'client'); two = self.service('two', 'windows', 'client')
        self.join(host, one); self.join(host, two)
        profile = build_group_profile(host.connection_state())
        links = profile['groupConnections']
        self.assertEqual(len(links), 2)
        self.assertNotEqual(links[0]['privateKeyPEM'], links[1]['privateKeyPEM'])
        self.assertNotEqual(links[0]['inputBind'], links[1]['inputBind'])
        self.assertEqual([p['windowParking']['serial'] for p in links], [1, 2])
        self.assertEqual([p['windowParking']['x'] for p in links], [1920, 3840])
        self.assertTrue(all(p['windowDestinations'][0]['viewport'] == p['windowParking'] for p in links))
        client = build_group_profile(two.connection_state())
        receiver = next(v for k,v in client['configs'].items() if k.endswith('windows-receive.json'))
        self.assertIn('-3840', receiver['backend']['args'])

    def test_records_from_another_group_cannot_generate_workers(self):
        host = self.service('host', 'linux', 'host'); client = self.service('client', 'macos', 'client')
        self.join(host, client)
        state = host.connection_state(); state['links'][0]['group_id'] = 'f'*32
        with self.assertRaises(ValueError): build_group_profile(state)

    @unittest.skipUnless((BUNDLE/'bin/vf-window-peer').exists(), 'native validator bundle unavailable')
    def test_group_window_configs_pass_native_offline_validation(self):
        host = self.service('host', 'linux', 'host')
        for name, platform in [('mac', 'macos'), ('win', 'windows')]: self.join(host, self.service(name, platform, 'client'))
        profile = build_group_profile(host.connection_state())
        directory = self.root/'runtime'
        materialize(profile, self.manifest('linux'), BUNDLE, directory)
        for name in profile['configs']:
            if not name.endswith('windows-receive.json'): continue
            result = subprocess.run([str(BUNDLE/'bin/vf-window-peer'), 'validate', '--config', str(directory/name)],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
