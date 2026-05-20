"""Stateless session tokens for the WebSocket handshake.

The server never persists user accounts. Instead, on a successful
``hello`` it issues a short opaque token that the client can present on
reconnect; the server verifies it with HMAC-SHA256 over the server-only
``session_secret``. No database lookup is required, which keeps the
handshake cheap and side-effect-free.

Token format
------------
``base64url(payload).base64url(signature)`` where ::

    payload   = "v1.<nickname>.<issued_at>.<nonce>"   (UTF-8)
    signature = HMAC-SHA256(secret, payload)

The token is **not** secret-bearing in the JWT sense (no claims about
authorisation). It only proves that the holder previously completed a
hello and that the server is willing to attribute moves to the bound
nickname for the lifetime of the token.

Tokens expire after ``max_age_s`` seconds (default 24 h).
"""

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
    """URL-safe base64 encode with padding stripped (RFC 4648 §5)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64d(text: str) -> bytes:
    """Inverse of :func:`_b64e` — restores padding before decoding."""
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


@dataclass(frozen=True)
class Session:
    """Verified session payload extracted from a token.

    Attributes
    ----------
    nickname:
        The display name the token was issued for.
    issued_at:
        UNIX timestamp at issuance, used for the age check.
    nonce:
        Random per-token value; preserved only to differentiate tokens
        with the same ``(nickname, issued_at)`` pair.
    """

    nickname: str
    issued_at: int
    nonce: str


def issue_token(nickname: str, secret: bytes) -> str:
    """Issue a fresh session token bound to ``nickname``.

    Parameters
    ----------
    nickname:
        Validated display name (caller must ensure it matches the
        server's ``NICKNAME_RE``).
    secret:
        Server-only HMAC key — typically :attr:`ServerConfig.session_secret`.

    Returns
    -------
    str
        A ``payload.signature`` string safe to send over JSON.
    """
    issued = int(time.time())
    nonce = secrets.token_urlsafe(12)
    payload = f"{_TOKEN_VERSION.decode()}.{nickname}.{issued}.{nonce}".encode("utf-8")
    sig = hmac.new(secret, payload, _HMAC_ALG).digest()
    return f"{_b64e(payload)}.{_b64e(sig)}"


def verify_token(token: str, secret: bytes, max_age_s: int = 86400) -> Optional[Session]:
    """Verify a token signature, version and age.

    Parameters
    ----------
    token:
        The ``payload.signature`` string supplied by the client.
    secret:
        The same HMAC key passed to :func:`issue_token`. If the server's
        secret has been rotated since the token was issued, verification
        will fail and the client must say hello again.
    max_age_s:
        Maximum age in seconds (default 24 h).

    Returns
    -------
    Session or None
        The decoded :class:`Session` on success, or ``None`` if the token
        is malformed, has an invalid signature, uses an unknown version,
        or is older than ``max_age_s``. Uses :func:`hmac.compare_digest`
        to avoid leaking timing information.
    """
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

