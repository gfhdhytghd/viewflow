#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import desktop_peer_discovery as peer
spec = importlib.util.spec_from_file_location('autostart', Path(__file__).resolve().parents[1] / 'desktop-autostart-linux.py')
autostart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(autostart)

class DiscoveryTests(unittest.TestCase):
    def config(self):
        return {'remote': 'WindowsVM:44149', 'peer_discovery': {
            'hostname':'WindowsVM', 'hostnames':['WindowsVM.local'],
            'mac':'52:54:00:12:34:56', 'ssh_user':'wilf', 'ssh_host_key_alias':'viewflow-windows'}}

    def test_changed_ip_uses_nic_and_checks_existing_host_identity(self):
        rows=[{'dst':'192.0.2.31','lladdr':'52:54:00:12:34:56','state':['STALE']},
              {'dst':'192.0.2.32','lladdr':'00:00:00:00:00:02','state':['REACHABLE']}]
        commands=[]
        def run(cmd, **kwargs):
            commands.append(cmd)
            return subprocess.CompletedProcess(cmd, 0 if cmd[0]=='ssh' else 2,
                                               'WindowsVM\r\n' if cmd[0]=='ssh' else '', '')
        with patch.object(peer.subprocess,'check_output',return_value=json.dumps(rows)), patch.object(peer.subprocess,'run',side_effect=run):
            self.assertEqual(peer.resolve(self.config()), '192.0.2.31:44149')
        ssh=next(cmd for cmd in commands if cmd[0]=='ssh')
        self.assertIn('HostKeyAlias=viewflow-windows',ssh)
        self.assertIn('StrictHostKeyChecking=yes',ssh)
        self.assertIn('wilf@192.0.2.31',ssh)

    def test_hostname_without_neighbor_entry(self):
        def run(cmd, **kwargs):
            return subprocess.CompletedProcess(cmd,0,'192.0.2.44 STREAM WindowsVM\n' if cmd[0]=='getent' else 'WindowsVM\n','')
        with patch.object(peer.subprocess,'check_output',return_value='[]'), patch.object(peer.subprocess,'run',side_effect=run):
            self.assertEqual(peer.resolve(self.config()),'192.0.2.44:44149')

    def test_wrong_host_or_untrusted_key_does_not_match(self):
        for rc,name in [(0,'OtherPC'),(255,'WindowsVM')]:
            def run(cmd, **kwargs):
                return subprocess.CompletedProcess(cmd,rc,'192.0.2.44 STREAM WindowsVM\n' if cmd[0]=='getent' else name,'')
            with patch.object(peer.subprocess,'check_output',return_value='[]'), patch.object(peer.subprocess,'run',side_effect=run):
                with self.assertRaises(RuntimeError): peer.resolve(self.config())

    def test_runtime_removes_discovery_metadata_and_preserves_template(self):
        config=self.config() | {'pointer':{},'desktop':{}}
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'template.json';p.write_text(json.dumps(config))
            with patch.object(peer,'resolve',return_value='192.0.2.99:44149'):
                result=autostart.prepare(p, {'pid':1,'instance':'test'},
                    {'x':0,'y':0,'width':100,'height':100,'scale':1},Path('/tmp'))
            self.assertEqual(result['remote'],'192.0.2.99:44149')
            self.assertNotIn('peer_discovery',result)
            self.assertEqual(json.loads(p.read_text()),config)

if __name__=='__main__': unittest.main()
