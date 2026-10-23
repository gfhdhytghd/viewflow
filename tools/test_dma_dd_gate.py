import unittest
from dma_dd_gate import ready

class GateTest(unittest.TestCase):
    def test_requires_same_completed_adopted_frame(self):
        submit='profile_dd_submit pts=31 id=1 capture=999 capture_clock=dxgi-last-present width=6144 height=3456 shared_source=1 completed=0\n'
        done='profile_dd_shared_ready pts=31 id=1 width=6144 height=3456 completed=1\n'
        self.assertTrue(ready(submit+done))
        self.assertFalse(ready(submit))
        self.assertFalse(ready(done))
        self.assertFalse(ready(submit+done.replace('pts=31','pts=32')))
        self.assertFalse(ready(submit.replace('shared_source=1','shared_source=0')+done))
        self.assertFalse(ready(submit.replace('width=6144','width=3072')+done))
        self.assertFalse(ready('profile_capture width=6144 height=3456\n'+done))

if __name__=='__main__':unittest.main()
