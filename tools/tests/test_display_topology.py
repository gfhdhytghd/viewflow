import importlib.util
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('topology', Path(__file__).resolve().parents[1] / 'display_topology.py')
topology = importlib.util.module_from_spec(spec); spec.loader.exec_module(topology)

class TopologyTests(unittest.TestCase):
    local = dict(x=0, y=0, width=6144, height=3456, scale=2)
    remote = dict(x=3072, y=390, width=3840, height=2400, scale=2)
    hdmi = dict(kind='physical', name='HDMI', width=1920, height=1200, pixelsWidth=1920, pixelsHeight=1200)
    sidecar = dict(kind='sidecar', name='Sidecar Display', width=1539, height=1155, pixelsWidth=3078, pixelsHeight=2310)

    def get(self, right, sidecar):
        displays = [self.hdmi] + ([self.sidecar] if sidecar else [])
        return topology.plan(right, dict(displays=displays), self.local, self.remote)

    def test_windows_alone_does_not_connect_mac(self):
        value = self.get('windows', False)
        self.assertEqual(value['units'], [topology.WINDOWS])
        self.assertFalse(value['connected'])

    def test_windows_and_sidecar_keep_independent_routes(self):
        value = self.get('windows', True)
        self.assertIn(topology.WINDOWS, value['units'])
        self.assertIn(topology.SIDECAR, value['units'])
        self.assertNotIn(topology.MAC, value['units'])
        self.assertEqual(value['sidecar_native'], dict(x=0, y=0, width=1539, height=1155))
        self.assertEqual(value['anchor'], [3072, 1590])

    def test_mac_alone_keeps_right_geometry(self):
        value = self.get('macos', False)
        self.assertNotIn(topology.WINDOWS, value['units'])
        self.assertNotIn(topology.SIDECAR, value['units'])
        self.assertEqual(value['anchor'], [3072, 390])
        self.assertEqual(value['primary_remote'], self.remote)

    def test_mac_with_sidecar_keeps_two_mac_viewports_and_window_service(self):
        value = self.get('macos', True)
        self.assertNotIn(topology.WINDOWS, value['units'])
        self.assertTrue({topology.MAC, topology.SIDECAR, topology.SHARE}.issubset(value['units']))
        self.assertEqual(value['sidecar_native'], dict(x=0, y=1200, width=1539, height=1155))
        self.assertEqual(value['sidecar_remote'], dict(x=3072, y=1590, width=3078, height=2310, scale=2))

    def test_hdmi_inventory_not_ready_does_not_make_a_wrong_plan(self):
        with self.assertRaises(ValueError):
            topology.plan('macos', dict(displays=[self.sidecar]), self.local, self.remote)

    def test_sidecar_resolution_changes_propagate_to_capture_and_input(self):
        sidecar = dict(self.sidecar, width=1194, height=834, pixelsWidth=2388, pixelsHeight=1668)
        value = topology.plan('macos', dict(displays=[self.hdmi, sidecar]), self.local, self.remote)
        self.assertEqual(value['sidecar_remote']['width'], 2388)
        self.assertEqual(value['sidecar_native']['width'], 1194)

    def test_missing_primary_output_is_recreated_with_stable_name(self):
        responses = [
            '[]',
            'ok',
            '[{"name":"HEADLESS-1","disabled":false}]',
        ]
        with mock.patch.object(topology, 'run', side_effect=responses) as run:
            output = topology.ensure_primary_output('HEADLESS-1', self.remote)
        self.assertEqual(output['name'], 'HEADLESS-1')
        self.assertEqual(run.call_args_list[1].args[0],
                         ['hyprctl', 'output', 'create', 'headless', 'HEADLESS-1'])

    def test_disabled_primary_output_is_reenabled_before_route_start(self):
        responses = ['[{"name":"HEADLESS-1","disabled":true}]', 'ok']
        with mock.patch.object(topology, 'run', side_effect=responses) as run:
            topology.ensure_primary_output('HEADLESS-1', self.remote)
        command = run.call_args_list[1].args[0]
        self.assertEqual(command[:2], ['hyprctl', 'eval'])
        self.assertIn('disabled = false', command[2])

    def test_primary_output_name_is_not_interpreted_as_hyprctl_arguments(self):
        with self.assertRaises(ValueError):
            topology.ensure_primary_output('HEADLESS-1; dispatch exit', self.remote)

    def test_windows_fallback_restores_output_before_starting_route(self):
        supervisor = topology.Supervisor.__new__(topology.Supervisor)
        supervisor.settings = {'primary_output': 'HEADLESS-1'}
        supervisor.runtime = Path('/run/user/test/viewflow')
        supervisor.remote = self.remote
        supervisor.selected = lambda: 'windows'
        calls = []
        with (mock.patch.object(topology, 'active_units', return_value=set()),
              mock.patch.object(topology, 'save'),
              mock.patch.object(topology, 'ensure_primary_output', side_effect=lambda *args: calls.append('output')),
              mock.patch.object(topology, 'run', side_effect=lambda *args: calls.append(args[0]))):
            supervisor.keep_windows_available()
        self.assertEqual(calls, ['output', ['systemctl', '--user', 'start', topology.WINDOWS]])

if __name__ == '__main__': unittest.main()
