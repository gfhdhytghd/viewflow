"""Offline workspace controller checks; never contact a compositor."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('output_workspace',
    Path(__file__).resolve().parents[2] / 'tools/desktop-autostart-linux.py')
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)


class OutputWorkspaceTests(unittest.TestCase):
    def test_route_uses_distinct_named_underlay_and_explicit_dispatch(self):
        expression = workspace.special_workspace_expression('HEADLESS-9', 'viewflow-mac', 'viewflow-mac')
        self.assertIn('monitor:set_workspace("name:viewflow-mac-underlay")', expression)
        self.assertIn('monitor:set_special_workspace("viewflow-mac")', expression)
        self.assertIn('hl.dispatch(action)', expression)
        self.assertIn('follow = false', expression)
        self.assertNotIn('local number', expression)

    def test_reconcile_runs_even_with_special_already_active(self):
        # A special-workspace visibility check cannot detect stranded underlay windows.
        with patch.object(workspace.subprocess, 'run') as run:
            for _ in range(2):
                workspace.reconcile_special_workspace('HEADLESS-9')
        self.assertEqual(run.call_count, 2)
        self.assertIn('hl.get_workspace_windows(previous)', run.call_args.args[0][-1])

    def test_names_are_serialized(self):
        expression = workspace.special_workspace_expression('output"quote', 'route"quote')
        self.assertIn('output\\"quote', expression)
        self.assertIn('special:route\\"quote', expression)


if __name__ == '__main__':
    unittest.main()
