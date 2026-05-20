## online_client.gd
## Autoloaded singleton that owns the WebSocket connection to the Duke's Gambit
## multiplayer server. Translates the JSON wire protocol into Godot signals
## consumed by main menu panels, controllers and GameController.

extends Node

# ── Connection state ───────────────────────────────────────────────────────
enum State {
	DISCONNECTED,
	CONNECTING,
	HANDSHAKING,
	READY,
}

# ── Signals ────────────────────────────────────────────────────────────────
signal connection_state_changed(new_state: int)
signal connection_error(message: String)

signal welcomed(online_count: int)
signal online_count_updated(online_count: int)
signal room_list_updated(rooms: Array, online_count: int)
signal room_created(room: Dictionary)
signal room_joined(room: Dictionary, role: String)
signal room_updated(room: Dictionary)
signal room_deleted(room_id: String, reason: String)

signal game_starting(payload: Dictionary)
signal move_applied(payload: Dictionary)
signal draw_offered(from_color: String)
signal draw_declined()
signal game_over_received(payload: Dictionary)

signal server_error(code: String, message: String)

# ── Configuration / state ──────────────────────────────────────────────────
const PROTOCOL_VERSION := 1
const MOVE_MAX_LEN := 6

var _state: int = State.DISCONNECTED
var _peer: WebSocketPeer = null
var _url: String = ""
var _nickname: String = ""
var _session_token: String = ""
var _current_room_id: String = ""
var _your_color: String = ""        # "white" / "black" once in a room

# Let's Encrypt CA chain embedded as a string so it works on Android without
# any export-filter configuration. Contains ISRG Root X1 (root, valid to 2035)
# and E7 intermediate (valid to 2027). E7 is missing from Godot's Android CA bundle.
const _LE_CHAIN_PEM := """-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIICtzCCAjygAwIBAgIRAMWKhaLGI0XgqMRSU4efWTowCgYIKoZIzj0EAwMwTzEL
MAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2VhcmNo
IEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDIwHhcNMjQwMzEzMDAwMDAwWhcN
MjcwMzEyMjM1OTU5WjAyMQswCQYDVQQGEwJVUzEWMBQGA1UEChMNTGV0J3MgRW5j
cnlwdDELMAkGA1UEAxMCRTcwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAARB6ASTCFh/
vjcwDMCgQer+VtqEkz7JANurZxLP+U9TCeioL6sp5Z8VRvRbYk4P1INBmbefQHJF
HCxcSjKmwtvGBWpl/9ra8HW0QDsUaJW2qOJqceJ0ZVFT3hbUHifBM/2jgfgwgfUw
DgYDVR0PAQH/BAQDAgGGMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcDATAS
BgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBSuSJ7chx1EoG/aouVgdAR4wpwA
gDAfBgNVHSMEGDAWgBR8Qpau3ktIO/qS+J6Mz22LqXI3lTAyBggrBgEFBQcBAQQm
MCQwIgYIKwYBBQUHMAKGFmh0dHA6Ly94Mi5pLmxlbmNyLm9yZy8wEwYDVR0gBAww
CjAIBgZngQwBAgEwJwYDVR0fBCAwHjAcoBqgGIYWaHR0cDovL3gyLmMubGVuY3Iu
b3JnLzAKBggqhkjOPQQDAwNpADBmAjEA/e5N+wjAk945cpaFxGaeMC13fyvdbNzX
lRg9HNdElxi5mXdI4az2CykNU07iFwqEAjEAihPCDkw4b1BvfLg8VNLLuaMpn1Rb
Z1682chR6zNRCseyie4SjyTCdkvsAa+omQSf
-----END CERTIFICATE-----
"""

var _le_chain: X509Certificate = null
var _diag: String = ""  # diagnostic info included in TLS error messages
var _tls_mode: String = "none"

func _ready() -> void:
	set_process(false)
	# Write bundled chain to user:// so X509Certificate can load it.
	var f := FileAccess.open("user://le_chain.pem", FileAccess.WRITE)
	if f == null:
		_diag = "[file_open_failed err=%d]" % FileAccess.get_open_error()
		return
	f.store_string(_LE_CHAIN_PEM)
	f.close()
	var cert := X509Certificate.new()
	var load_err := cert.load("user://le_chain.pem")
	if load_err == OK:
		_le_chain = cert
		_diag = "[cert_loaded]"
	else:
		_diag = "[cert_load_failed err=%d]" % load_err

# ── Public API ─────────────────────────────────────────────────────────────
func get_state() -> int:
	return _state

func get_nickname() -> String:
	return _nickname

func get_current_room_id() -> String:
	return _current_room_id

func get_your_color() -> String:
	return _your_color

## Connect to the server. ``url`` is a ws://, wss:// URL or bare hostname.
func connect_to_server(url: String, nickname: String) -> void:
	disconnect_from_server()
	_url = url.strip_edges()
	# Auto-prepend wss:// if user entered bare hostname (e.g. "example.com:8080")
	if not _url.begins_with("ws://") and not _url.begins_with("wss://"):
		_url = "wss://" + _url
	_nickname = nickname.strip_edges()

	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = 1 << 16
	_peer.outbound_buffer_size = 1 << 16

	var tls_options: TLSOptions = null
	if _url.begins_with("wss://"):
		tls_options = TLSOptions.client_unsafe()
		_tls_mode = "unsafe"

	var ok := _peer.connect_to_url(_url, tls_options)
	if ok != OK:
		emit_signal("connection_error", "Connection failed: code %d" % ok)
		_set_state(State.DISCONNECTED)
		return
	_set_state(State.CONNECTING)
	set_process(true)

func disconnect_from_server() -> void:
	if _peer != null:
		_peer.close(1000, "client disconnect")
	_peer = null
	_session_token = ""
	_current_room_id = ""
	_your_color = ""
	set_process(false)
	_set_state(State.DISCONNECTED)

func send_list_rooms() -> void:
	_send({"type": "list_rooms"})

func send_create_room(room_name: String, host_color: String, time_ms: int, password: String) -> void:
	_send({
		"type": "create_room",
		"name": room_name,
		"host_color": host_color,
		"time_ms": time_ms,
		"password": password,
	})

func send_join_room(room_id: String, password: String) -> void:
	_send({"type": "join_room", "room_id": room_id, "password": password})

func send_leave_room() -> void:
	if _current_room_id == "":
		return
	_send({"type": "leave_room"})
	_current_room_id = ""
	_your_color = ""

func send_delete_room() -> void:
	_send({"type": "delete_room"})

func send_start_game() -> void:
	_send({"type": "start_game"})

func send_move(uci: String) -> void:
	if uci.length() > MOVE_MAX_LEN:
		return
	_send({"type": "move", "uci": uci})

func send_surrender() -> void:
	_send({"type": "surrender"})

func send_offer_draw() -> void:
	_send({"type": "offer_draw"})

func send_accept_draw() -> void:
	_send({"type": "accept_draw"})

func send_decline_draw() -> void:
	_send({"type": "decline_draw"})

# ── Process loop ───────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var status := _peer.get_ready_state()

	match status:
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				_set_state(State.HANDSHAKING)
				_verify_fingerprint_or_disconnect()
				_send({"type": "hello", "nickname": _nickname,
					"client_version": PROTOCOL_VERSION})
			while _peer != null and _peer.get_available_packet_count() > 0:
				var raw := _peer.get_packet().get_string_from_utf8()
				_handle_raw(raw)
		WebSocketPeer.STATE_CLOSED, WebSocketPeer.STATE_CLOSING:
			var was_state := _state
			set_process(false)
			var code := _peer.get_close_code() if _peer != null else -1
			var reason := _peer.get_close_reason() if _peer != null else ""
			_peer = null
			_set_state(State.DISCONNECTED)
			if was_state != State.DISCONNECTED:
				var msg: String
				if code == -1:
					msg = "TLS error -1 | %s | %s" % [_tls_mode, _diag]
				elif code >= 0:
					msg = "Disconnected from server (code %d%s)" % [code, ": " + reason if reason != "" else ""]
				else:
					msg = "Disconnected from server"
				emit_signal("connection_error", msg)
		WebSocketPeer.STATE_CONNECTING:
			pass

# ── Internal ───────────────────────────────────────────────────────────────
func _set_state(new_state: int) -> void:
	if new_state == _state:
		return
	_state = new_state
	emit_signal("connection_state_changed", new_state)

func _verify_fingerprint_or_disconnect() -> void:
	pass # reserved for future cert pinning

func _send(obj: Dictionary) -> void:
	if _peer == null:
		return
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var err := _peer.send_text(JSON.stringify(obj))
	if err != OK:
		push_warning("OnlineClient: failed to send (%d)" % err)

func _handle_raw(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("OnlineClient: invalid frame: %s" % raw)
		return
	var msg: Dictionary = parsed
	var mtype: String = str(msg.get("type", ""))
	match mtype:
		"welcome":
			_session_token = str(msg.get("session_token", ""))
			_set_state(State.READY)
			emit_signal("welcomed", int(msg.get("online_count", 0)))
		"online_count":
			emit_signal("online_count_updated", int(msg.get("online_count", 0)))
		"room_list":
			emit_signal("room_list_updated",
				msg.get("rooms", []), int(msg.get("online_count", 0)))
		"room_created":
			var room: Dictionary = msg.get("room", {})
			_current_room_id = str(room.get("room_id", ""))
			_your_color = str(room.get("your_color", ""))
			emit_signal("room_created", room)
		"room_joined":
			var rj: Dictionary = msg.get("room", {})
			_current_room_id = str(rj.get("room_id", ""))
			_your_color = str(rj.get("your_color", ""))
			emit_signal("room_joined", rj, str(msg.get("role", "")))
		"room_updated":
			var ru: Dictionary = msg.get("room", {})
			if str(ru.get("your_color", "")) != "":
				_your_color = str(ru.get("your_color", ""))
			emit_signal("room_updated", ru)
		"room_deleted":
			_current_room_id = ""
			_your_color = ""
			emit_signal("room_deleted",
				str(msg.get("room_id", "")), str(msg.get("reason", "")))
		"game_start":
			_your_color = str(msg.get("your_color", _your_color))
			emit_signal("game_starting", msg)
		"move_applied":
			emit_signal("move_applied", msg)
		"draw_offer":
			emit_signal("draw_offered", str(msg.get("from_color", "")))
		"draw_declined":
			emit_signal("draw_declined")
		"game_over":
			emit_signal("game_over_received", msg)
		"error":
			emit_signal("server_error",
				str(msg.get("code", "")), str(msg.get("message", "")))
		"pong":
			pass
		"kicked":
			emit_signal("connection_error", "Kicked: %s" % msg.get("reason", ""))
			disconnect_from_server()
		_:
			push_warning("OnlineClient: unknown message type '%s'" % mtype)
