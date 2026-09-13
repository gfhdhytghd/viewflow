import struct
import unittest
import io
import json
import subprocess
import threading
from unittest.mock import patch
from linux_native_forward import ViewflowRoute, NativeRawDevice, AsyncRoute
from linux_native_forward import NativeEncoder, NativeDevice, captured_for_route, PRESSURE, MAJOR, MINOR, ORIENTATION, EV_KEY, BTN_LEFT
from linux_forward import TRACKING, X, Y, EV_ABS, EV_SYN, SYN_REPORT, SYN_DROPPED


def decode(p):
    return [struct.unpack_from('<BBHH6B', p, 12+i*12) for i in range(p[0])]


class NativeForwardTests(unittest.TestCase):
    def test_route_query_cannot_block_physical_report_reader(self):
        entered, release = threading.Event(), threading.Event()
        class Route:
            calls = 0
            def active(self):
                self.calls += 1
                if self.calls == 1:
                    return True
                entered.set()
                release.wait(1)
                return False
        route = AsyncRoute(Route(), interval=0.001)
        try:
            self.assertTrue(entered.wait(1))
            # The query is blocked, but report routing keeps its last owner.
            self.assertTrue(route.active())
            release.set()
            route.close()
            self.assertFalse(route.active())
        finally:
            release.set()
            route.close()

    def test_contact_state_five_does_not_lift_or_reallocate(self):
        d = NativeRawDevice.__new__(NativeRawDevice)
        d.contacts, d.button = {}, False
        e = NativeEncoder((-4067,4067),(-2603,2603))
        frames = []
        for tick,state in enumerate((3,4,5,4,5,7),100):
            bits = 100 | (200<<13) | (2<<26) | (state<<29)
            packet = bytes([0x31,0,0,0])+struct.pack('<I5B',bits,96,86,21,15,3|(4<<5))
            frames.append(e.frames(d.feed(packet),d.button,tick,preserve_cadence=True))
        for batch in frames[:-1]:
            self.assertEqual(len(batch),1)
            self.assertEqual(decode(batch[0]),decode(frames[0][0]))
            self.assertEqual(decode(batch[0])[0][1],1)
        self.assertEqual(decode(frames[-1][0])[0][1],0)
        self.assertEqual(frames[-1][-1][0],0)

    def test_reserved_classification_preserves_contact_click_and_release(self):
        d = NativeRawDevice.__new__(NativeRawDevice)
        d.contacts, d.button = {}, False
        e = NativeEncoder((-4067,4067),(-2603,2603))
        def packet(finger, state, button):
            bits = 100 | ((-200&8191)<<13) | (finger<<26) | (state<<29)
            return bytes([0x31,button,0,0])+struct.pack('<I5B',bits,96,86,21,15,3|(4<<5))
        with patch('sys.stderr', new_callable=io.StringIO) as log:
            begin = e.frames(d.feed(packet(7,3,1)),d.button,100,preserve_cadence=True)[0]
            move = e.frames(d.feed(packet(7,4,0)),d.button,110,preserve_cadence=True)[0]
            known = e.frames(d.feed(packet(5,4,0)),d.button,120,preserve_cadence=True)[0]
        self.assertEqual(log.getvalue().count('mapped to Undefined'),1)
        self.assertEqual(d.unknown_classifications,2)
        self.assertEqual([begin[1],move[1],known[1]],[1,0,0])
        self.assertEqual(decode(begin)[0][4:],(15,96,86,21,4,0))
        self.assertEqual(decode(begin),decode(move))
        self.assertEqual(decode(known)[0][:-1],decode(move)[0][:-1])
        self.assertEqual(decode(known)[0][-1],5)
        ended = e.frames(d.feed(packet(7,7,0)),d.button,130,preserve_cadence=True)
        self.assertEqual(decode(ended[0])[0][1],0)
        self.assertEqual(ended[-1][0],0)
        self.assertEqual(e.previous,{})

    def test_native_fields_survive_physical_click(self):
        d = NativeRawDevice.__new__(NativeRawDevice)
        d.contacts, d.button = {}, False
        bits = (100&8191) | ((-200&8191)<<13) | (5<<26) | (4<<29)
        contact = struct.pack('<I5B',bits,96,86,21,15,3|(4<<5))
        packet = bytes([0x31,1,0,0])+contact
        snap = d.feed(packet)
        self.assertTrue(d.button)
        e = NativeEncoder((-4067,4067),(-2603,2603))
        first = e.frames(snap,d.button,100,preserve_cadence=True)[0]
        c = decode(first)[0]
        self.assertEqual(c[4:],(15,96,86,21,4,5))
        # Do not turn physical pressure 15 into 120, Size 21 into 91, or
        # native finger classification 5 into a guessed index finger 2.
        next_frame = e.frames(snap,d.button,110,preserve_cadence=True)
        self.assertEqual(len(next_frame),1)
        self.assertEqual(decode(next_frame[0]),decode(first))
        snap = d.feed(bytes([0x31,0,0,0])+contact)
        up = e.frames(snap,d.button,120,preserve_cadence=True)[0]
        self.assertEqual(up[1],0)
        self.assertEqual(decode(up),decode(first))
        d.feed(bytes([0x31,0,0,0]))
        releases=e.frames(d.snapshot(),d.button,130,preserve_cadence=True)
        self.assertEqual(decode(releases[0])[0][1],0)
        self.assertEqual(releases[-1][0],0)
        self.assertEqual(e.frames({},False,140,preserve_cadence=True),[])
        self.assertIsNone(d.feed(b'\x90\x00'))
        with self.assertRaises(ValueError):d.feed(b'\x31\x00')
        with self.assertRaises(ValueError):d.feed(packet+contact)

    def test_query_failure_preserves_press_but_confirmed_return_releases(self):
        config = {'remote':'mac:44139', 'pointer':{'cursor_monitor_id':2}}
        status = {'connected':1, 'phase':3, 'remote':[2,0,0,100,100]}
        def opened(path, *args):
            if path == '/config': return io.StringIO(json.dumps(config))
            if str(path).endswith('cursor-ready'): return io.StringIO('123')
            return io.BytesIO(b'vf-cursor-peer\0--config\0/config\0')
        route = ViewflowRoute('/config', 'mac')
        encoder = NativeEncoder((0,100),(0,100))
        held = {(0,1):(50,50,20,80,80,0)}
        with patch('builtins.open', side_effect=opened), patch('os.readlink', return_value='/bin/vf-cursor-peer'), patch('subprocess.run') as run:
            run.side_effect = subprocess.TimeoutExpired('hyprctl', .2)
            self.assertFalse(route.active()) # no owner has been confirmed
            run.side_effect = None
            run.return_value.stdout = json.dumps(status)
            self.assertTrue(route.active())
            encoder.frames(held, True, 100)
            run.side_effect = subprocess.TimeoutExpired('hyprctl', .2)
            self.assertTrue(route.active())
            self.assertEqual(encoder.frames(held, True, 110), [])
            run.side_effect = None
            run.return_value.stdout = json.dumps(dict(status, phase=0))
            self.assertFalse(route.active())
            self.assertEqual(encoder.frames({}, False, 120)[-1][1], 0)
            run.return_value.stdout = json.dumps(status)
            self.assertTrue(route.active())
            config['remote'] = 'windows:44139'
            self.assertFalse(route.active())
            config['remote'] = 'mac:44139'
            run.side_effect = subprocess.TimeoutExpired('hyprctl', .2)
            self.assertFalse(route.active()) # old owner must not survive target change
            run.side_effect = None
            run.return_value.stdout = json.dumps(status)
            self.assertTrue(route.active())
            with patch('os.readlink', side_effect=FileNotFoundError):
                self.assertFalse(route.active())

    def test_viewflow_route_and_return_release(self):
        config = {'remote':'172.16.105.83:44139', 'pointer':{'cursor_monitor_id':2}}
        status = {'connected':1,'phase':3,'remote':[2,3072,390,1920,1200]}
        def active(s=status,c=config,alive=True):
            return captured_for_route(s,c,123,alive,'172.16.105.83')
        self.assertTrue(active())
        for phase in (0,1,2):
            self.assertFalse(active(dict(status,phase=phase)))
        self.assertFalse(active(dict(status,connected=0)))
        self.assertFalse(active(dict(status,remote=None)))
        self.assertFalse(active(dict(status,remote=[3,0,0,1920,1200])))
        self.assertFalse(active(c=dict(config,remote='172.16.105.70:44149')))
        self.assertFalse(active(alive=False))
        e=NativeEncoder((0,100),(0,100))
        held={(0,1):(10,10,20,80,80,0)}
        e.frames(held,True,100)
        # Control returns while fingers/button remain physically held. The
        # remote sees explicit lifts and button-up, then no local updates.
        release=e.frames({},False,110)
        self.assertEqual(decode(release[0])[0][1],0)
        self.assertEqual(release[0][1],0)
        self.assertEqual(e.frames({},False,120),[])
        self.assertEqual(decode(e.frames(held,True,130)[0])[0][1],1)

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
        expected = [tuple(list(c[:4]) + [120] + list(c[5:])) for c in decode(frame)]
        self.assertEqual(decode(clicked[0]), expected)

    def test_short_physical_click_pressure_and_timing(self):
        e = NativeEncoder((0,100), (0,100))
        snap = {(0,1):(50,50,5,80,80,0)}
        before = e.frames(snap,False,1000)[0]
        down = e.frames(snap,True,1010)[0]
        up = e.frames(snap,False,1120)[0]
        self.assertEqual([p[1] for p in (before,down,up)], [0,1,0])
        self.assertEqual([decode(p)[0][4] for p in (before,down,up)], [5,120,5])
        self.assertEqual([struct.unpack_from('<I',p,4)[0] for p in (before,down,up)], [1000,1010,1120])
        self.assertEqual(decode(before)[0][:4], decode(down)[0][:4])

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
