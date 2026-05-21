"""Wire protocol for the Duke's Gambit WebSocket server.

Every message exchanged over the WebSocket is a JSON object with a
mandatory ``type`` field; the constants in this module name those types
and the error codes that may appear in :data:`S_ERROR` payloads.

Connection lifecycle
--------------------
1. Client opens a WebSocket and sends :data:`C_HELLO` with a nickname
   (and optionally a previous ``session_token`` to resume identity).
2. Server replies with :data:`S_WELCOME` containing the current protocol
   version and a fresh session token.
3. Client may then list rooms (:data:`C_LIST_ROOMS`), create a room
   (:data:`C_CREATE_ROOM`) or join one (:data:`C_JOIN_ROOM`).
4. Once both seats are filled, the host sends :data:`C_START_GAME` and
   the server broadcasts :data:`S_GAME_START` to both members.
5. During play, clients exchange :data:`C_MOVE` / :data:`S_MOVE_APPLIED`
   messages; the server validates each move against ``python-chess``
   and updates clocks server-side. Game termination is announced via
   :data:`S_GAME_OVER`.

Conventions
-----------
* All durations are in **milliseconds** unless suffixed ``_s``.
* Colors are the strings ``"white"`` / ``"black"`` on the wire.
* Moves use UCI notation (``"e2e4"``, ``"e7e8q"`` for promotions).
* Errors are always delivered as :data:`S_ERROR` with a stable string
  ``code`` from the ``ERR_*`` constants below.
"""

from __future__ import annotations

PROTOCOL_VERSION = 1

# ── Client → Server ────────────────────────────────────────────────────────
C_HELLO = "hello"                # {nickname, client_version}
C_LIST_ROOMS = "list_rooms"
C_CREATE_ROOM = "create_room"    # {name, password?, host_color, time_ms}
C_JOIN_ROOM = "join_room"        # {room_id, password?}
C_LEAVE_ROOM = "leave_room"
C_DELETE_ROOM = "delete_room"    # host only
C_START_GAME = "start_game"      # host only — start match once both players are in
C_CLIENT_READY = "client_ready"  # client signals it finished loading the game scene
C_MOVE = "move"                  # {uci, promotion?} — UCI "e2e4" / "e7e8q"
C_SURRENDER = "surrender"
C_OFFER_DRAW = "offer_draw"
C_ACCEPT_DRAW = "accept_draw"
C_DECLINE_DRAW = "decline_draw"
C_PING = "ping"

# ── Server → Client ────────────────────────────────────────────────────────
S_WELCOME = "welcome"            # {protocol, session_token, online_count}
S_ROOM_LIST = "room_list"        # {rooms: [...], online_count}
S_ONLINE_COUNT = "online_count"  # {online_count}
S_ROOM_CREATED = "room_created"  # {room: {...}, role: "host"}
S_ROOM_JOINED = "room_joined"    # {room: {...}, role: "host"|"guest"|"none"}
S_ROOM_UPDATED = "room_updated"  # {room: {...}}
S_ROOM_DELETED = "room_deleted"  # {room_id, reason}
S_GAME_START = "game_start"      # {room_id, white, black, time_ms, fen, your_color}
S_READY_STATE = "ready_state"    # {ready: ["white", ...], all_ready: bool} — emitted while clients load
S_MOVE_APPLIED = "move_applied"  # {uci, from, to, promotion, fen, active, white_ms, black_ms, ply}
S_DRAW_OFFER = "draw_offer"      # {from_color}
S_DRAW_DECLINED = "draw_declined"
S_GAME_OVER = "game_over"        # {winner: "white"|"black"|"draw", reason, white_ms, black_ms}
S_ERROR = "error"                # {code, message}
S_PONG = "pong"
S_KICKED = "kicked"              # {reason}

# Standard error codes
ERR_BAD_REQUEST = "bad_request"
ERR_PROTOCOL = "protocol_error"
ERR_AUTH = "auth_error"
ERR_NOT_FOUND = "not_found"
ERR_FORBIDDEN = "forbidden"
ERR_FULL = "full"
ERR_BAD_STATE = "bad_state"
ERR_ILLEGAL_MOVE = "illegal_move"
ERR_NOT_YOUR_TURN = "not_your_turn"
ERR_RATE_LIMITED = "rate_limited"
ERR_INTERNAL = "internal"
