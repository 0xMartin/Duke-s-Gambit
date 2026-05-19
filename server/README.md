# Duke's Gambit — Online Server

Authoritative WebSocket server for online play in **Duke's Gambit**.
Players connect from the in-game **Online** section, browse the room list,
create or join a room and play 1v1 chess over the network. The server validates
every move, runs the chess clock, and is the single source of truth for the
game outcome.

## Author

**0xM4R71N** — [github.com/0xMartin](https://github.com/0xMartin)

---

## Highlights

- **Python 3.12 + asyncio + [websockets](https://websockets.readthedocs.io/)** — small, dependency-light core.
- **[python-chess](https://python-chess.readthedocs.io/)** for full move legality (en passant, castling, promotion, threefold repetition, 50-move rule).
- **WSS (TLS) by default** with an auto-generated self-signed certificate. Optional plain WS for LAN/dev.
- **Stateless session tokens** (HMAC-signed). No login, no database — players just pick a nickname.
- **Room model:** UUID-style room IDs, optional per-room password, host chooses side and time control.
- **Authoritative clock** with per-side ticking and timeout enforcement.
- **Graceful reconnect** (30 s window by default) — drop your Wi-Fi briefly, walk back in, the game continues.
- **DoS guards:** per-connection rate limit, max-room / max-client caps, max message size.

---

## Quick start (Docker, recommended)

```bash
cd server
docker compose up --build -d
docker compose logs -f duke-server
```

On first start the server generates a self-signed certificate inside the
`duke-certs` volume and prints its SHA-256 fingerprint:

```
TLS enabled. Cert: /data/certs/server.crt
Cert SHA-256 fingerprint: AB:CD:EF:...
```

The server listens on `wss://<host>:8765` by default.

### Trusting the self-signed certificate in the game

The Godot client supports two ways to connect to a WSS server with a
self-signed cert:

1. **Trust by fingerprint (easiest, LAN play)** — paste the printed
   SHA-256 fingerprint into the *Online → Connect* dialog. The client only
   accepts the server if its certificate's fingerprint matches.
2. **Trust the cert directly** — copy `server.crt` from the Docker volume
   (e.g. `docker cp dukes-gambit-server:/data/certs/server.crt ~/duke-server.crt`)
   and pick it as the *Trusted CA* file in the same dialog.

For development / pure LAN you may also set `DUKE_TLS=0` to fall back to
plain `ws://`. **Do not** expose a plain-WS server to the public internet.

### Quick start without Docker

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
DUKE_TLS=0 python -m duke_server
```

(Drop `DUKE_TLS=0` to run with TLS — certs are generated in `./certs` next to the package.)

---

## Configuration

All settings come from environment variables.

| Variable                 | Default        | Description                                                       |
| ------------------------ | -------------- | ----------------------------------------------------------------- |
| `DUKE_HOST`              | `0.0.0.0`      | Bind address.                                                     |
| `DUKE_PORT`              | `8765`         | TCP port.                                                         |
| `DUKE_TLS`               | `1`            | `1` = WSS with auto self-signed cert, `0` = plain WS (LAN only).  |
| `DUKE_CERT_DIR`          | `/data/certs`  | Where the cert/key live (mounted as a volume in Docker).          |
| `DUKE_SESSION_SECRET`    | random per run | HMAC key for session tokens. Set to a long random string in prod. |
| `DUKE_MAX_ROOMS`         | `256`          | Cap on simultaneously open rooms.                                 |
| `DUKE_MAX_CLIENTS`       | `512`          | Cap on simultaneous WebSocket connections.                        |
| `DUKE_RECONNECT_S`       | `30`           | Reconnect grace window for a disconnected player.                 |
| `DUKE_ROOM_IDLE_S`       | `600`          | Idle empty-room cleanup (s).                                      |
| `DUKE_HEARTBEAT_S`       | `20`           | WebSocket ping interval (s).                                      |
| `DUKE_LOG_LEVEL`         | `INFO`         | Standard Python log level.                                        |

---

## Wire protocol (summary)

JSON messages over WebSocket, one object per frame, mandatory `type` field.

### Client → Server

| Type            | Payload                                              | Notes                              |
| --------------- | ---------------------------------------------------- | ---------------------------------- |
| `hello`         | `{nickname, token?}`                                 | Must be the first message.         |
| `list_rooms`    | `{}`                                                 | Subscribes to lobby updates.       |
| `create_room`   | `{name, host_color, time_ms, password?}`             | Caller becomes host.               |
| `join_room`     | `{room_id, password?}`                               |                                    |
| `leave_room`    | `{}`                                                 |                                    |
| `delete_room`   | `{}`                                                 | Host only, pre-game.               |
| `move`          | `{uci}`                                              | UCI form: `e2e4`, `e7e8q`.         |
| `surrender`     | `{}`                                                 | Loses the game.                    |
| `offer_draw`    | `{}`                                                 | Accept-by-counter-offer logic.     |
| `accept_draw`   | `{}`                                                 |                                    |
| `decline_draw`  | `{}`                                                 |                                    |
| `ping`          | `{}`                                                 |                                    |

### Server → Client

| Type            | Payload                                                                              |
| --------------- | ------------------------------------------------------------------------------------ |
| `welcome`       | `{protocol, session_token, online_count}`                                            |
| `room_list`     | `{rooms[], online_count}`                                                            |
| `online_count`  | `{online_count}`                                                                     |
| `room_created`  | `{room, role}`                                                                       |
| `room_joined`   | `{room, role}`                                                                       |
| `room_updated`  | `{room}`                                                                             |
| `room_deleted`  | `{room_id, reason}`                                                                  |
| `game_start`    | `{room_id, white, black, time_ms, fen, active, your_color, white_ms, black_ms, ply}` |
| `move_applied`  | `{uci, from, to, promotion, fen, active, white_ms, black_ms, ply}`                   |
| `draw_offer`    | `{from_color}`                                                                       |
| `draw_declined` | `{}`                                                                                 |
| `game_over`     | `{winner, reason, white_ms, black_ms, fen}`                                          |
| `error`         | `{code, message}`                                                                    |
| `pong`          | `{t}`                                                                                |
| `kicked`        | `{reason}`                                                                           |

### Move encoding

Moves use standard UCI long algebraic notation:

- `e2e4` — pawn push
- `g1f3` — knight move
- `e1g1` — king-side castle (king's `from`/`to`, server infers castling)
- `e7e8q` — promotion to queen (`q`, `r`, `b`, `n`)

The server replies with a `move_applied` event whose `from`, `to` and
`promotion` fields are already parsed for convenient client-side use.

### Error codes

`bad_request`, `protocol_error`, `auth_error`, `not_found`, `forbidden`,
`full`, `bad_state`, `illegal_move`, `not_your_turn`, `rate_limited`,
`internal`.

---

## Security model

| Threat                                       | Mitigation                                                             |
| -------------------------------------------- | ---------------------------------------------------------------------- |
| Eavesdropping on the wire                    | WSS (TLS) by default, recommended in production.                       |
| Unauthorised entry to a private room         | Per-room password (HMAC-compared), random URL-safe room IDs.           |
| Tampering with someone else's session        | HMAC-signed session tokens; nicknames are single-instance per server.  |
| Cheating / illegal moves                     | `python-chess` validates every move; server-only outcome decision.     |
| Clock manipulation                           | Server clock is authoritative; client times are display-only.          |
| Spam / DoS                                   | Per-connection rate limit (30 msg/s), room/client caps, message size.  |
| Crash on bad input                           | Strict JSON validation, length-limited fields, regex-validated names.  |

> ⚠ Self-signed certificates are fine on a LAN, but for the public internet
> please put the server behind a reverse proxy (Caddy / nginx) with a
> Let's Encrypt cert and forward to the websocket port.

---

## Development

Run plain WS for fast iteration:

```bash
DUKE_TLS=0 python -m duke_server
```

Quick smoke test from the shell with `websocat`:

```bash
websocat ws://localhost:8765 <<< '{"type":"hello","nickname":"Tester"}'
```

You should get back a `welcome` frame.

---

## License

Same as the parent project (non-commercial fan game).