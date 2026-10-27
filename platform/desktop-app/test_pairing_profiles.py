import itertools
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from pairing_profiles import build_profile, quality_mode
from pairing_protocol import new_key, issue_pair, public_key, private_key_pem
from runtime import materialize, validate_profile, SCRIPTS

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / 'dist/Viewflow-linux-20260921-media-r2'


def device(platform, identity, start):
    result = dict(platform=platform, id=identity * 32, name=platform,
        ports=dict(windows=start, clipboard=start+1, input=start+2, atlas=start+3),
        display=dict(width=1920, height=1080, scale=1))
    if platform == 'windows': result['share_bounds'] = [-1920, 120, 0, 1200]
    return result


class PairingProfileTests(unittest.TestCase):
    def profiles(self, first, second):
        a, b = device(first, 'a', 41000), device(second, 'b', 42000)
        ak, bk = new_key(), new_key()
        issued = issue_pair(a['id'], ak, b['id'], public_key(bk))
        def record(peer, key, certificate):
            return dict(device=peer, private_key=private_key_pem(key), certificate=certificate,
                        authority=issued['authority'], host='127.0.0.1', stream_id='c'*32)
        return (build_profile(a, record(b, ak, issued['local_certificate'])),
                build_profile(b, record(a, bk, issued['peer_certificate'])))

    def test_quality_mode_combines_to_the_more_conserving_choice(self):
        self.assertEqual(quality_mode('auto', 'auto'), 'auto')
        self.assertEqual(quality_mode('high_quality', 'auto'), 'auto')
        self.assertEqual(quality_mode('high_quality', 'high_quality'), 'high_quality')
        self.assertEqual(quality_mode('auto', 'save_bandwidth'), 'save_bandwidth')
        self.assertEqual(quality_mode('bogus', 'high_quality'), 'high_quality')
        # An unset peer has no preference and does not override a local choice.
        self.assertEqual(quality_mode('high_quality', None), 'high_quality')
        self.assertEqual(quality_mode(None, None), 'auto')

    def test_quality_mode_is_written_only_when_not_auto(self):
        for local_platform, remote_platform in itertools.permutations(('linux', 'windows', 'macos'), 2):
            local, peer = device(local_platform, 'a', 41000), device(remote_platform, 'b', 42000)
            for mode in ('auto', 'high_quality', 'save_bandwidth'):
                record = dict(device=peer, certificate='cert', private_key='key', authority='ca',
                              host='127.0.0.1', stream_id='c'*32, options=dict(quality_mode=mode))
                profile = build_profile(local, record)
                if local_platform == 'macos':
                    self.assertEqual(profile.get('qualityMode', 'auto'), mode)
                    continue
                for item in profile['components']:
                    if item['program'] == 'vf-clipboard-peer': continue
                    self.assertEqual(item['environment'].get('VIEWFLOW_QUALITY_MODE', 'auto'), mode)
                    if item['program'] in ('vf-window-peer', 'paired-linux-session'):
                        config = profile['configs'][item['id'] + '.json']
                        if mode == 'auto': self.assertNotIn('quality_mode', config)
                        else: self.assertEqual(config['quality_mode'], mode)

    def test_connection_options_cover_every_launch_mode(self):
        for local_platform, remote_platform in itertools.permutations(('linux', 'windows', 'macos'), 2):
            local, peer = device(local_platform, 'a', 41000), device(remote_platform, 'b', 42000)
            for enabled in (True, False):
                record = dict(device=peer, certificate='cert', private_key='key', authority='ca',
                              host='127.0.0.1', stream_id='c'*32,
                              options=dict(transparency=enabled, hid_forwarding=enabled))
                profile = build_profile(local, record)
                if local_platform == 'macos':
                    self.assertEqual(profile['transparency'], enabled)
                    self.assertEqual(profile['hidForwarding'], enabled)
                    continue
                for item in profile['components']:
                    if item['program'] == 'vf-clipboard-peer':
                        self.assertNotIn('environment', item)
                        continue
                    env = item['environment']
                    self.assertEqual(env['VIEWFLOW_TRANSPARENCY'], str(int(enabled)))
                    if item['program'] in ('vf-window-peer', 'paired-linux-session'):
                        self.assertEqual(profile['configs'][item['id']+'.json'].get('transparency', True), enabled)
                    if item['program'] == 'paired-linux-session':
                        self.assertEqual(profile['configs']['desktop-share.json']['pointer'].get('hid_forwarding', True), enabled)
                        self.assertEqual(env['VIEWFLOW_CURSOR_RAW_TOUCHPAD'], str(int(enabled and remote_platform == 'windows')))
                        self.assertEqual(env['VIEWFLOW_CURSOR_EXTERNAL_TOUCHPAD'], str(int(enabled and remote_platform == 'macos')))
                        self.assertTrue(profile['configs']['desktop-share.json']['pointer']['wheel'])
                record.pop('options')
                default = build_profile(local, record)
                if local_platform == 'linux':
                    # Defaults are omitted so older daemons still parse the config.
                    self.assertNotIn('hid_forwarding', default['configs']['desktop-share.json']['pointer'])
                    record['remote_options'] = dict(hid_forwarding=False)
                    fallback = build_profile(local, record)
                    self.assertFalse(fallback['configs']['desktop-share.json']['pointer']['hid_forwarding'])
                    env = next(c['environment'] for c in fallback['components'] if c['id'] == 'desktop-share')
                    self.assertEqual((env['VIEWFLOW_CURSOR_RAW_TOUCHPAD'], env['VIEWFLOW_CURSOR_EXTERNAL_TOUCHPAD']), ('0', '0'))

    def test_every_platform_pair_generates_local_allowlisted_profile(self):
        for first, second in itertools.combinations(('linux', 'windows', 'macos'), 2):
            for profile in self.profiles(first, second):
                if profile['version'] == 1:
                    self.assertTrue(profile['windowParking'])
                    self.assertEqual(len(profile['windowDestinations']), 1)
                    continue
                programs = {name: 'bin/' + name for name in ('vf-window-peer', 'vf-media-peer', 'vf-clipboard-peer',
                    'viewflow_linux_reverse', 'viewflow-windows-windows', 'viewflow_windows_reverse', 'viewflow_windows_composition_preview')}
                manifest = dict(platform=profile['platform'], programs=programs, scripts=list(SCRIPTS))
                validate_profile(profile, manifest)
                with tempfile.TemporaryDirectory() as directory:
                    materialize(profile, manifest, BUNDLE, Path(directory))
                    for name in profile['configs']:
                        parsed = json.loads((Path(directory) / name).read_text())
                        self.assertTrue(Path(parsed['private_key']).is_file())
                        self.assertNotIn('${', json.dumps(parsed))

    def test_linux_receiver_selects_source_coordinate_convention(self):
        for remote in ('macos', 'windows'):
            linux, _ = self.profiles('linux', remote)
            receiver = next(c for c in linux['components'] if c['id'] == 'windows-receive')
            self.assertEqual(receiver.get('environment', {}).get('VIEWFLOW_REVERSE_MAC_SHADOW'),
                             '1' if remote == 'macos' else None)

    def test_windows_parking_origin_is_translated_to_receiver(self):
        linux, windows = self.profiles('linux', 'windows')
        self.assertEqual(linux['configs']['windows-receive.json']['backend']['args'], ['1920', '-120', '1'])
        self.assertEqual(windows['configs']['windows-share.json']['backend']['args'], ['-1920', '120', '0', '1200'])
        linux, mac = self.profiles('linux', 'macos')
        self.assertEqual(linux['configs']['windows-receive.json']['backend']['args'][0], '-1920')
        self.assertEqual(mac['presentationOriginX'], -1920)

    @unittest.skipUnless((BUNDLE / 'bin/vf-media-peer').exists(), 'local built native peers unavailable')
    def test_generated_configs_pass_real_native_offline_validators(self):
        programs = {path.name: 'bin/' + path.name for path in (BUNDLE / 'bin').iterdir()}
        # The validator checks absolute paths, not launching presenter programs.
        programs['viewflow_windows_composition_preview'] = 'bin/viewflow_windows_composition_preview.exe'
        programs['viewflow_windows_reverse'] = 'bin/viewflow_windows_reverse.exe'
        programs['viewflow-windows-windows'] = 'bin/viewflow-windows-windows.exe'
        for pair in [('linux', 'windows'), ('linux', 'macos'), ('windows', 'macos')]:
            for profile in self.profiles(*pair):
                if profile['version'] == 1: continue
                manifest = dict(platform=profile['platform'], programs=programs, scripts=list(SCRIPTS))
                with tempfile.TemporaryDirectory() as directory:
                    data = Path(directory)
                    materialize(profile, manifest, BUNDLE, data)
                    for name, config in profile['configs'].items():
                        if 'role' in config: binary, mode = 'vf-window-peer', 'validate'
                        elif name == 'desktop-receive.json': binary, mode = 'vf-media-peer', 'validate-receive'
                        elif name == 'desktop-share.json':
                            binary, mode = 'vf-media-peer', 'validate-send'
                            prepared = json.loads((data / name).read_text())
                            prepared.pop('native_cursor', None)  # launcher-only, removed by prepare()
                            (data / name).write_text(json.dumps(prepared))
                        else: continue
                        result = subprocess.run([str(BUNDLE / 'bin' / binary), mode, '--config', str(data / name)],
                                                capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, (pair, name, result.stdout, result.stderr))


if __name__ == '__main__': unittest.main()
