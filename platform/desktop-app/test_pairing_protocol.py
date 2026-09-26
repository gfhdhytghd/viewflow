import socket
import threading
import unittest

from cryptography.exceptions import InvalidTag
import pairing_protocol as wire


class PairingProtocolTests(unittest.TestCase):
    def channels(self, password_a='123456', password_b='123456'):
        a, b = socket.socketpair()
        a.settimeout(5); b.settimeout(5)
        self.addCleanup(a.close); self.addCleanup(b.close)
        result = {}
        def serve():
            try: result['b'] = wire.authenticate(b, password_b, 'b' * 32, 'a' * 32, False)
            except Exception as error: result['error'] = error
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try: result['a'] = wire.authenticate(a, password_a, 'a' * 32, 'b' * 32, True)
        except Exception as error: result['client_error'] = error
        thread.join(5)
        self.assertFalse(thread.is_alive())
        return result

    def test_pairing_and_authenticated_bidirectional_records(self):
        result = self.channels()
        self.assertEqual(set(result), {'a', 'b'})
        result['a'].send({'name': '我的电脑'})
        self.assertEqual(result['b'].receive(), {'name': '我的电脑'})
        result['b'].send({'ports': [1, 2]})
        self.assertEqual(result['a'].receive(), {'ports': [1, 2]})

    def test_wrong_code_never_authenticates(self):
        result = self.channels(password_b='123457')
        self.assertNotIn('a', result)
        self.assertNotIn('b', result)
        self.assertIsInstance(result['client_error'], InvalidTag)

    def test_each_side_keeps_its_private_key(self):
        a, b = wire.new_key(), wire.new_key()
        pair = wire.issue_pair('a' * 32, a, 'b' * 32, wire.public_key(b))
        self.assertNotIn('PRIVATE KEY', str(pair))
        wire.validate_certificate(pair['local_certificate'], pair['authority'], a, 'a' * 32)
        wire.validate_certificate(pair['peer_certificate'], pair['authority'], b, 'b' * 32)
        with self.assertRaises(ValueError):
            wire.validate_certificate(pair['peer_certificate'], pair['authority'], a, 'b' * 32)

    def test_ipv6_scope_is_local_to_receiving_socket(self):
        self.assertEqual(wire.socket_host(('fe80::1', 44331, 0, 4)), 'fe80::1%4')
        self.assertEqual(wire.socket_host(('::ffff:192.0.2.1', 44331, 0, 0)), '192.0.2.1')

    def test_manual_addresses(self):
        for text, expected in [('computer.local', ('computer.local', wire.PORT)),
                               ('192.168.1.2:45000', ('192.168.1.2', 45000)),
                               ('[::1]:45000', ('::1', 45000)), ('::1', ('::1', wire.PORT)), ('[fe80::1%4]:44331', ('fe80::1%4',44331))]:
            self.assertEqual(wire.address(text), expected)
        for text in ('', 'https://host', 'host/path', 'foo@host', 'host:99999', 'host name', 'host;rm'):
            with self.assertRaises(ValueError): wire.address(text)


if __name__ == '__main__': unittest.main()
