"""Apple App Attest verification.

Follows Apple's "Validating apps that connect to your server":
https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server

Attestation (once per device key) proves the key lives in the Secure Enclave of a real
Apple device running our app (team ID + bundle ID). Assertions (every request) prove the
request was signed by that key. Neither step involves any secret on our side.
"""

import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

# https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
# SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
APPLE_APP_ATTEST_ROOT_CA = x509.load_pem_x509_certificate(b"""-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----""")

NONCE_EXTENSION_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
AAGUID_PRODUCTION = b"appattest" + b"\x00" * 7
AAGUID_DEVELOPMENT = b"appattestdevelop"


class AttestationError(Exception):
    """The attestation or assertion is not valid; the reason is safe to log."""


@dataclass
class AttestedKey:
    public_key_der: bytes   # SubjectPublicKeyInfo DER of the device key
    environment: str        # "production" or "development"


def _parse_auth_data(auth_data: bytes):
    if len(auth_data) < 37:
        raise AttestationError("authenticator data too short")
    rp_id_hash = auth_data[0:32]
    counter = int.from_bytes(auth_data[33:37], "big")
    return rp_id_hash, counter


def verify_attestation(attestation: bytes, key_id: bytes, challenge: bytes, app_id: str,
                       allow_development: bool) -> AttestedKey:
    """Steps 1-9 of Apple's attestation check. `key_id` is the raw (base64-decoded) key ID."""
    try:
        obj = cbor2.loads(attestation)
        fmt, att_stmt, auth_data = obj["fmt"], obj["attStmt"], obj["authData"]
        cert_chain = att_stmt["x5c"]
    except (ValueError, KeyError, TypeError, cbor2.CBORDecodeError) as e:
        raise AttestationError(f"malformed attestation ({type(e).__name__})")
    if fmt != "apple-appattest" or len(cert_chain) < 2:
        raise AttestationError("unexpected attestation format")

    # 1. Certificate chain: credential cert <- intermediate <- Apple App Attestation Root CA.
    cred_cert = x509.load_der_x509_certificate(cert_chain[0])
    intermediate = x509.load_der_x509_certificate(cert_chain[1])
    now = datetime.now(timezone.utc)
    try:
        cred_cert.verify_directly_issued_by(intermediate)
        intermediate.verify_directly_issued_by(APPLE_APP_ATTEST_ROOT_CA)
    except (ValueError, TypeError, InvalidSignature):
        raise AttestationError("certificate chain does not lead to Apple's root")
    for cert in (cred_cert, intermediate):
        if not (cert.not_valid_before_utc <= now <= cert.not_valid_after_utc):
            raise AttestationError("certificate outside its validity period")

    # 2-4. nonce = SHA256(authData || SHA256(challenge)) must match the cert's nonce extension.
    nonce = hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()
    try:
        ext = cred_cert.extensions.get_extension_for_oid(NONCE_EXTENSION_OID).value.value
    except x509.ExtensionNotFound:
        raise AttestationError("nonce extension missing")
    # DER: SEQUENCE { [1] { OCTET STRING nonce } }; the nonce is the last 32 bytes.
    if len(ext) < 32 or ext[-32:] != nonce:
        raise AttestationError("nonce mismatch")

    # 5. The key ID is the SHA256 of the credential cert's public key (uncompressed point).
    public_key = cred_cert.public_key()
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise AttestationError("unexpected key type")
    point = public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    if hashlib.sha256(point).digest() != key_id:
        raise AttestationError("key ID does not match the certificate")

    # 6-9. App ID, counter 0, environment, credential ID.
    rp_id_hash, counter = _parse_auth_data(auth_data)
    if rp_id_hash != hashlib.sha256(app_id.encode()).digest():
        raise AttestationError("attestation is for a different app")
    if counter != 0:
        raise AttestationError("counter is not zero")
    aaguid = auth_data[37:53]
    if aaguid == AAGUID_PRODUCTION:
        environment = "production"
    elif aaguid == AAGUID_DEVELOPMENT and allow_development:
        environment = "development"
    else:
        raise AttestationError("unexpected App Attest environment")
    cred_id_len = int.from_bytes(auth_data[53:55], "big")
    if auth_data[55:55 + cred_id_len] != key_id:
        raise AttestationError("credential ID does not match the key ID")

    return AttestedKey(
        public_key_der=public_key.public_bytes(serialization.Encoding.DER,
                                               serialization.PublicFormat.SubjectPublicKeyInfo),
        environment=environment,
    )


def verify_assertion(assertion: bytes, client_data: bytes, public_key_der: bytes, app_id: str,
                     previous_counter: int) -> int:
    """Checks one request's signature. Returns the new counter, which must be stored."""
    try:
        obj = cbor2.loads(assertion)
        signature, auth_data = obj["signature"], obj["authenticatorData"]
    except (ValueError, KeyError, TypeError, cbor2.CBORDecodeError) as e:
        raise AttestationError(f"malformed assertion ({type(e).__name__})")

    nonce = hashlib.sha256(auth_data + hashlib.sha256(client_data).digest()).digest()
    public_key = serialization.load_der_public_key(public_key_der)
    try:
        public_key.verify(signature, nonce, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise AttestationError("bad signature")

    rp_id_hash, counter = _parse_auth_data(auth_data)
    if rp_id_hash != hashlib.sha256(app_id.encode()).digest():
        raise AttestationError("assertion is for a different app")
    if counter <= previous_counter:
        raise AttestationError("counter did not increase (replayed request)")
    return counter
