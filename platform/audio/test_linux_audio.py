import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('linux_audio', Path(__file__).with_name('linux_audio.py'))
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


class RoutingTests(unittest.TestCase):
    def test_received_audio_is_never_recaptured(self):
        received = {'properties': {'application.id': audio.APP_ID, 'application.process.id': '20'}}
        self.assertFalse(audio.selected(received, 'system', set()))
        self.assertFalse(audio.selected(received, 'application', {'20'}))
        self.assertTrue(audio.selected({'properties': {}}, 'system', set()))
        self.assertFalse(audio.selected({'properties': {}}, 'application', {'20'}))
        self.assertTrue(audio.selected({'properties': {'application.process.id': '20'}}, 'application', {'20'}))

    def test_capture_tracks_late_inputs_and_restores_observed_outputs(self):
        route = audio.Capture('system', [])
        streams = [{'index': 4, 'sink': 1, 'properties': {}},
                   {'index': 5, 'sink': 2, 'properties': {'application.id': audio.APP_ID}}]
        outputs = {1: 'speakers', 2: 'headphones', 3: route.name}
        commands = []
        def command(*args):
            commands.append(args)
            if args[0] == 'get-default-sink': return 'speakers'
            if args[0] == 'move-sink-input':
                stream = next(s for s in streams if s['index'] == args[1])
                stream['sink'] = next(i for i, name in outputs.items() if name == args[2])
            return ''
        with patch.object(audio, 'pactl', command), patch.object(audio, 'sinks', lambda: outputs), patch.object(audio, 'inputs', lambda: streams):
            route.reconcile()
            self.assertEqual(streams[0]['sink'], 3)
            self.assertEqual(streams[1]['sink'], 2)
            streams.append({'index': 6, 'sink': 2, 'properties': {}})
            route.reconcile()
            route.module = 71
            route.close()
        self.assertEqual(streams[0]['sink'], 1)
        self.assertEqual(streams[2]['sink'], 2)
        self.assertIn(('unload-module', 71), commands)
        self.assertFalse(any(c[0] == 'set-default-sink' for c in commands))

    def test_stop_preserves_user_rerouting_away_from_private_sink(self):
        route = audio.Capture('system', [])
        route.module = 72; route.original[4] = 'speakers'
        streams = [{'index': 4, 'sink': 2}]
        commands = []
        def command(*args):
            commands.append(args)
            return 'speakers' if args[0] == 'get-default-sink' else ''
        with patch.object(audio, 'pactl', command), patch.object(audio, 'sinks', lambda: {1: 'speakers', 2: 'headphones', 3: route.name}), patch.object(audio, 'inputs', lambda: streams):
            route.close()
        self.assertFalse(any(c[0] == 'move-sink-input' for c in commands))

if __name__ == '__main__': unittest.main()
