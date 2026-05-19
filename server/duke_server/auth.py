"""Session token: HMAC-signed nickname + nonce. Stateless, no DB needed."""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import time
from dataclasses import dataclass
from typing import Optional


_TOKEN_VERSION = b"v1"
_HMAC_ALG = hashlib.sha256


def _b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64d(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


@dataclass(frozen=True)
class Session:
    nickname: str
    issued_at: int
    nonce: str


def issue_token(nickname: str, secret: bytes) -> str:
    issued = int(time.time())
    nonce = secrets.token_urlsafe(12)
    payload = f"{_TOKEN_VERSION.decode()}.{nickname}.{issued}.{nonce}".encode("utf-8")
    sig = hmac.new(secret, payload, _HMAC_ALG).digest()
    return f"{_b64e(payload)}.{_b64e(sig)}"


def verify_token(token: str, secret: bytes, max_age_s: int = 86400) -> Optional[Session]:
    try:
        payload_b, sig_b = token.split(".")
        payload = _b64d(payload_b)
        sig = _b64d(sig_b)
    except Exception:
        return None

    expected = hmac.new(secret, payload, _HMAC_ALG).digest()
    if not hmac.compare_digest(expected, sig):
        return None

    try:
        version, nickname, issued, nonce = payload.decode("utf-8").split(".", 3)
        issued_i = int(issued)
    except Exception:
        return None

    if version != _TOKEN_VERSION.decode():
        return None
    if int(time.time()) - issued_i > max_age_s:
        return None

    return Session(nickname=nickname, issued_at=issued_i, nonce=nonce)
