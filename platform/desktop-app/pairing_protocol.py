"""Viewflow group pairing v2: SPAKE2, authenticated envelopes and local TLS keys.

Discovery is only a hint. Six-digit codes are never sent over the network and
never used as an offline-verifiable hash. PAKE authenticates the ephemeral
channel; Ed25519 private keys stay on their originating computers.
"""
import base64
import datetime
import ipaddress
import json
import os
import re
import socket
import struct
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from spake2 import SPAKE2_A, SPAKE2_B

VERSION = 2
PORT = 44331
MAX_MESSAGE = 128 * 1024
CONTEXT = b'org.viewflow.pairing.v2'


def b64(data): return base64.b64encode(data).decode('ascii')
def unb64(value): return base64.b64decode(value, validate=True)


def address(value, default_port=PORT):
    """Accept hostname, IPv4[:port] and [IPv6][:port], never a URL or command."""
    value = value.strip()
    if not value or len(value) > 300 or any(c.isspace() for c in value) or any(c in value for c in '/?#@\\'):
        raise ValueError('配对地址无效，请输入主机名或 IP 地址。')
    if value.count(':') > 1 and not value.startswith('['):
        ipaddress.IPv6Address(value.split('%', 1)[0])
        return value, default_port
    parsed = urlsplit('//' + value)
    host, port = parsed.hostname, default_port if parsed.port is None else parsed.port
    if not host or not 1 <= port <= 65535 or not re.fullmatch(r'[A-Za-z0-9_.:%-]+', host):
        raise ValueError('配对地址无效，请输入主机名或 IP 地址。')
    return host, port


def endpoint(host, port):
    return f'[{host}]:{port}' if ':' in host else f'{host}:{port}'


def numeric_host(value):
    ip = ipaddress.ip_address(value.split('%', 1)[0])
    return str(ip.ipv4_mapped) if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped else value


def socket_host(address):
    """Preserve the receiver's interface scope for link-local IPv6 transports."""
    host = numeric_host(address[0])
    if ':' in host and len(address) > 3 and address[3] and '%' not in host:
        host += '%' + str(address[3])
    return host


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode()


def send(sock, value):
    body = encode(value)
    if len(body) > MAX_MESSAGE: raise ValueError('pairing message too large')
    sock.sendall(struct.pack('!I', len(body)) + body)


def exact(sock, count):
    result = bytearray()
    while len(result) < count:
        block = sock.recv(count - len(result))
        if not block: raise ConnectionError('pairing connection closed')
        result.extend(block)
    return bytes(result)


def receive(sock):
    count, = struct.unpack('!I', exact(sock, 4))
    if count == 0 or count > MAX_MESSAGE: raise ValueError('invalid pairing message length')
    value = json.loads(exact(sock, count))
    if not isinstance(value, dict): raise ValueError('invalid pairing message')
    return value


class Channel:
    def __init__(self, sock, key, client):
        self.sock = sock
        keys = HKDF(algorithm=hashes.SHA256(), length=64, salt=None, info=CONTEXT).derive(key)
        self.tx = AESGCM(keys[:32] if client else keys[32:])
        self.rx = AESGCM(keys[32:] if client else keys[:32])
        self.sent = self.received = 0

    def send(self, value):
        data = self.tx.encrypt(self.sent.to_bytes(12, 'big'), encode(value), CONTEXT)
        self.sent += 1
        send(self.sock, {'ciphertext': b64(data)})

    def receive(self):
        envelope = receive(self.sock)
        raw = self.rx.decrypt(self.received.to_bytes(12, 'big'), unb64(envelope['ciphertext']), CONTEXT)
        self.received += 1
        result = json.loads(raw)
        if not isinstance(result, dict): raise ValueError('invalid pairing payload')
        return result


def authenticate(sock, password, local_id, peer_id, client):
    id_a, id_b = (local_id, peer_id) if client else (peer_id, local_id)
    pake = (SPAKE2_A if client else SPAKE2_B)(password.encode(),
        idA=CONTEXT + id_a.encode(), idB=CONTEXT + id_b.encode())
    send(sock, {'pake': b64(pake.start())})
    key = pake.finish(unb64(receive(sock)['pake']))
    channel = Channel(sock, key, client)
    channel.send({'confirm': VERSION, 'id': local_id})
    proof = channel.receive()
    if proof != {'confirm': VERSION, 'id': peer_id}: raise ValueError('pairing confirmation failed')
    return channel


def valid_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{32}', value):
        raise ValueError('invalid device identity')
    return value


def validate_device(value):
    valid_id(value.get('id'))
    if value.get('platform') not in ('linux', 'windows', 'macos'):
        raise ValueError('unsupported peer platform')
    name = value.get('name')
    if not isinstance(name, str) or not 1 <= len(name) <= 120 or any(ord(c) < 32 for c in name):
        raise ValueError('invalid device name')
    ports = value.get('ports', {})
    if set(ports) != {'windows', 'atlas', 'clipboard', 'input'} or any(type(p) is not int or not 1 <= p <= 65535 for p in ports.values()) or len(set(ports.values())) != 4:
        raise ValueError('invalid service ports')
    display = value.get('display', {})
    for key in ('width', 'height'):
        if type(display.get(key)) is not int or not 64 <= display[key] <= 16384:
            raise ValueError('invalid display dimensions')
    scale = display.get('scale')
    if not isinstance(scale, (int, float)) or not 0.5 <= scale <= 4:
        raise ValueError('invalid display scale')
    bounds = value.get('share_bounds')
    if bounds is not None and (not isinstance(bounds, list) or len(bounds) != 4 or
            any(type(x) is not int or abs(x) > 100000 for x in bounds) or
            not 64 <= bounds[2] - bounds[0] <= 16384 or not 64 <= bounds[3] - bounds[1] <= 16384):
        raise ValueError('invalid sharing display bounds')
    origin = value.get('share_origin')
    if origin is not None and (not isinstance(origin, list) or len(origin) != 2 or
            any(type(x) is not int or abs(x) > 100000 for x in origin)):
        raise ValueError('invalid sharing origin')
    if value.get('share_serial') is not None and value['share_serial'] not in (1, 2):
        raise ValueError('invalid sharing display serial')
    return value


def private_key_pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption()).decode()


def new_key():
    return Ed25519PrivateKey.generate()


def public_key(key):
    return b64(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))


def issue_pair(local_id, local_key, peer_id, peer_public):
    """A new pair owns a CA; only public keys/certificates cross the PAKE channel."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    peer_key = Ed25519PublicKey.from_public_bytes(unb64(peer_public))
    authority = new_key()
    now = datetime.datetime.now(datetime.timezone.utc)
    issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Viewflow pair ' + os.urandom(8).hex())])
    def builder(subject, key):
        return x509.CertificateBuilder().subject_name(subject).issuer_name(issuer).public_key(key).serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
    ca = builder(issuer, authority.public_key()).add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True).add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True).sign(authority, None)
    def cert(device_id, key):
        dns = 'vf-' + valid_id(device_id) + '.local'
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, dns)])
        return builder(subject, key).add_extension(x509.BasicConstraints(ca=False, path_length=None), True).add_extension(x509.SubjectAlternativeName([x509.DNSName(dns)]), False).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH, ExtendedKeyUsageOID.SERVER_AUTH]), False).sign(authority, None).public_bytes(serialization.Encoding.PEM).decode()
    return {'authority': ca.public_bytes(serialization.Encoding.PEM).decode(),
            'local_certificate': cert(local_id, local_key.public_key()),
            'peer_certificate': cert(peer_id, peer_key)}


def validate_certificate(certificate, authority, key, device_id):
    cert = x509.load_pem_x509_certificate(certificate.encode())
    ca = x509.load_pem_x509_certificate(authority.encode())
    cert.verify_directly_issued_by(ca)
    if cert.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw) != key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw):
        raise ValueError('pair certificate does not match local key')
    if cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName) != ['vf-' + device_id + '.local']:
        raise ValueError('pair certificate identity mismatch')
