import struct
import unittest
from linux_forward import Encoder, Device, EV_SYN, EV_ABS, SYN_REPORT, SYN_DROPPED, X


def contacts(frame):
    assert len(frame) == 32 and frame[0] == 1
    return [struct.unpack_from('<BBHH', frame, 1+6*i) for i in range(frame[31])]


class EncodingTests(unittest.TestCase):
    def test_mapping_lift_and_slot_reuse(self):
        e = Encoder((-100, 100), (-50, 50))
        a = contacts(e.frames({(0, 81): (-100, 50)})[0])
        self.assertEqual(a, [(3, 0, 0, 32767)])
        self.assertEqual(e.frames({(0, 81): (-100, 50)}), [])
        frames = e.frames({(0, 82): (100, -50)})
        self.assertEqual(contacts(frames[0]), [(2, 0, 0, 32767)])
        self.assertEqual(contacts(frames[1]), [(3, 1, 32767, 0)])
        self.assertEqual(contacts(e.frames({})[0])[0][0], 2)
        self.assertEqual(e.frames({}), [])

    def test_five_replacements_emit_lifts_before_new_ids(self):
        e = Encoder((0, 100), (0, 100))
        before = contacts(e.frames({(i, i): (10, 20) for i in range(5)})[0])
        result = e.frames({(i, i+10): (20, 30) for i in range(5)})
        self.assertEqual(len(result), 2)
        lifted, after = map(contacts, result)
        self.assertTrue(all(c[0] == 2 for c in lifted))
        self.assertEqual([c[1:] for c in lifted], [c[1:] for c in before])
        self.assertTrue(set(c[1] for c in before).isdisjoint(c[1] for c in after))

    def test_over_capacity_preserves_existing_contacts_and_recovers(self):
        e = Encoder((0, 1), (0, 1))
        snapshot = {(i, i): (0, 0) for i in range(6)}
        self.assertEqual(len(contacts(e.frames(snapshot)[0])), 5)
        del snapshot[(0, 0)]
        after = contacts(e.frames(snapshot)[-1])
        self.assertEqual(len(after), 5)
        self.assertEqual([c[1] for c in after], [1, 2, 3, 4, 5])

    def test_id_wrap_still_lifts_and_clamps(self):
        e = Encoder((0, 100), (0, 100))
        for i in range(260):
            frames = e.frames({(0, i): (-10, 110)})
            self.assertEqual(contacts(frames[-1])[0][2:], (0, 32767))
            if i:
                self.assertNotEqual(contacts(frames[0])[0][1], contacts(frames[1])[0][1])

    def test_syn_dropped_resync_ignores_incomplete_events(self):
        d = Device.__new__(Device)
        d.dropped = False; d.slot = 0; d.capacity = 1
        d.slots = [{0x39: 10, 0x35: 1, 0x36: 2}]
        def resync():
            d.slots = [{0x39: 11, 0x35: 3, 0x36: 4}]
        d.resync = resync
        d.event(EV_SYN, SYN_DROPPED, 0)
        d.event(EV_ABS, X, 99)
        self.assertEqual(d.event(EV_SYN, SYN_REPORT, 0), {(0, 11): (3, 4)})
        self.assertFalse(d.dropped)

if __name__ == '__main__':
    unittest.main()
