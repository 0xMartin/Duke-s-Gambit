"""Self-signed certificate generation for TLS bootstrap (LAN-friendly)."""

from __future__ import annotations

import datetime as _dt
import hashlib
import os
import ssl
from pathlib import Path
from typing import Tuple

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

CERT_FILE = "server.crt"
KEY_FILE = "server.key"
FINGERPRINT_FILE = "server.fingerprint.txt"


def ensure_cert(cert_dir: str) -> Tuple[Path, Path, str]:
    """Return (cert_path, key_path, sha256_fingerprint_hex). Generate if missing."""
    d = Path(cert_dir)
    d.mkdir(parents=True, exist_ok=True)
    cert_path = d / CERT_FILE
    key_path = d / KEY_FILE

    if not cert_path.exists() or not key_path.exists():
        _generate_self_signed(cert_path, key_path)

    fingerprint = _sha256_fingerprint(cert_path)
    (d / FINGERPRINT_FILE).write_text(fingerprint + "\n", encoding="utf-8")
    return cert_path, key_path, fingerprint


def make_ssl_context(cert_path: Path, key_path: Path) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def _generate_self_signed(cert_path: Path, key_path: Path) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "Duke's Gambit Server"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Duke's Gambit"),
    ])
    san = x509.SubjectAlternativeName([
        x509.DNSName("localhost"),
        x509.DNSName("dukes-gambit-server"),
        x509.IPAddress(__import__("ipaddress").ip_address("127.0.0.1")),
        x509.IPAddress(__import__("ipaddress").ip_address("0.0.0.0")),
    ])
    now = _dt.datetime.now(_dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - _dt.timedelta(days=1))
        .not_valid_after(now + _dt.timedelta(days=3650))
        .add_extension(san, critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(private_key=key, algorithm=hashes.SHA256())
    )

    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    try:
        os.chmod(key_path, 0o600)
    except OSError:
        pass


def _sha256_fingerprint(cert_path: Path) -> str:
    pem = cert_path.read_bytes()
    # Convert PEM → DER for the standard fingerprint definition.
    cert = x509.load_pem_x509_certificate(pem)
    der = cert.public_bytes(serialization.Encoding.DER)
    digest = hashlib.sha256(der).hexdigest().upper()
    return ":".join(digest[i : i + 2] for i in range(0, len(digest), 2))
