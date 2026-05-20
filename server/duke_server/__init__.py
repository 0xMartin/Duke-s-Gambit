"""Duke's Gambit multiplayer chess server.

This package implements an authoritative WebSocket server for the Duke's
Gambit Godot client. Key design properties:

* **Server-authoritative**: all chess rules, clocks and game-over decisions
  are evaluated server-side using ``python-chess``. Clients are presentation
  layers only — they may render optimistically but rely on ``move_applied``
  / ``game_over`` events for the canonical state.
* **Stateless sessions**: clients authenticate with an HMAC-signed token
  (see :mod:`duke_server.auth`). No database is required; the server keeps
  everything in memory.
* **TLS by default**: a self-signed certificate is generated on first boot
  (see :mod:`duke_server.tls`). The SHA-256 fingerprint is exposed so LAN
  clients can pin it.
* **Wire format**: line-delimited JSON over a single WebSocket connection
  (one message = one JSON object with a mandatory ``type`` field). The full
  protocol is documented in :mod:`duke_server.protocol`.

Module layout::

    auth       — HMAC-signed session tokens (stateless auth).
    config     — environment-driven runtime configuration.
    game       — server-side chess engine + per-side clock.
    lobby      — registry of rooms and connected clients.
    protocol   — wire constants (message types, error codes).
    room       — room lifecycle: membership, password, game wrapper.
    server     — asyncio WebSocket server, dispatch, broadcasts.
    tls        — self-signed certificate generation.

Run ``python -m duke_server`` to start the server.
"""

__version__ = "1.0.0"
__author__ = "0xM4R71N"
