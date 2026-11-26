"""Tests for appattest.py using a simulated Apple CA and device (real devices can't be used here).

Run: python -m pytest test_appattest.py   (or python test_appattest.py)
"""

import hashlib
from datetime import datetime, timedelta, timezone

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

import appattest

APP_ID = "TEAMID1234.com.example.HealthRead"


def _name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(subject, issuer, public_key, signing_key, extensions=()):
    now = datetime.now(timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(_name(subject)).issuer_name(_name(issuer))
               .public_key(public_key).serial_number(x509.random_serial_number())
               .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=30)))
    for ext in extensions:
        builder = builder.add_extension(ext, critical=False)
    return builder.sign(signing_key, hashes.SHA256())


class FakeApple:
    """Plays Apple's CA and one device's Secure Enclave key."""

    def __init__(self):
        self.root_key = ec.generate_private_key(ec.SECP384R1())
        self.root = _cert("Fake Root", "Fake Root", self.root_key.public_key(), self.root_key)
        self.inter_key = ec.generate_private_key(ec.SECP384R1())
        self.inter = _cert("Fake Intermediate", "Fake Root", self.inter_key.public_key(), self.root_key)
        self.device_key = ec.generate_private_key(ec.SECP256R1())
        point = self.device_key.public_key().public_bytes(
            serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        self.key_id = hashlib.sha256(point).digest()
        self.counter = 0

    def auth_data(self, app_id=APP_ID, counter=0, aaguid=appattest.AAGUID_PRODUCTION, cred_id=None):
        cred_id = self.key_id if cred_id is None else cred_id
        return (hashlib.sha256(app_id.encode()).digest() + b"\x40" + counter.to_bytes(4, "big")
                + aaguid + len(cred_id).to_bytes(2, "big") + cred_id)

    def attestation(self, challenge, **auth_kwargs):
        auth_data = self.auth_data(**auth_kwargs)
        nonce = hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()
        # Same DER layout as Apple: SEQUENCE { [1] { OCTET STRING nonce } }
        der = bytes([0x30, 0x24, 0xA1, 0x22, 0x04, 0x20]) + nonce
        ext = x509.UnrecognizedExtension(appattest.NONCE_EXTENSION_OID, der)
        cred = _cert("Device", "Fake Intermediate", self.device_key.public_key(), self.inter_key, [ext])
        return cbor2.dumps({
            "fmt": "apple-appattest",
            "attStmt": {"x5c": [cred.public_bytes(serialization.Encoding.DER),
                                self.inter.public_bytes(serialization.Encoding.DER)], "receipt": b""},
            "authData": auth_data,
        })

    def assertion(self, client_data, app_id=APP_ID):
        self.counter += 1
        auth_data = hashlib.sha256(app_id.encode()).digest() + b"\x40" + self.counter.to_bytes(4, "big")
        nonce = hashlib.sha256(auth_data + hashlib.sha256(client_data).digest()).digest()
        signature = self.device_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
        return cbor2.dumps({"signature": signature, "authenticatorData": auth_data})


def _expect_rejected(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except appattest.AttestationError:
        return
    raise AssertionError("expected AttestationError")


def test_attestation_and_assertions():
    apple = FakeApple()
    appattest.APPLE_APP_ATTEST_ROOT_CA = apple.root
    challenge = b"c" * 32

    key = appattest.verify_attestation(apple.attestation(challenge), apple.key_id, challenge, APP_ID, False)
    assert key.environment == "production"

    # Wrong challenge, app, key ID, counter or environment are all rejected.
    _expect_rejected(appattest.verify_attestation, apple.attestation(challenge), apple.key_id, b"x" * 32, APP_ID, False)
    _expect_rejected(appattest.verify_attestation, apple.attestation(challenge, app_id="OTHER.app"),
                     apple.key_id, challenge, APP_ID, False)
    _expect_rejected(appattest.verify_attestation, apple.attestation(challenge), b"k" * 32, challenge, APP_ID, False)
    _expect_rejected(appattest.verify_attestation, apple.attestation(challenge, counter=1),
                     apple.key_id, challenge, APP_ID, False)
    _expect_rejected(appattest.verify_attestation, apple.attestation(challenge, aaguid=appattest.AAGUID_DEVELOPMENT),
                     apple.key_id, challenge, APP_ID, False)
    dev = appattest.verify_attestation(apple.attestation(challenge, aaguid=appattest.AAGUID_DEVELOPMENT),
                                       apple.key_id, challenge, APP_ID, True)
    assert dev.environment == "development"

    # A chain from a different root is rejected.
    impostor = FakeApple()
    _expect_rejected(appattest.verify_attestation, impostor.attestation(challenge), impostor.key_id,
                     challenge, APP_ID, False)

    # Assertions: valid, then tampered body, replay, wrong app.
    body = b'{"image_jpeg_base64": "..."}'
    counter = appattest.verify_assertion(apple.assertion(body), body, key.public_key_der, APP_ID, 0)
    assert counter == 1
    _expect_rejected(appattest.verify_assertion, apple.assertion(body), body + b" ", key.public_key_der, APP_ID, 1)
    replay = apple.assertion(body)
    assert appattest.verify_assertion(replay, body, key.public_key_der, APP_ID, 2) == 3
    _expect_rejected(appattest.verify_assertion, replay, body, key.public_key_der, APP_ID, 3)
    _expect_rejected(appattest.verify_assertion, apple.assertion(body, app_id="OTHER.app"), body,
                     key.public_key_der, APP_ID, 3)


if __name__ == "__main__":
    test_attestation_and_assertions()
    print("ok")
