"""Exercise the actual QML JavaScript geometry without desktop input."""
import json
from pathlib import Path
import unittest
import os
os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["QT_QUICK_BACKEND"] = "software"
from PySide6.QtWidgets import QApplication
from PySide6.QtQml import QJSEngine

ROOT = Path(__file__).parent
class DisplaySnapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
    def test_snap_geometry_and_order_independence(self):
        engine=QJSEngine()
        loaded=engine.evaluate((ROOT/'qml/DisplaySnap.js').read_text())
        self.assertFalse(loaded.isError(), loaded.toString())
        for case in json.loads((ROOT/'tests/display_snap_cases.json').read_text()):
            with self.subTest(case=case['name']):
                args=[case[k] for k in ('moving','screens','x','y','zoom','settle')]
                result=engine.evaluate('snap('+','.join(json.dumps(v) for v in args)+')').toVariant()
                self.assertEqual([result['x'],result['y']],case['expected'])
                if case['settle']:
                    from display_arrangement import touches, overlaps
                    placed=dict(case['moving'],x=result['x'],y=result['y'])
                    others=[s for s in case['screens'] if s['id']!=placed['id']]
                    self.assertTrue(any(touches(placed,s) for s in others))
                    self.assertFalse(any(overlaps(placed,s) for s in others))
                args[1]=list(reversed(args[1]))
                reversed_result=engine.evaluate('snap('+','.join(json.dumps(v) for v in args)+')').toVariant()
                self.assertEqual(result,reversed_result)
                if case['name'] in ('far','no_distant_axis_snap','zoom_in_no_snap'):
                    self.assertEqual(result['guides'],[])
                else:self.assertTrue(result['guides'])
if __name__=='__main__':unittest.main()
