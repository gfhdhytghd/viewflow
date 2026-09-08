import struct
import unittest
from linux_native_forward import NativeEncoder, NativeDevice, PRESSURE, MAJOR, MINOR, ORIENTATION, EV_KEY, BTN_LEFT
from linux_forward import TRACKING, X, Y, EV_ABS, EV_SYN, SYN_REPORT, SYN_DROPPED


def decode(p):
    return [struct.unpack_from('<BBHH6B', p, 12+i*12) for i in range(p[0])]


class NativeForwardTests(unittest.TestCase):
    def test_contacts_and_button_only_change(self):
        e = NativeEncoder((-100, 100), (-50, 50))
        snap = {(i,i): (i*10, i*5, 31, 160, 120, -2) for i in range(5)}
        frame = e.frames(snap, False, 10000)[0]
        self.assertEqual(len(frame), 72)
        self.assertEqual(len(decode(frame)), 5)
        self.assertEqual(decode(frame)[0][3:], (16384,31,40,30,35,6,2))
        self.assertEqual(e.peak, 5)
        self.assertEqual(e.frames(snap,False,10001), [])
        clicked = e.frames(snap,True,10002)
        self.assertEqual(len(clicked),1)
        self.assertEqual(clicked[0][1],1)
        self.assertEqual(decode(frame),decode(clicked[0]))

    def test_lift_and_reuse(self):
        e = NativeEncoder((0,100), (0,100))
        e.frames({(0,1):(10,10,20,80,80,0)},False,1)
        frames = e.frames({(0,2):(20,20,30,80,80,0)},False,2)
        self.assertEqual(len(frames),2)
        self.assertEqual(decode(frames[0])[0][1],0)
        self.assertNotEqual(decode(frames[0])[0][0],decode(frames[1])[0][0])
        self.assertEqual(decode(e.frames({},False,3)[0])[0][1],0)
        self.assertEqual(e.previous,{})

    def test_resync_and_extra_axes(self):
        d = NativeDevice.__new__(NativeDevice)
        d.capacity=1;d.slot=0;d.button=False;d.dropped=False
        d.extra=[PRESSURE,MAJOR,MINOR,ORIENTATION]
        d.slots=[{TRACKING:1,X:20,Y:30,PRESSURE:12,MAJOR:40,MINOR:20,ORIENTATION:0}]
        d.event(EV_KEY,BTN_LEFT,1)
        d.event(EV_ABS,PRESSURE,88)
        self.assertTrue(d.button)
        self.assertEqual(d.event(EV_SYN,SYN_REPORT,0)[(0,1)][2],88)
        d.event(EV_SYN,SYN_DROPPED,0)
        d.event(EV_KEY,BTN_LEFT,0)
        self.assertTrue(d.button) # ignore stale events until complete resync
        calls=[]
        def resync():
            calls.append(1);d.button=False;d.slots[0][TRACKING]=-1
        d.resync=resync
        self.assertEqual(d.event(EV_SYN,SYN_REPORT,0),{})
        self.assertEqual(calls,[1])
        self.assertFalse(d.button)

if __name__=='__main__':unittest.main()
