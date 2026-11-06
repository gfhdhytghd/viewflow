"""Offline ordered matrix: no native workers, input or compositor access."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from runtime import Worker
import unittest
from pairing_profiles import build_profile
from test_pairing_profiles import device

PLATFORMS = ('linux', 'windows', 'macos')

def pair(first, second, *, hid=False):
    a, b = device(first, 'a', 41000), device(second, 'b', 42000)
    for d in (a, b):
        d.update(handoff_version=1, handoff_port=d['ports']['input']+10, name='same-hostname')
    a['share_origin'] = [1920, 0]
    b['share_origin'] = [-1920, 0]
    def profile(local, peer):
        return build_profile(local, dict(device=peer, host='127.0.0.1', certificate='fixture',
            private_key='fixture', authority='fixture', stream_id='c'*32,
            options=dict(hid_forwarding=hid)))
    return a, b, profile

def handoff(profile):
    return profile.get('desktopHandoff') if 'desktopHandoff' in profile else profile['configs'].get('desktop-handoff.json')

class HandoffProfiles(unittest.TestCase):
    def test_all_nine_ordered_pairs_have_both_input_only_roles(self):
        for first, second in itertools.product(PLATFORMS, repeat=2):
            with self.subTest(controller=first, target=second):
                a, b, profile = pair(first, second)
                left, right = handoff(profile(a,b)), handoff(profile(b,a))
                self.assertIsNotNone(left); self.assertIsNotNone(right)
                for cfg, local, remote in ((left,a,b),(right,b,a)):
                    self.assertTrue(cfg['sender']); self.assertTrue(cfg['receiver'])
                    self.assertEqual(cfg['device_id'], local['id']); self.assertEqual(cfg['peer_id'], remote['id'])
                    self.assertEqual(cfg['remote'].rsplit(':',1)[1], str(remote['handoff_port']))
                    self.assertNotIn('media', cfg); self.assertNotIn('native_presenter', cfg)
                self.assertEqual(left['peer']['x'], -right['peer']['x'])

    @unittest.skipUnless(os.environ.get('VIEWFLOW_HANDOFF_TEST_BINARY'), 'handoff validator binary not selected')
    def test_rust_validator_accepts_all_nine_native_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            for first, second in itertools.product(PLATFORMS, repeat=2):
                a,b,profile=pair(first,second)
                cfg=dict(handoff(profile(a,b)))
                cfg.update(native=str(Path(directory)/'native'), certificate=str(Path(directory)/'cert'),
                           private_key=str(Path(directory)/'key'), certificate_authority=str(Path(directory)/'ca'))
                path=Path(directory)/'profile.json';path.write_text(json.dumps(cfg))
                result=subprocess.run([os.environ['VIEWFLOW_HANDOFF_TEST_BINARY'],'validate','--config',str(path)],
                                      text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('handoff-config-valid',result.stdout)

    def test_native_hid_compatibility_direction_is_preserved(self):
        a,b,profile=pair('linux','macos',hid=True)
        local=profile(a,b)
        self.assertFalse(handoff(local)['sender'])
        self.assertTrue(handoff(local)['receiver'])
        self.assertEqual(next(c for c in local['components'] if c['id']=='desktop-share')['environment']['VIEWFLOW_CURSOR_EXTERNAL_TOUCHPAD'],'1')
        self.assertTrue(handoff(profile(b,a))['sender'])

    def test_capability_and_edge_absence_do_not_remove_other_lanes(self):
        a,b,profile=pair('windows','windows')
        for change in ('old_peer','gap','corner'):
            with self.subTest(change=change):
                local,peer=dict(a),dict(b)
                if change=='old_peer':peer.pop('handoff_version')
                if change=='gap':local['share_origin']=[1921,0]
                if change=='corner':local['share_origin']=[1920,1080]
                result=profile(local,peer)
                self.assertIsNone(handoff(result))
                self.assertIn('clipboard',{c['id'] for c in result['components']})
                self.assertIn('windows-receive',{c['id'] for c in result['components']})
                self.assertIn('notice',result)

    def test_capability_status_is_visible_without_stopping_other_workers(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'status';path.write_text('sender unavailable; receiver available')
            process=SimpleNamespace(poll=lambda:None)
            worker=Worker(dict(id='handoff'),[],Path(directory),
                          environment={'VIEWFLOW_HANDOFF_STATUS_FILE':str(path)},desired=True,process=process)
            other=Worker(dict(id='clipboard'),[],Path(directory),desired=True,process=process,status='running')
            worker.tick();other.tick()
            self.assertIn('sender unavailable',worker.status)
            self.assertEqual(other.status,'running')
            self.assertIs(worker.process,process)

    def test_four_edges_and_partial_overlap(self):
        a,b,profile=pair('linux','linux')
        for origin in ([1920,100],[-1920,-100],[100,1080],[-100,-1080]):
            a['share_origin']=origin
            result=profile(a,b)
            self.assertIsNotNone(handoff(result))
            source=next(c for c in result['components'] if c['id']=='desktop-share')
            self.assertEqual(source['environment']['VIEWFLOW_CURSOR_WINDOW_ONLY'],'1')

if __name__ == '__main__': unittest.main()
