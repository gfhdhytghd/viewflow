import random
import unittest
from display_arrangement import arrange, overlaps, touches

class ArrangementTests(unittest.TestCase):
    def screens(self):
        return [dict(id='host',host=True,x=0,y=0,width=3072,height=1728),
                dict(id='mac',host=False,x=3072,y=222,width=1920,height=1200),
                dict(id='win',host=False,x=4992,y=222,width=1920,height=1080)]
    def assert_connected(self, screens):
        seen={screens[0]['id']}
        while True:
            new=seen|{a['id'] for a in screens if any(b['id'] in seen and touches(a,b) for b in screens)}
            if new==seen:break
            seen=new
        self.assertEqual(len(seen),len(screens))
        for i,a in enumerate(screens):
            for b in screens[i+1:]:self.assertFalse(overlaps(a,b))
    def test_gap_keeps_vertical_offset_and_closes_horizontal_gap(self):
        result=arrange(self.screens()[:2],'mac',4072,222)
        self.assertEqual((result[1]['x'],result[1]['y']),(3072,222))
        self.assert_connected(result)
    def test_bridge_movement_and_removal_leave_no_isolated_display(self):
        self.assert_connected(arrange(self.screens(),'mac',-4000,200))
        self.assert_connected(arrange([self.screens()[0],self.screens()[2]]))
    def test_corner_is_not_an_edge_and_old_gap_is_repaired(self):
        s=self.screens()[:2];s[1].update(x=3072,y=1728)
        self.assertFalse(touches(*s));self.assert_connected(arrange(s))
    def test_random_drag_and_numeric_positions_stay_connected_and_stable(self):
        randomizer=random.Random(42)
        for _ in range(500):
            screens=arrange(self.screens(),randomizer.choice(['mac','win']),randomizer.randint(-15000,15000),randomizer.randint(-15000,15000))
            self.assert_connected(screens)
            self.assertEqual(screens,arrange(screens))
