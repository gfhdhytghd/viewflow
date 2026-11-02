import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import hyprland_plugins as plugins

COMMIT = 'a' * 40
VERSION = dict(commit=COMMIT, version='0.57.0', tag='v0.57.0', abiHash=COMMIT + '_abi')
BUILD = dict(commit=COMMIT, version='0.57.0', api_hash=VERSION['abiHash'], api_version='0.2')


class PluginSelectionTests(unittest.TestCase):
    def test_commit_and_api_hash_both_required(self):
        running = plugins.running_build(VERSION)
        variant = dict(BUILD, path='plugins/release/abi', line='release')
        self.assertEqual(plugins.exact_variant({'hyprland_variants': [variant]}, running), variant)
        for field in ('commit', 'api_hash'):
            with self.subTest(field=field):
                self.assertIsNone(plugins.exact_variant({'hyprland_variants': [dict(variant, **{field: 'different'})]}, running))

    def test_tags_never_select_abi(self):
        for tag in ('v0.57.0', 'main', 'fork'):
            self.assertIsNone(plugins.exact_variant({}, plugins.running_build(dict(VERSION, tag=tag))))
        with self.assertRaisesRegex(ValueError, 'full build commit'):
            plugins.running_build(dict(VERSION, commit='short'))
        with self.assertRaisesRegex(ValueError, 'abiHash'):
            plugins.running_build(dict(VERSION, abiHash=''))

    def test_older_fork_dependency_hash(self):
        version = dict(VERSION, abiHash='')
        for key, value in [('Aquamarine', '0.15.1'), ('Hyprutils', '0.14.2'), ('Hyprgraphics', '0.5.1'),
                           ('Hyprcursor', '0.1.13'), ('Hyprlang', '0.6.8')]:
            version['build' + key] = value
        self.assertEqual(plugins.running_build(version)['api_hash'], COMMIT + '_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6')

    def setup_bundle(self, root):
        bundle = root / 'bundle'
        for project in plugins.PROJECTS:
            path = bundle / 'plugin-source/platform' / project / 'CMakeLists.txt'
            path.parent.mkdir(parents=True)
            path.write_text('fixture')
        return bundle

    def test_exact_prebuilt_needs_no_headers_or_compiler(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            folder = bundle / 'plugins/release/abi'; folder.mkdir(parents=True)
            for name in plugins.PLUGINS: (folder / (name + '.so')).touch()
            manifest = {'hyprland_variants': [dict(BUILD, path='plugins/release/abi')]}
            with patch.object(plugins, 'header_build', side_effect=AssertionError('must not probe')):
                paths, status = plugins.resolve_plugins(bundle, manifest, VERSION)
            self.assertEqual(status, 'prebuilt')
            self.assertEqual(paths[0].parent, folder)
            manifest['hyprland_variants'][0]['path'] = '../escape'
            with self.assertRaisesRegex(ValueError, 'variant path'):
                plugins.resolve_plugins(bundle, manifest, VERSION)

    def test_header_mismatch_never_builds_or_loads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); bundle = self.setup_bundle(root)
            for mismatch in (dict(BUILD, commit='b'*40), dict(BUILD, api_hash='different')):
                with patch.object(plugins, 'header_build', return_value=mismatch), patch.object(plugins.subprocess, 'run') as run:
                    with self.assertRaisesRegex(RuntimeError, 'headers/compositor ABI mismatch'):
                        plugins.resolve_plugins(bundle, {}, VERSION, root / 'data')
                    run.assert_not_called()

    def test_build_cache_invalidation_and_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); bundle = self.setup_bundle(root)
            data = root / 'data'; calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                if '--build' in argv:
                    target = argv[-1]; build = Path(argv[2]); build.mkdir(parents=True)
                    (build / (target + '.so')).write_bytes(b'fixture ELF')
            with patch.object(plugins, 'header_build', return_value=BUILD), patch.object(plugins.subprocess, 'run', side_effect=run):
                paths, status = plugins.resolve_plugins(bundle, {}, VERSION, data)
                self.assertEqual(status, 'built')
                self.assertTrue(all(p.is_relative_to(data) for p in paths))
                self.assertEqual(len(calls), 4)
                with patch.object(plugins, 'header_build', side_effect=AssertionError('cached build needs no compiler')):
                    cached, status = plugins.resolve_plugins(bundle, {}, VERSION, data)
                self.assertEqual((cached, status), (paths, 'cached'))
                source = bundle / 'plugin-source/platform/hyprland-plugin/CMakeLists.txt'
                source.write_text('changed source')
                rebuilt, status = plugins.resolve_plugins(bundle, {}, VERSION, data)
                self.assertEqual(status, 'built'); self.assertNotEqual(rebuilt, paths)
                source.write_text('failing source')
                with patch.object(plugins.subprocess, 'run', side_effect=OSError('missing cmake')):
                    with self.assertRaisesRegex(RuntimeError, 'Build log:'):
                        plugins.resolve_plugins(bundle, {}, VERSION, data)
                self.assertEqual(source.read_text(), 'failing source')
                self.assertEqual(len(list(data.rglob('build.json'))), 2)


if __name__ == '__main__': unittest.main()
