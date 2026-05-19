// ai_state.cpp
// Duke's Gambit AI — Implementation of bitboard state, magic bitboards,
// Zobrist hashing, and pseudo-legal / tactical move generation.

#include "ai_state.h"

#include <atomic>
#include <bit>
#include <cstring>

namespace dukes_ai {

// ===========================================================================
// Global tables (definitions)
// ===========================================================================
uint64_t ZOBRIST_PIECES[NUM_COLORS][NUM_PIECE_TYPES][NUM_SQUARES];
uint64_t ZOBRIST_CASTLING[16];
uint64_t ZOBRIST_EP_FILE[8];
uint64_t ZOBRIST_SIDE;

Bitboard KNIGHT_ATTACKS[NUM_SQUARES];
Bitboard KING_ATTACKS[NUM_SQUARES];
Bitboard PAWN_ATTACKS[NUM_COLORS][NUM_SQUARES];

Magic ROOK_MAGICS[NUM_SQUARES];
Magic BISHOP_MAGICS[NUM_SQUARES];

// Per-square attack tables (plain magic bitboards). Sized to known totals:
//   sum_{sq} (1 << popcount(rook_mask[sq]))   == 102400
//   sum_{sq} (1 << popcount(bishop_mask[sq])) == 5248
static Bitboard ROOK_TABLE[102400];
static Bitboard BISHOP_TABLE[5248];

// Castling-rights mask applied (AND-ed) on every move's from/to square.
// Initialised in init_tables().
static uint8_t CASTLING_MASK[NUM_SQUARES];

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
static inline int pop_lsb(Bitboard &b) {
	int sq = std::countr_zero(b);
	b &= b - 1;
	return sq;
}

static inline int popcount(Bitboard b) {
	return std::popcount(b);
}

// Deterministic PRNG (splitmix64).
struct SplitMix64 {
	uint64_t state;
	uint64_t next() {
		uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
		z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
		z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
		return z ^ (z >> 31);
	}
	uint64_t sparse() { return next() & next() & next(); }
};

// Slow ray attack used during table initialisation.
static Bitboard slow_slider_attacks(int sq, Bitboard occ, const int dirs[4][2]) {
	Bitboard atk = 0;
	for (int d = 0; d < 4; ++d) {
		int f = file_of(sq), r = rank_of(sq);
		while (true) {
			f += dirs[d][0];
			r += dirs[d][1];
			if (f < 0 || f > 7 || r < 0 || r > 7) {
				break;
			}
			int s = square_of(f, r);
			atk |= square_bb(s);
			if (occ & square_bb(s)) {
				break;
			}
		}
	}
	return atk;
}

static const int ROOK_DIRS[4][2]   = { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } };
static const int BISHOP_DIRS[4][2] = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } };

static Bitboard rook_relevant_mask(int sq) {
	Bitboard m = 0;
	int f = file_of(sq), r = rank_of(sq);
	for (int rr = r + 1; rr <= 6; ++rr) m |= square_bb(square_of(f, rr));
	for (int rr = r - 1; rr >= 1; --rr) m |= square_bb(square_of(f, rr));
	for (int ff = f + 1; ff <= 6; ++ff) m |= square_bb(square_of(ff, r));
	for (int ff = f - 1; ff >= 1; --ff) m |= square_bb(square_of(ff, r));
	return m;
}

static Bitboard bishop_relevant_mask(int sq) {
	Bitboard m = 0;
	int f = file_of(sq), r = rank_of(sq);
	for (int ff = f + 1, rr = r + 1; ff <= 6 && rr <= 6; ++ff, ++rr) m |= square_bb(square_of(ff, rr));
	for (int ff = f + 1, rr = r - 1; ff <= 6 && rr >= 1; ++ff, --rr) m |= square_bb(square_of(ff, rr));
	for (int ff = f - 1, rr = r + 1; ff >= 1 && rr <= 6; --ff, ++rr) m |= square_bb(square_of(ff, rr));
	for (int ff = f - 1, rr = r - 1; ff >= 1 && rr >= 1; --ff, --rr) m |= square_bb(square_of(ff, rr));
	return m;
}

// ---------------------------------------------------------------------------
// Magic generation
// ---------------------------------------------------------------------------
static void generate_magics(Magic out_magics[NUM_SQUARES], Bitboard *table,
		bool is_bishop, SplitMix64 &rng) {
	size_t offset = 0;
	for (int sq = 0; sq < NUM_SQUARES; ++sq) {
		Magic &m = out_magics[sq];
		m.mask = is_bishop ? bishop_relevant_mask(sq) : rook_relevant_mask(sq);
		int bits = popcount(m.mask);
		m.shift = uint8_t(64 - bits);

		int size = 1 << bits;
		Bitboard subsets[4096];
		Bitboard refs[4096];

		// Enumerate all subsets of m.mask using the carry-rippler trick.
		Bitboard b = 0;
		int n = 0;
		do {
			subsets[n] = b;
			refs[n] = slow_slider_attacks(sq, b, is_bishop ? BISHOP_DIRS : ROOK_DIRS);
			++n;
			b = (b - m.mask) & m.mask;
		} while (b);

		// Search for a magic number.
		Bitboard candidate;
		Bitboard tmp[4096];
		while (true) {
			candidate = rng.sparse();
			// Discard magics with too few high-bits — they rarely work.
			if (popcount((m.mask * candidate) & 0xFF00000000000000ULL) < 6) {
				continue;
			}
			std::memset(tmp, 0, sizeof(Bitboard) * size);
			bool fail = false;
			for (int i = 0; i < n; ++i) {
				unsigned idx = unsigned((subsets[i] * candidate) >> m.shift);
				if (tmp[idx] == 0) {
					tmp[idx] = refs[i];
				} else if (tmp[idx] != refs[i]) {
					fail = true;
					break;
				}
			}
			if (!fail) {
				break;
			}
		}
		m.magic = candidate;
		m.attacks = table + offset;
		std::memcpy(table + offset, tmp, sizeof(Bitboard) * size);
		offset += size;
	}
}

// ---------------------------------------------------------------------------
// init_tables — one-time setup. Thread-safe via atomic flag.
// ---------------------------------------------------------------------------
static std::atomic<bool> g_tables_ready{ false };
static std::atomic<bool> g_tables_init_in_progress{ false };

void init_tables() {
	if (g_tables_ready.load(std::memory_order_acquire)) {
		return;
	}
	bool expected = false;
	if (!g_tables_init_in_progress.compare_exchange_strong(expected, true)) {
		// Another thread is initialising — busy-wait briefly.
		while (!g_tables_ready.load(std::memory_order_acquire)) {
			// Spin (very short window).
		}
		return;
	}

	// --- Zobrist ---
	SplitMix64 zrng{ 0x1D8E13C4A3F7BEEFULL };
	for (int c = 0; c < NUM_COLORS; ++c) {
		for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
			for (int sq = 0; sq < NUM_SQUARES; ++sq) {
				ZOBRIST_PIECES[c][pt][sq] = zrng.next();
			}
		}
	}
	for (int i = 0; i < 16; ++i) {
		ZOBRIST_CASTLING[i] = zrng.next();
	}
	for (int f = 0; f < 8; ++f) {
		ZOBRIST_EP_FILE[f] = zrng.next();
	}
	ZOBRIST_SIDE = zrng.next();

	// --- Knight attacks ---
	for (int sq = 0; sq < NUM_SQUARES; ++sq) {
		int f = file_of(sq), r = rank_of(sq);
		Bitboard atk = 0;
		const int offs[8][2] = {
			{ 1, 2 }, { 2, 1 }, { -1, 2 }, { -2, 1 },
			{ 1, -2 }, { 2, -1 }, { -1, -2 }, { -2, -1 },
		};
		for (auto &o : offs) {
			int ff = f + o[0], rr = r + o[1];
			if (ff >= 0 && ff < 8 && rr >= 0 && rr < 8) {
				atk |= square_bb(square_of(ff, rr));
			}
		}
		KNIGHT_ATTACKS[sq] = atk;
	}

	// --- King attacks ---
	for (int sq = 0; sq < NUM_SQUARES; ++sq) {
		int f = file_of(sq), r = rank_of(sq);
		Bitboard atk = 0;
		for (int df = -1; df <= 1; ++df) {
			for (int dr = -1; dr <= 1; ++dr) {
				if (df == 0 && dr == 0) continue;
				int ff = f + df, rr = r + dr;
				if (ff >= 0 && ff < 8 && rr >= 0 && rr < 8) {
					atk |= square_bb(square_of(ff, rr));
				}
			}
		}
		KING_ATTACKS[sq] = atk;
	}

	// --- Pawn attacks ---
	for (int sq = 0; sq < NUM_SQUARES; ++sq) {
		int f = file_of(sq), r = rank_of(sq);
		Bitboard w = 0, b = 0;
		if (r < 7) {
			if (f > 0) w |= square_bb(square_of(f - 1, r + 1));
			if (f < 7) w |= square_bb(square_of(f + 1, r + 1));
		}
		if (r > 0) {
			if (f > 0) b |= square_bb(square_of(f - 1, r - 1));
			if (f < 7) b |= square_bb(square_of(f + 1, r - 1));
		}
		PAWN_ATTACKS[WHITE][sq] = w;
		PAWN_ATTACKS[BLACK][sq] = b;
	}

	// --- Magic bitboards ---
	SplitMix64 mrng{ 0xC0DE5EED1234ABCDULL };
	generate_magics(ROOK_MAGICS, ROOK_TABLE, false, mrng);
	generate_magics(BISHOP_MAGICS, BISHOP_TABLE, true, mrng);

	// --- Castling masks ---
	for (int i = 0; i < NUM_SQUARES; ++i) {
		CASTLING_MASK[i] = 0xFF;
	}
	CASTLING_MASK[A1] = uint8_t(~CR_WQ);
	CASTLING_MASK[H1] = uint8_t(~CR_WK);
	CASTLING_MASK[E1] = uint8_t(~CR_WHITE);
	CASTLING_MASK[A8] = uint8_t(~CR_BQ);
	CASTLING_MASK[H8] = uint8_t(~CR_BK);
	CASTLING_MASK[E8] = uint8_t(~CR_BLACK);

	g_tables_ready.store(true, std::memory_order_release);
}

// ===========================================================================
// SearchState — implementation
// ===========================================================================

void SearchState::clear() {
	std::memset(pieces, 0, sizeof(pieces));
	occupancy[WHITE] = occupancy[BLACK] = 0;
	occupancy_all = 0;
	side_to_move = WHITE;
	castling_rights = 0;
	ep_square = -1;
	halfmove_clock = 0;
	fullmove_number = 1;
	ply = 0;
	zobrist = 0;
	undo_count = 0;
	hash_history_count = 0;
}

void SearchState::load_position(const int32_t board[64], int side, int castling,
		int ep_index, int halfmove, int fullmove) {
	clear();
	for (int sq = 0; sq < 64; ++sq) {
		int code = board[sq];
		if (code <= 0) continue;
		ExternalPiece p = decode_external_piece(code);
		if (p.type >= PT_NONE) continue;
		Bitboard bb = square_bb(sq);
		pieces[p.color][p.type] |= bb;
		occupancy[p.color] |= bb;
	}
	occupancy_all = occupancy[WHITE] | occupancy[BLACK];
	side_to_move = uint8_t(side & 1);
	castling_rights = uint8_t(castling & CR_ALL);
	ep_square = (ep_index >= 0 && ep_index < 64) ? int8_t(ep_index) : int8_t(-1);
	halfmove_clock = uint8_t(halfmove < 0 ? 0 : (halfmove > 255 ? 255 : halfmove));
	fullmove_number = uint16_t(fullmove < 1 ? 1 : fullmove);
	recompute_zobrist();
	hash_history[0] = zobrist;
	hash_history_count = 1;
}

void SearchState::recompute_zobrist() {
	uint64_t h = 0;
	for (int c = 0; c < NUM_COLORS; ++c) {
		for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
			Bitboard b = pieces[c][pt];
			while (b) {
				int sq = pop_lsb(b);
				h ^= ZOBRIST_PIECES[c][pt][sq];
			}
		}
	}
	h ^= ZOBRIST_CASTLING[castling_rights & 0xF];
	if (ep_square >= 0) {
		h ^= ZOBRIST_EP_FILE[file_of(ep_square)];
	}
	if (side_to_move == BLACK) {
		h ^= ZOBRIST_SIDE;
	}
	zobrist = h;
}

uint8_t SearchState::piece_type_on(int sq) const {
	Bitboard bb = square_bb(sq);
	if (!(occupancy_all & bb)) return PT_NONE;
	for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
		if ((pieces[WHITE][pt] | pieces[BLACK][pt]) & bb) {
			return uint8_t(pt);
		}
	}
	return PT_NONE;
}

uint8_t SearchState::color_on(int sq) const {
	Bitboard bb = square_bb(sq);
	if (occupancy[WHITE] & bb) return WHITE;
	if (occupancy[BLACK] & bb) return BLACK;
	return uint8_t(0xFF);
}

Bitboard SearchState::attackers_to(int sq, Bitboard occ) const {
	Bitboard atk = 0;
	atk |= PAWN_ATTACKS[BLACK][sq] & pieces[WHITE][PAWN];
	atk |= PAWN_ATTACKS[WHITE][sq] & pieces[BLACK][PAWN];
	atk |= KNIGHT_ATTACKS[sq] & (pieces[WHITE][KNIGHT] | pieces[BLACK][KNIGHT]);
	atk |= KING_ATTACKS[sq]   & (pieces[WHITE][KING]   | pieces[BLACK][KING]);
	Bitboard bishops_queens = pieces[WHITE][BISHOP] | pieces[BLACK][BISHOP]
			| pieces[WHITE][QUEEN]  | pieces[BLACK][QUEEN];
	Bitboard rooks_queens   = pieces[WHITE][ROOK]   | pieces[BLACK][ROOK]
			| pieces[WHITE][QUEEN]  | pieces[BLACK][QUEEN];
	atk |= bishop_attacks(sq, occ) & bishops_queens;
	atk |= rook_attacks(sq, occ)   & rooks_queens;
	return atk;
}

bool SearchState::is_square_attacked(int sq, int by_color) const {
	const int c = by_color & 1;
	if (PAWN_ATTACKS[1 - c][sq] & pieces[c][PAWN]) return true;
	if (KNIGHT_ATTACKS[sq] & pieces[c][KNIGHT])    return true;
	if (KING_ATTACKS[sq]   & pieces[c][KING])      return true;
	Bitboard bq = pieces[c][BISHOP] | pieces[c][QUEEN];
	if (bishop_attacks(sq, occupancy_all) & bq)    return true;
	Bitboard rq = pieces[c][ROOK]   | pieces[c][QUEEN];
	if (rook_attacks(sq, occupancy_all) & rq)      return true;
	return false;
}

bool SearchState::in_check() const {
	return in_check(side_to_move);
}

bool SearchState::in_check(int color) const {
	Bitboard king_bb = pieces[color & 1][KING];
	if (!king_bb) return false;
	int king_sq = std::countr_zero(king_bb);
	return is_square_attacked(king_sq, 1 - (color & 1));
}

bool SearchState::is_repetition() const {
	// Walk back through halfmove_clock positions, looking for matching zobrist.
	int n = hash_history_count;
	int limit = n - 1 - halfmove_clock;
	if (limit < 0) limit = 0;
	for (int i = n - 3; i >= limit; i -= 2) {
		if (hash_history[i] == zobrist) {
			return true;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// Internal bitboard mutators (also update zobrist).
// ---------------------------------------------------------------------------
void SearchState::place_piece(int color, int type, int sq) {
	Bitboard bb = square_bb(sq);
	pieces[color][type] |= bb;
	occupancy[color]    |= bb;
	occupancy_all       |= bb;
	zobrist ^= ZOBRIST_PIECES[color][type][sq];
}

void SearchState::remove_piece(int color, int type, int sq) {
	Bitboard bb = square_bb(sq);
	pieces[color][type] ^= bb;
	occupancy[color]    ^= bb;
	occupancy_all       ^= bb;
	zobrist ^= ZOBRIST_PIECES[color][type][sq];
}

void SearchState::move_piece(int color, int type, int from, int to) {
	Bitboard bb = square_bb(from) | square_bb(to);
	pieces[color][type] ^= bb;
	occupancy[color]    ^= bb;
	occupancy_all       ^= bb;
	zobrist ^= ZOBRIST_PIECES[color][type][from];
	zobrist ^= ZOBRIST_PIECES[color][type][to];
}

// ===========================================================================
// make_move / unmake_move
// ===========================================================================
void SearchState::make_move(Move m) {
	const int from = m.from();
	const int to   = m.to();
	const MoveFlag flag = m.flag();
	const int us   = side_to_move;
	const int them = 1 - us;

	const uint8_t moved_type = piece_type_on(from);

	// Save undo state.
	UndoState &u = undo_stack[undo_count++];
	u.zobrist        = zobrist;
	u.castling       = castling_rights;
	u.ep_square      = ep_square;
	u.halfmove_clock = halfmove_clock;
	u.captured_type  = PT_NONE;
	u.captured_color = uint8_t(them);
	u.captured_sq    = -1;
	u.moved_type     = moved_type;

	// Remove any existing EP file from zobrist; will re-add if a new EP square is set.
	if (ep_square >= 0) {
		zobrist ^= ZOBRIST_EP_FILE[file_of(ep_square)];
	}
	ep_square = -1;

	// Increment halfmove clock by default (reset for pawn moves / captures below).
	halfmove_clock = uint8_t(halfmove_clock + 1);

	if (flag == MF_CASTLING) {
		// Move king.
		move_piece(us, KING, from, to);
		// Determine rook from/to from the king destination square.
		int rook_from, rook_to;
		if (to == G1)      { rook_from = H1; rook_to = F1; }
		else if (to == C1) { rook_from = A1; rook_to = D1; }
		else if (to == G8) { rook_from = H8; rook_to = F8; }
		else                { rook_from = A8; rook_to = D8; }
		move_piece(us, ROOK, rook_from, rook_to);
	} else if (flag == MF_EN_PASSANT) {
		// Move the pawn, capture is on adjacent square.
		int captured_sq = (us == WHITE) ? (to - 8) : (to + 8);
		move_piece(us, PAWN, from, to);
		remove_piece(them, PAWN, captured_sq);
		u.captured_type = PAWN;
		u.captured_sq   = int8_t(captured_sq);
		halfmove_clock = 0;
	} else {
		// Possibly a capture on `to`.
		if (occupancy[them] & square_bb(to)) {
			// Find captured piece type.
			Bitboard to_bb = square_bb(to);
			for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
				if (pieces[them][pt] & to_bb) {
					u.captured_type = uint8_t(pt);
					u.captured_sq   = int8_t(to);
					remove_piece(them, pt, to);
					break;
				}
			}
			halfmove_clock = 0;
		}

		if (flag == MF_PROMOTION) {
			// Remove pawn from `from`, place promotion piece on `to`.
			remove_piece(us, PAWN, from);
			place_piece(us, m.promotion_type(), to);
			halfmove_clock = 0;
		} else {
			move_piece(us, moved_type, from, to);
			if (moved_type == PAWN) {
				halfmove_clock = 0;
				// Detect double pawn push to set EP square.
				int delta = to - from;
				if (delta == 16 || delta == -16) {
					int new_ep = (us == WHITE) ? (from + 8) : (from - 8);
					// Only set EP if an enemy pawn could actually capture.
					if (PAWN_ATTACKS[us][new_ep] & pieces[them][PAWN]) {
						ep_square = int8_t(new_ep);
						zobrist ^= ZOBRIST_EP_FILE[file_of(new_ep)];
					}
				}
			}
		}
	}

	// Update castling rights via from/to masks.
	uint8_t new_castling = castling_rights & CASTLING_MASK[from] & CASTLING_MASK[to];
	if (new_castling != castling_rights) {
		zobrist ^= ZOBRIST_CASTLING[castling_rights];
		zobrist ^= ZOBRIST_CASTLING[new_castling];
		castling_rights = new_castling;
	}

	// Flip side.
	side_to_move = uint8_t(them);
	zobrist ^= ZOBRIST_SIDE;

	if (us == BLACK) {
		++fullmove_number;
	}
	++ply;

	hash_history[hash_history_count++] = zobrist;
}

void SearchState::unmake_move(Move m) {
	const int from = m.from();
	const int to   = m.to();
	const MoveFlag flag = m.flag();

	--ply;
	--hash_history_count;
	UndoState &u = undo_stack[--undo_count];

	const int us   = 1 - side_to_move; // We are unmaking; original mover.
	const int them = side_to_move;

	side_to_move = uint8_t(us);
	if (us == BLACK) {
		--fullmove_number;
	}

	if (flag == MF_CASTLING) {
		// Reverse rook and king.
		int rook_from, rook_to;
		if (to == G1)      { rook_from = H1; rook_to = F1; }
		else if (to == C1) { rook_from = A1; rook_to = D1; }
		else if (to == G8) { rook_from = H8; rook_to = F8; }
		else                { rook_from = A8; rook_to = D8; }
		// Restore zobrist by simply reusing move_piece (it XORs both endpoints).
		// We use raw bit-toggle to avoid touching zobrist (we'll restore from u).
		Bitboard kbb = square_bb(from) | square_bb(to);
		pieces[us][KING] ^= kbb;
		occupancy[us]    ^= kbb;
		occupancy_all    ^= kbb;
		Bitboard rbb = square_bb(rook_from) | square_bb(rook_to);
		pieces[us][ROOK] ^= rbb;
		occupancy[us]    ^= rbb;
		occupancy_all    ^= rbb;
	} else if (flag == MF_EN_PASSANT) {
		// Move pawn back, restore captured pawn.
		Bitboard pbb = square_bb(from) | square_bb(to);
		pieces[us][PAWN] ^= pbb;
		occupancy[us]    ^= pbb;
		occupancy_all    ^= pbb;
		int cap_sq = u.captured_sq;
		pieces[them][PAWN] |= square_bb(cap_sq);
		occupancy[them]    |= square_bb(cap_sq);
		occupancy_all      |= square_bb(cap_sq);
	} else if (flag == MF_PROMOTION) {
		// Remove promoted piece from `to`, restore pawn on `from`.
		int promo = m.promotion_type();
		pieces[us][promo] ^= square_bb(to);
		occupancy[us]     ^= square_bb(to);
		occupancy_all     ^= square_bb(to);
		pieces[us][PAWN]  |= square_bb(from);
		occupancy[us]     |= square_bb(from);
		occupancy_all     |= square_bb(from);
		// Restore captured piece (if any).
		if (u.captured_type < PT_NONE) {
			pieces[them][u.captured_type] |= square_bb(to);
			occupancy[them]               |= square_bb(to);
			occupancy_all                 |= square_bb(to);
		}
	} else {
		// Normal move (possibly a capture).
		uint8_t mt = u.moved_type;
		Bitboard mbb = square_bb(from) | square_bb(to);
		pieces[us][mt] ^= mbb;
		occupancy[us]  ^= mbb;
		occupancy_all  ^= mbb;
		if (u.captured_type < PT_NONE) {
			pieces[them][u.captured_type] |= square_bb(to);
			occupancy[them]               |= square_bb(to);
			occupancy_all                 |= square_bb(to);
		}
	}

	// Restore scalar fields and zobrist.
	zobrist         = u.zobrist;
	castling_rights = u.castling;
	ep_square       = u.ep_square;
	halfmove_clock  = u.halfmove_clock;
}

void SearchState::make_null_move() {
	UndoState &u = undo_stack[undo_count++];
	u.zobrist        = zobrist;
	u.castling       = castling_rights;
	u.ep_square      = ep_square;
	u.halfmove_clock = halfmove_clock;
	u.captured_type  = PT_NONE;
	u.captured_color = uint8_t(1 - side_to_move);
	u.captured_sq    = -1;
	u.moved_type     = PT_NONE;

	if (ep_square >= 0) {
		zobrist ^= ZOBRIST_EP_FILE[file_of(ep_square)];
		ep_square = -1;
	}
	side_to_move = uint8_t(1 - side_to_move);
	zobrist ^= ZOBRIST_SIDE;
	++halfmove_clock;
	++ply;
	hash_history[hash_history_count++] = zobrist;
}

void SearchState::unmake_null_move() {
	--ply;
	--hash_history_count;
	UndoState &u = undo_stack[--undo_count];
	side_to_move    = uint8_t(1 - side_to_move);
	zobrist         = u.zobrist;
	castling_rights = u.castling;
	ep_square       = u.ep_square;
	halfmove_clock  = u.halfmove_clock;
}

// ===========================================================================
// Pseudo-legal move generation
// ===========================================================================
namespace {

inline void add_pawn_promotions(MoveList &out, int from, int to) {
	out.add(Move::make(from, to, MF_PROMOTION, QUEEN));
	out.add(Move::make(from, to, MF_PROMOTION, ROOK));
	out.add(Move::make(from, to, MF_PROMOTION, BISHOP));
	out.add(Move::make(from, to, MF_PROMOTION, KNIGHT));
}

template <bool TacticalOnly>
inline void generate_pawn_moves(const SearchState &s, MoveList &out) {
	const int us   = s.side_to_move;
	const int them = 1 - us;
	const Bitboard own_pawns = s.pieces[us][PAWN];
	const Bitboard empty     = ~s.occupancy_all;
	const Bitboard enemies   = s.occupancy[them];
	const Bitboard promo_rank = (us == WHITE) ? RANK_8_BB : RANK_1_BB;

	// Push offsets.
	const int push_dir = (us == WHITE) ? 8 : -8;
	const Bitboard rank_to_double = (us == WHITE) ? RANK_3_BB : RANK_6_BB;

	// Single pushes.
	Bitboard single_push = (us == WHITE)
			? ((own_pawns << 8) & empty)
			: ((own_pawns >> 8) & empty);

	if (!TacticalOnly) {
		Bitboard quiet_push = single_push & ~promo_rank;
		Bitboard q = quiet_push;
		while (q) {
			int to = pop_lsb(q);
			int from = to - push_dir;
			out.add(Move::make(from, to));
		}
		// Double pushes (from pawn on starting rank, single-push square clear).
		Bitboard double_push = (us == WHITE)
				? (((single_push & rank_to_double) << 8) & empty)
				: (((single_push & rank_to_double) >> 8) & empty);
		Bitboard d = double_push;
		while (d) {
			int to = pop_lsb(d);
			int from = to - 2 * push_dir;
			out.add(Move::make(from, to));
		}
	}

	// Promotion pushes (always generated, even in tactical mode).
	Bitboard promo_push = single_push & promo_rank;
	while (promo_push) {
		int to = pop_lsb(promo_push);
		int from = to - push_dir;
		add_pawn_promotions(out, from, to);
	}

	// Captures.
	Bitboard left_caps, right_caps;
	if (us == WHITE) {
		left_caps  = ((own_pawns & ~FILE_A_BB) << 7) & enemies;
		right_caps = ((own_pawns & ~FILE_H_BB) << 9) & enemies;
	} else {
		left_caps  = ((own_pawns & ~FILE_H_BB) >> 7) & enemies;
		right_caps = ((own_pawns & ~FILE_A_BB) >> 9) & enemies;
	}
	const int lcap_dir = (us == WHITE) ? 7  : -7;
	const int rcap_dir = (us == WHITE) ? 9  : -9;

	auto emit_caps = [&](Bitboard caps, int dir) {
		Bitboard promo_caps = caps & promo_rank;
		Bitboard quiet_caps = caps & ~promo_rank;
		while (promo_caps) {
			int to = pop_lsb(promo_caps);
			int from = to - dir;
			add_pawn_promotions(out, from, to);
		}
		while (quiet_caps) {
			int to = pop_lsb(quiet_caps);
			int from = to - dir;
			out.add(Move::make(from, to));
		}
	};
	emit_caps(left_caps,  lcap_dir);
	emit_caps(right_caps, rcap_dir);

	// En passant.
	if (s.ep_square >= 0) {
		Bitboard ep_attackers = PAWN_ATTACKS[them][s.ep_square] & own_pawns;
		while (ep_attackers) {
			int from = pop_lsb(ep_attackers);
			out.add(Move::make(from, s.ep_square, MF_EN_PASSANT));
		}
	}
}

template <bool TacticalOnly>
inline void generate_piece_moves(const SearchState &s, MoveList &out) {
	const int us   = s.side_to_move;
	const Bitboard own = s.occupancy[us];
	const Bitboard enemies = s.occupancy[1 - us];
	const Bitboard target_mask = TacticalOnly ? enemies : ~own;

	// Knights.
	Bitboard knights = s.pieces[us][KNIGHT];
	while (knights) {
		int from = pop_lsb(knights);
		Bitboard atk = KNIGHT_ATTACKS[from] & target_mask;
		while (atk) {
			int to = pop_lsb(atk);
			out.add(Move::make(from, to));
		}
	}

	// Bishops.
	Bitboard bishops = s.pieces[us][BISHOP];
	while (bishops) {
		int from = pop_lsb(bishops);
		Bitboard atk = bishop_attacks(from, s.occupancy_all) & target_mask;
		while (atk) {
			int to = pop_lsb(atk);
			out.add(Move::make(from, to));
		}
	}

	// Rooks.
	Bitboard rooks = s.pieces[us][ROOK];
	while (rooks) {
		int from = pop_lsb(rooks);
		Bitboard atk = rook_attacks(from, s.occupancy_all) & target_mask;
		while (atk) {
			int to = pop_lsb(atk);
			out.add(Move::make(from, to));
		}
	}

	// Queens.
	Bitboard queens = s.pieces[us][QUEEN];
	while (queens) {
		int from = pop_lsb(queens);
		Bitboard atk = queen_attacks(from, s.occupancy_all) & target_mask;
		while (atk) {
			int to = pop_lsb(atk);
			out.add(Move::make(from, to));
		}
	}

	// King (non-castling).
	Bitboard king_bb = s.pieces[us][KING];
	if (king_bb) {
		int from = std::countr_zero(king_bb);
		Bitboard atk = KING_ATTACKS[from] & target_mask;
		while (atk) {
			int to = pop_lsb(atk);
			out.add(Move::make(from, to));
		}

		// Castling (only in full generation, not tactical).
		if (!TacticalOnly) {
			const int us2 = s.side_to_move;
			const int them = 1 - us2;
			if (!s.is_square_attacked(from, them)) {
				if (us2 == WHITE) {
					if ((s.castling_rights & CR_WK)
							&& !(s.occupancy_all & (square_bb(F1) | square_bb(G1)))
							&& !s.is_square_attacked(F1, them)
							&& !s.is_square_attacked(G1, them)) {
						out.add(Move::make(E1, G1, MF_CASTLING));
					}
					if ((s.castling_rights & CR_WQ)
							&& !(s.occupancy_all & (square_bb(B1) | square_bb(C1) | square_bb(D1)))
							&& !s.is_square_attacked(D1, them)
							&& !s.is_square_attacked(C1, them)) {
						out.add(Move::make(E1, C1, MF_CASTLING));
					}
				} else {
					if ((s.castling_rights & CR_BK)
							&& !(s.occupancy_all & (square_bb(F8) | square_bb(G8)))
							&& !s.is_square_attacked(F8, them)
							&& !s.is_square_attacked(G8, them)) {
						out.add(Move::make(E8, G8, MF_CASTLING));
					}
					if ((s.castling_rights & CR_BQ)
							&& !(s.occupancy_all & (square_bb(B8) | square_bb(C8) | square_bb(D8)))
							&& !s.is_square_attacked(D8, them)
							&& !s.is_square_attacked(C8, them)) {
						out.add(Move::make(E8, C8, MF_CASTLING));
					}
				}
			}
		}
	}
}

} // namespace

void SearchState::generate_pseudo_moves(MoveList &out) const {
	out.clear();
	generate_pawn_moves<false>(*this, out);
	generate_piece_moves<false>(*this, out);
}

void SearchState::generate_tactical_moves(MoveList &out) const {
	out.clear();
	generate_pawn_moves<true>(*this, out);
	generate_piece_moves<true>(*this, out);
}

// ---------------------------------------------------------------------------
// Legality check — performs a temporary make/unmake.
// Search code should iterate pseudo-legal moves and skip those failing this.
// ---------------------------------------------------------------------------
bool SearchState::is_legal(Move m) const {
	// We need to test on a non-const copy without affecting `this`.
	SearchState &mut = const_cast<SearchState &>(*this);
	mut.make_move(m);
	bool ok = !mut.in_check(1 - mut.side_to_move);
	mut.unmake_move(m);
	return ok;
}

} // namespace dukes_ai
