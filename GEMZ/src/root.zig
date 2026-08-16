//! GEMZ — idiomatic Zig wrappers for Atari ST GEM (AES + VDI).
//!
//! Freestanding m68k, no std lib; every system call is inline m68k asm.
//! The AES (trap #2, d0 = $C8) parameter block layout and calling convention
//! follow the working `hello/src/main.zig` example and the canonical reference
//! at `libs/toslibc/include/toslibc/tos/aes.h`.
//!
//! Everything lives in this one file for now; the structs (`app`, `Window`,
//! `Object`, …) will be split into separate files later.

const std = @import("std");

// ---------------------------------------------------------------------------
// AES parameter block (trap #2, d0 = $C8)
// ---------------------------------------------------------------------------

const AesControl = extern struct {
    opcode: u16,
    n_int_in: u16,
    n_int_out: u16,
    n_addr_in: u16,
    n_addr_out: u16,
};

const AesGlobal = extern struct {
    version: u16,
    app_max: u16,
    app_id: u16,
    user: u32,
    rsc: ?[*]const u8,
    reserved: [4]u32,
};

const AesPb = extern struct {
    control: *AesControl,
    global: *AesGlobal,
    int_in: ?[*]const i16,
    int_out: [*]i16,
    addr_in: ?[*]const ?[*]const u8,
    addr_out: [*]?[*]u8,
};

/// Input arrays for an AES call, passed to `aesCall` by pointer. Passing slices
/// instead trips an m68k backend bug: a slice *length* carried in `d1` arrives
/// as 0, so `int_in` gets nulled. Lengths read back from memory are safe.
const AesArgs = extern struct {
    int_in: ?[*]const i16,
    n_int_in: u16,
    addr_in: ?[*]const ?[*]const u8,
    n_addr_in: u16,
    n_int_out: u16,

    /// No inputs (appl_init, appl_exit).
    pub fn none() AesArgs {
        return .{
            .int_in = null,
            .n_int_in = 0,
            .addr_in = null,
            .n_addr_in = 0,
            .n_int_out = 1,
        };
    }

    /// int_in only; explicit output count.
    pub fn ints(int_in: anytype, comptime out: u16) AesArgs {
        return .{
            .int_in = int_in,
            .n_int_in = @intCast(int_in.len),
            .addr_in = null,
            .n_addr_in = 0,
            .n_int_out = out,
        };
    }

    /// int_in + addr_in; explicit output count.
    pub fn from(int_in: anytype, addr_in: anytype, comptime out: u16) AesArgs {
        return .{
            .int_in = int_in,
            .n_int_in = @intCast(int_in.len),
            .addr_in = addr_in,
            .n_addr_in = @intCast(addr_in.len),
            .n_int_out = out,
        };
    }
};

/// AES opcodes (trap #2, d0 = $C8). Complete standard set.
pub const AesOpcode = enum(u16) {
    // appl_*
    appl_init = 10,
    appl_read = 11,
    appl_write = 12,
    appl_find = 13,
    appl_tplay = 14,
    appl_trecord = 15,
    appl_bvset = 16,
    appl_yield = 17,
    appl_search = 18,
    appl_exit = 19,

    // evnt_*
    evnt_keybd = 20,
    evnt_button = 21,
    evnt_mouse = 22,
    evnt_mesag = 23,
    evnt_timer = 24,
    evnt_multi = 25,
    evnt_dclick = 26,

    // menu_*
    menu_bar = 30,
    menu_icheck = 31,
    menu_ienable = 32,
    menu_tnormal = 33,
    menu_text = 34,
    menu_register = 35,
    menu_unregister = 36,

    // objc_*
    objc_add = 40,
    objc_delete = 41,
    objc_draw = 42,
    objc_find = 43,
    objc_offset = 44,
    objc_order = 45,
    objc_edit = 46,
    objc_change = 47,

    // form_*
    form_do = 50,
    form_dial = 51,
    form_alert = 52,
    form_error = 53,
    form_center = 54,
    form_keybd = 55,
    form_button = 56,

    // graf_*
    graf_rubberbox = 70,
    graf_dragbox = 71,
    graf_movebox = 72,
    graf_growbox = 73,
    graf_shrinkbox = 74,
    graf_watchbox = 75,
    graf_slidebox = 76,
    graf_handle = 77,
    graf_mouse = 78,
    graf_mkstate = 79,

    // scrp_*
    scrp_read = 80,
    scrp_write = 81,
    scrp_clear = 82,

    // fsel_*
    fsel_input = 90,

    // wind_*
    wind_create = 100,
    wind_open = 101,
    wind_close = 102,
    wind_delete = 103,
    wind_get = 104,
    wind_set = 105,
    wind_find = 106,
    wind_update = 107,
    wind_calc = 108,
    wind_new = 109,

    // rsrc_*
    rsrc_load = 110,
    rsrc_free = 111,
    rsrc_gaddr = 112,
    rsrc_saddr = 113,
    rsrc_obfix = 114,

    // shel_*
    shel_read = 120,
    shel_write = 121,
    shel_get = 122,
    shel_put = 123,
    shel_find = 124,
    shel_envrn = 125,
    shel_rdef = 126,
    shel_wdef = 127,

    // xgrf_*
    xgrf_stepcalc = 130,
    xgrf_2box = 131,

    // Unknown/extension opcode. Non-exhaustive so `@enumFromInt` of an
    // unlisted value is well-defined rather than UB.
    _,
};

/// The single AES global block. `appl_init` writes `app_id` here and it must
/// persist for the whole application lifetime.
var global: AesGlobal = .{
    .version = 0,
    .app_max = 0,
    .app_id = 0,
    .user = 0,
    .rsc = null,
    .reserved = .{0} ** 4,
};

/// The full 7-word output of the most recent AES call. Callers that need more
/// than the return code (`wind_get`, `evnt_multi`) read this after `aesCall`.
var aes_out: [7]i16 = .{ 0, 0, 0, 0, 0, 0, 0 };

fn aesTrap(pb: *const AesPb) void {
    asm volatile (
        \\move.l %[pb], %%d1
        \\move.w #0xc8, %%d0
        \\trap #2
        :
        : [pb] "r" (pb),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true });
}

/// Dispatch one AES call. `out[0]` is the implicit AES return code, declared
/// output integers start at index 1; the full 7 words are left in `aes_out`.
/// `n_int_out` is fixed at the AES maximum of 7; callers read only the words
/// they declared.
noinline fn aesCall(opcode: AesOpcode, args: *const AesArgs) i16 {
    var control = AesControl{
        .opcode = @intFromEnum(opcode),
        .n_int_in = args.n_int_in,
        .n_int_out = args.n_int_out,
        .n_addr_in = args.n_addr_in,
        .n_addr_out = 0,
    };
    var int_out: [7]i16 = .{ 0, 0, 0, 0, 0, 0, 0 };
    var addr_out: [1]?[*]u8 = .{null};

    const pb = AesPb{
        .control = &control,
        .global = &global,
        .int_in = args.int_in,
        .int_out = &int_out,
        .addr_in = args.addr_in,
        .addr_out = &addr_out,
    };

    aesTrap(&pb);
    aes_out = int_out;
    return int_out[0];
}

// ---------------------------------------------------------------------------
// GEMDOS exit (trap #1, function 0 = Pterm0)
// ---------------------------------------------------------------------------

fn pterm0() noreturn {
    asm volatile (
        \\move.w #0, -(%%sp)
        \\trap #1
        ::: .{ .memory = true });
    unreachable;
}

/// GEMDOS Cconws (trap #1, function 9) — write a NUL-terminated string to the
/// console. Visible on the host via Hatari `--conout 2`.
fn cconws(s: [*:0]const u8) void {
    asm volatile (
        \\move.l %[s], -(%%sp)
        \\move.w #9, -(%%sp)
        \\trap #1
        \\lea 6(%%sp), %%sp
        :
        : [s] "r" (s),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
}

/// TEMP DEBUG: print a comptime message to the GEMDOS console.
pub fn dbg(comptime msg: []const u8) void {
    const s: [*:0]const u8 = msg ++ "\r\n";
    cconws(s);
}

// ---------------------------------------------------------------------------
// Public GEM types
// ---------------------------------------------------------------------------

pub const Rect = extern struct {
    x: i16,
    y: i16,
    w: i16,
    h: i16,
};

pub const Point = extern struct {
    x: i16,
    y: i16,
};

/// `wind_create` attribute bits (kind).
pub const WindKind = packed struct(u16) {
    name: bool = false, // bit 0 — title bar
    closer: bool = false, // bit 1 — close box
    fuller: bool = false, // bit 2 — full box
    mover: bool = false, // bit 3 — move bar
    info: bool = false, // bit 4 — info line
    sizer: bool = false, // bit 5 — size box
    _pad: u10 = 0,
};

/// `wind_set` / `wind_get` field selectors.
pub const WindField = struct {
    pub const name: i16 = 2; // window title (string, addr_in)
    pub const info: i16 = 3; // info line (string, addr_in)
    pub const work_xywh: i16 = 4; // work area (window-relative)
    pub const curr_xywh: i16 = 5; // current window rect (screen-relative)
};

/// `wind_update` modes.
pub const WindUpdate = struct {
    pub const end_update: i16 = 0;
    pub const beg_update: i16 = 1;
};

/// GEM object types (`ob_type`).
pub const ObjectType = enum(u16) {
    box = 20,
    text = 21,
    box_text = 22,
    image = 23,
    prog_def = 24,
    i_box = 25,
    button = 26,
    string = 27,
    f_text = 28,
    f_box_text = 29,
    icon = 30,
    title = 31,
};

/// GEM object flags (bitmask; combine with `ObjectFlag.flags`).
pub const ObjectFlag = enum(u16) {
    none = 0,
    selectable = 0x0001,
    default_ = 0x0002,
    exit = 0x0004,
    editable = 0x0008,
    r_button = 0x0010,
    last_obj = 0x0020,
    touch_exit = 0x0040,
    hide_tree = 0x0080,
    _, // arbitrary bit combinations are valid

    /// Build a combined flags value from a set of flags.
    pub fn flags(set: []const ObjectFlag) ObjectFlag {
        var result: u16 = 0;
        for (set) |f| result |= @intFromEnum(f);
        return @enumFromInt(result);
    }
};

/// Standard Atari ST colour palette index (0-15). Bits 8-11 of a `te_color`
/// word select one of these for the text colour. Indices 8-15 are the
/// low-intensity versions of 0-7.
pub const Color = enum(u16) {
    white = 0,
    black = 1,
    red = 2,
    green = 3,
    blue = 4,
    cyan = 5,
    yellow = 6,
    magenta = 7,
    _,
};

/// Pack a palette index into a `te_color` word (text colour only; the
/// border/fill nibbles stay 0).
pub fn textColor(color: Color) i16 {
    return @intCast(@as(u16, @intFromEnum(color)) << 8);
}

/// Pack a palette colour into a G_BOX fill word. G_BOX stores its fill spec
/// directly in `ob_spec` (the low word): bits 0-3 = fill colour, bits 4-6 =
/// inside pattern (1 = solid), bits 12-15 = border colour.
fn boxFill(color: Color) u16 {
    const c: u16 = @intFromEnum(color) & 0xF;
    return c | (@as(u16, 1) << 4) | (c << 12);
}

// ---------------------------------------------------------------------------
// Music — YM2149 (PSG) three-voice sequencer
// ---------------------------------------------------------------------------

/// Max steps in one note sequence.
pub const max_notes = 64;

/// A voice channel. The YM2149 has three (A, B, C).
pub const Channel = enum(u8) { A = 0, B = 1, C = 2 };

/// Note periods as 12-bit YM2149 tone values (`period = 125000 / freq`,
/// A4 = 440 Hz = `a3`). Indexed `[octave][semitone]`; semitone order:
/// c, db, d, eb, e, f, gb, g, ab, a, bb, b. Octave 0 = scientific octave 1.
const noteTable = [4][12]u16{
    .{ 3822, 3608, 3405, 3214, 3034, 2863, 2703, 2551, 2408, 2273, 2145, 2025 },
    .{ 1911, 1804, 1703, 1607, 1517, 1432, 1351, 1276, 1204, 1136, 1073, 1012 },
    .{ 956, 902, 851, 804, 758, 716, 676, 638, 602, 568, 536, 506 },
    .{ 478, 451, 426, 402, 379, 358, 338, 319, 301, 284, 268, 253 },
};

/// Silence gap between notes, in 200 Hz ticks (5 ms each). 10 ticks = 50 ms —
/// long enough to audibly separate the low bass notes.
const note_gate_ticks: u16 = 10;

/// Coarse wake interval for the AES timer (ms). The sequencer does NOT trust
/// this for real timing — it reads the 200 Hz hardware counter instead.
const poll_ms: u16 = 25;

/// XBIOS Gettime (opcode 23) — the 200 Hz system timer count (32-bit, 5 ms per
/// tick). Called via a trap rather than reading `_hz_200` ($4BA) directly: a
/// direct low-memory read bus-errors in some emulator/TOS combinations, and the
/// XBIOS call is the official, TOS-version-safe way to reach the timer.
fn xbiosGetTime() u32 {
    var result: u32 = 0;
    asm volatile (
        \\move.w #23, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        \\move.l %%d0, %[result]
        : [result] "=m" (result),
        : 
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
    return result;
}

/// How long a percussive drum hit rings, in ticks (10 = 50 ms; crude decay).
const drum_burst_ticks: u16 = 10;

/// Noise period (R6, 0-31) for the shared noise generator; higher = lower pitch.
/// One value for all drums for now; per-hit pitch comes later.
const noise_period: u8 = 8;

/// Sentinel values stored in `notes[]` for percussive hits. Tone periods are
/// 12-bit (<= 0x0FFF), so 0xFFF0.. are unambiguous.
const drum_kick: u16 = 0xFFF0;
const drum_snare: u16 = 0xFFF1;
const drum_hat: u16 = 0xFFF2;

/// Current song rep (loop count of the master track, channel A). A file-scope
/// variable rather than an `App` field: the large `App` struct's layout is
/// fragile on the m68k backend, and a field-offset miscompute would corrupt
/// `music[]`.
var song_rep: u32 = 0;

/// One sequencer channel: its note buffer + playback state.
pub const Track = struct {
    notes: [max_notes]u16 = [_]u16{0} ** max_notes, // bits 0-11 = tone period (0 = rest); bits 12-14 = beats-1; >= 0xFFF0 = drum hit
    count: usize = 0,
    index: usize = 0,
    delay_ticks: u16 = 0, // duration of one beat, in 200 Hz ticks
    remaining: u16 = 0, // ticks until this track's next state change
    volume: u8 = 0, // 0-15
    looping: bool = false,
    active: bool = false,
    gate_on: bool = false, // in the silence gap before the next note
    from_rep: u8 = 0, // first rep this track plays (1-based); 0 = not scheduled
    to_rep: u8 = 0, // last rep (inclusive); 0 = until song end
};

/// One scheduled voice in a `playSong` arrangement.
pub const Part = struct {
    channel: Channel,
    notes: []const u8, // comptime pattern string
    bpm: u8,
    volume: u8,
    from_rep: u8, // first rep (1-based)
    to_rep: u8, // last rep inclusive; 0 = until song end
};

/// Natural-note semitone index (c=0, d=2, e=4, f=5, g=7, a=9, b=11).
fn semitone(c: u8) u8 {
    return switch (c) {
        'c' => 0,
        'd' => 2,
        'e' => 4,
        'f' => 5,
        'g' => 7,
        'a' => 9,
        'b' => 11,
        else => 0,
    };
}

/// Parse a comptime note string into a track's step buffer.
/// Tokens: [letter][`b` = flat][octave] = tone note; `.` = rest; `k`/`s`/`h` =
/// kick/snare/hat. A trailing `-` doubles the duration (d2- = half note, d2-- =
/// whole note). Commas/space are skipped. e.g. "e1 b0 d2 b0, k . s . h h"
fn parseNotes(comptime src: []const u8) Track {
    var out: Track = .{};
    var i: usize = 0;
    while (i < src.len and out.count < max_notes) {
        const c = src[i] | 0x20; // ASCII lower-case (comptime: no runtime cost)
        var encoded: u16 = 0;
        var is_step = false;
        if (c == '.') {
            encoded = 0; // rest
            is_step = true;
            i += 1;
        } else if (c >= 'a' and c <= 'g') {
            // [letter] ['b' = flat] [octave]
            var flat = false;
            var oct_i = i + 1;
            if (oct_i < src.len and src[oct_i] == 'b' and oct_i + 1 < src.len and src[oct_i + 1] >= '0' and src[oct_i + 1] <= '3') {
                flat = true;
                oct_i += 1;
            }
            if (oct_i < src.len and src[oct_i] >= '0' and src[oct_i] <= '3') {
                const oct: usize = src[oct_i] - '0';
                const st: usize = if (flat) (semitone(c) + 11) % 12 else semitone(c);
                encoded = noteTable[oct][st];
                is_step = true;
                i = oct_i + 1;
            } else {
                i += 1;
            }
        } else if (c == 'k' or c == 's' or c == 'h') {
            encoded = switch (c) {
                'k' => drum_kick,
                's' => drum_snare,
                'h' => drum_hat,
                else => 0,
            };
            is_step = true;
            i += 1;
        } else {
            i += 1;
        }
        if (!is_step) continue;

        // Trailing '-' doubles the duration: d2- = 2 beats, d2-- = 4 beats.
        var dashes: usize = 0;
        while (i + dashes < src.len and src[i + dashes] == '-' and dashes < 3) : (dashes += 1) {}
        i += dashes;
        if (dashes > 0 and encoded < drum_kick) {
            encoded |= @as(u16, @intCast(dashes)) << 12;
        }
        out.notes[out.count] = encoded;
        out.count += 1;
    }
    return out;
}

/// Total duration of the current step (beat count × one beat), in ticks.
fn stepTotalTicks(t: *const Track) u16 {
    const v = t.notes[t.index];
    if (v >= drum_kick) return t.delay_ticks; // drums are always one beat
    const dashes: u16 = (v >> 12) & 0x3;
    const total: u32 = @as(u32, t.delay_ticks) << @intCast(dashes);
    return @intCast(@min(total, 65535));
}

/// How long the current step's sound rings before the gate, in ticks.
fn stepOnTicks(t: *const Track) u16 {
    const v = t.notes[t.index];
    if (v >= drum_kick) return drum_burst_ticks;
    const total: u32 = stepTotalTicks(t);
    if (total > note_gate_ticks) return @intCast(total - note_gate_ticks);
    return 1;
}

/// Comptime scan: does a note string contain any drum token (k/s/h)?
fn hasDrumToken(comptime notes: []const u8) bool {
    var i: usize = 0;
    while (i < notes.len) : (i += 1) {
        const c = notes[i] | 0x20;
        if (c == 'k' or c == 's' or c == 'h') return true;
    }
    return false;
}

/// Comptime: derive the mixer byte (R7) for a song — a channel with drum tokens
/// gets noise routed to it; a channel with tones gets tone; unused stays muted.
fn songMixer(comptime parts: anytype) u8 {
    var tone: [3]u8 = .{ 1, 1, 1 };
    var noise: [3]u8 = .{ 1, 1, 1 };
    inline for (parts) |p| {
        const ci: usize = @intFromEnum(p.channel);
        const drums = hasDrumToken(p.notes);
        tone[ci] = if (drums) 1 else 0;
        noise[ci] = if (drums) 0 else 1;
    }
    return tone[0] | (tone[1] << 1) | (tone[2] << 2) | (noise[0] << 3) | (noise[1] << 4) | (noise[2] << 5) | 0x40 | 0x80;
}

/// XBIOS Giaccess (trap #14, opcode 28) — select a PSG register and write data.
/// Args are passed on the stack (XBIOS convention): push regno, then data,
/// then the opcode. The dispatcher only *reads* the opcode (its pop is on a
/// copy of the stack and never commits to usp), so the caller pops opcode +
/// args = 6 bytes after the trap.
fn giAccess(data: u16, reg: u16) void {
    asm volatile (
        \\move.w %[reg], -(%%sp)
        \\move.w %[data], -(%%sp)
        \\move.w #28, -(%%sp)
        \\trap #14
        \\lea 6(%%sp), %%sp
        :
        : [data] "d" (@as(u32, data)),
          [reg] "d" (@as(u32, reg)),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
}

/// Write a value to a YM2149 register via XBIOS Giaccess. The register number
/// carries a flag: bit 7 (GIACCESS_WRITE, 0x80) = write the data; without it
/// Giaccess only selects the register (read).
fn psgWrite(reg: u8, val: u8) void {
    giAccess(val, reg | 0x80);
}

/// Write a 12-bit tone period to a channel's period registers (R0/R1..R4/R5).
fn psgWritePeriod(channel: Channel, period: u16) void {
    const base: u8 = @intFromEnum(channel) * 2;
    psgWrite(base, @intCast(period & 0xFF));
    psgWrite(base + 1, @intCast((period >> 8) & 0x0F));
}

/// Write a channel's volume (R8/R9/R10). 0-15, 0 = silent.
fn psgWriteVolume(channel: Channel, volume: u8) void {
    psgWrite(8 + @intFromEnum(channel), volume & 0x0F);
}

/// Initialise the PSG: tone on for all three channels, noise off.
fn psgInit() void {
    psgWrite(7, 0xFA);
}

/// GEM text info (`TEDINFO`). `G_TEXT`, `G_BOXTEXT`, `G_FTEXT` and `G_FBOXTEXT`
/// objects point at this instead of a raw string — EmuTOS dereferences it as a
/// pointer-to-structure. `G_BUTTON` uses a plain string, not a TEDINFO.
pub const TedInfo = extern struct {
    ptext: ?[*]const u8, // ptr to text (must be first)
    ptmplt: ?[*]const u8 = null,
    pvalid: ?[*]const u8 = null,
    font: i16 = 3,
    junk1: i16 = 0,
    just: i16 = 0,
    color: i16 = 0x0100, // te_color bitfield: bits 8-11 = text colour (1 = black)
    junk2: i16 = 0,
    thickness: i16 = 1,
    txtlen: i16 = 0,
    tmplen: i16 = 0,

    /// Build a TEDINFO from a comptime string and a palette colour.
    pub fn from(comptime text: []const u8, comptime color: Color) TedInfo {
        return .{ .ptext = text.ptr, .color = textColor(color) };
    }
};

/// GEM bit-block (`BITBLK`) — a 1-bit image. `G_IMAGE` objects point at this.
pub const BitBlk = extern struct {
    pdata: ?[*]const u8, // ptr to packed bit data (row-major, MSB-first)
    wb: i16, // width in bytes
    hl: i16, // height in lines (pixels)
    x: i16, // source x offset (usually 0)
    y: i16, // source y offset (usually 0)
    color: i16, // foreground colour index

    /// Build a BITBLK from a packed bitmap, using `color` for the "1" bits.
    pub fn from(bmp: *const Bitmap, comptime color: Color) BitBlk {
        return .{
            .pdata = bmp.data.ptr,
            .wb = @intCast((bmp.w_px + 7) / 8),
            .hl = @intCast(bmp.h_px),
            .x = 0,
            .y = 0,
            .color = textColor(color),
        };
    }
};

/// A packed 1-bit bitmap: row-major, MSB-first within each byte.
pub const Bitmap = struct {
    data: []const u8,
    w_px: u16,
    h_px: u16,
};

/// Pack ASCII art into a 1-bit bitmap at comptime. `#` (or `1`) = set,
/// anything else = clear. All rows must be the same width.
pub fn bitmap(comptime rows: []const []const u8) Bitmap {
    @setEvalBranchQuota(400000);
    const h: u16 = @intCast(rows.len);
    const w: u16 = @intCast(rows[0].len);
    const wb: usize = (@as(usize, w) + 7) / 8;
    const data = blk: {
        var buf: [wb * rows.len]u8 = undefined;
        inline for (rows, 0..) |row, y| {
            inline for (0..wb) |bi| {
                var byte: u8 = 0;
                inline for (0..8) |bit| {
                    const px = bi * 8 + bit;
                    if (px < w and row[px] == '#') {
                        byte |= (@as(u8, 0x80) >> @intCast(bit));
                    }
                }
                buf[y * wb + bi] = byte;
            }
        }
        break :blk buf;
    };
    return .{ .data = data[0..], .w_px = w, .h_px = h };
}

/// A GEM object-tree node (24 bytes, layout per Atari GEM).
pub const Object = extern struct {
    next: i16 = -1, // next sibling, -1 = none
    head: i16 = -1, // first child, -1 = none
    tail: i16 = -1, // last child, -1 = none
    object_type: ObjectType,
    flags: ObjectFlag = .none,
    state: u16 = 0,
    spec: ?[*]const u8 = null, // text label for text/button objects
    x: i16 = 0,
    y: i16 = 0,
    w: i16 = 0,
    h: i16 = 0,

    /// A container box (typically the root of a subtree), at (0,0).
    pub fn box(w: i16, h: i16) Object {
        return .{ .object_type = .box, .w = w, .h = h };
    }

    /// A solid-filled box (typically a background), at (0,0).
    pub fn filledBox(w: i16, h: i16, color: Color) Object {
        const spec: [*]const u8 = @ptrFromInt(@as(usize, boxFill(color)));
        return .{ .object_type = .box, .spec = spec, .w = w, .h = h };
    }

    /// A text object (G_TEXT). Takes the text directly; a static, word-aligned
    /// `TedInfo` pointing at it is created at comptime, so application code
    /// never builds a string buffer or a TEDINFO by hand.
    pub fn text(comptime s: []const u8, x: i16, y: i16, w: i16, h: i16) Object {
        const ted = TedInfo{ .ptext = s.ptr };
        return .{ .object_type = .text, .spec = @ptrCast(&ted), .x = x, .y = y, .w = w, .h = h };
    }

    /// A text object (G_TEXT) whose TEDINFO is supplied in full (colour, font,
    /// justification, …). The TEDINFO must be a stable, word-aligned static —
    /// pass `&some_module_level_const`, not a temporary.
    pub fn textTed(ted: *const TedInfo, x: i16, y: i16, w: i16, h: i16) Object {
        return .{ .object_type = .text, .spec = @ptrCast(ted), .x = x, .y = y, .w = w, .h = h };
    }

    /// A 1-bit bitmap image (G_IMAGE). `blk` must be a stable, word-aligned
    /// static — pass `&some_module_level_const`, not a temporary.
    pub fn image(blk: *const BitBlk, x: i16, y: i16, w: i16, h: i16) Object {
        return .{ .object_type = .image, .spec = @ptrCast(blk), .x = x, .y = y, .w = w, .h = h };
    }

    /// A push button. `ob_spec` points straight at the NUL-terminated string.
    pub fn button(comptime s: []const u8, x: i16, y: i16, w: i16, h: i16, flags: ObjectFlag) Object {
        return .{ .object_type = .button, .flags = flags, .spec = s.ptr, .x = x, .y = y, .w = w, .h = h };
    }
};

/// Message types delivered through `evnt_multi`'s message buffer.
pub const MessageType = struct {
    pub const wm_redraw: i16 = 20;
    pub const wm_topped: i16 = 21;
    pub const wm_closed: i16 = 22;
    pub const wm_fulled: i16 = 23;
    pub const wm_arrowed: i16 = 24;
    pub const wm_sized: i16 = 27;
    pub const wm_moved: i16 = 28;
};

/// `evnt_multi` event mask bits.
pub const EventMask = struct {
    pub const keybd: u16 = 0x0001;
    pub const button: u16 = 0x0002;
    pub const m1: u16 = 0x0004;
    pub const m2: u16 = 0x0008;
    pub const mesag: u16 = 0x0010;
    pub const timer: u16 = 0x0020;
};

/// Result of one `evnt_multi` wait.
pub const Event = struct {
    ev: u16, // which event(s) fired (EventMask bits)
    mx: i16,
    my: i16,
    mb: i16, // button state
    ks: i16, // keyboard state
    kc: i16, // key code
    mc: i16, // mouse clicks
};

/// `graf_mouse` cursor shapes.
pub const GrafMouse = struct {
    pub const arrow: i16 = 0;
    pub const hand: i16 = 4;
};

/// The default (single) alert button in a `form_alert` dialog.
pub const AlertButton = enum(i16) {
    default_button = 1,
};

// ---------------------------------------------------------------------------
// AES: window management
// ---------------------------------------------------------------------------

noinline fn windCreate(kind: u16, x: i16, y: i16, w: i16, h: i16) i16 {
    const int_in = [_]i16{ @bitCast(kind), x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    return aesCall(.wind_create, &args);
}

noinline fn windOpen(id: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ id, x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_open, &args);
}

noinline fn windClose(id: i16) void {
    const int_in = [_]i16{id};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_close, &args);
}

noinline fn windDelete(id: i16) void {
    const int_in = [_]i16{id};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_delete, &args);
}

noinline fn windSetTitle(id: i16, title: [*:0]const u8) void {
    // wind_set passes pointer args in the int_in array (the 32-bit address
    // split across two words), not via addr_in.
    const p: u32 = @intFromPtr(title);
    const int_in = [_]i16{
        id,
        WindField.name,
        @intCast(p >> 16),
        @intCast(p & 0xffff),
        0,
        0,
    };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_set, &args);
}

noinline fn windSet(id: i16, field: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ id, field, x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_set, &args);
}

noinline fn windGet(id: i16, field: i16, out: *Rect) void {
    const int_in = [_]i16{ id, field };
    const args = AesArgs.ints(&int_in, 5);
    _ = aesCall(.wind_get, &args);
    out.x = aes_out[1];
    out.y = aes_out[2];
    out.w = aes_out[3];
    out.h = aes_out[4];
}

noinline fn windFind(x: i16, y: i16) i16 {
    const int_in = [_]i16{ x, y };
    const args = AesArgs.ints(&int_in, 1);
    return aesCall(.wind_find, &args);
}

noinline fn windUpdate(mode: i16) void {
    const int_in = [_]i16{mode};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_update, &args);
}

// ---------------------------------------------------------------------------
// AES: object trees
// ---------------------------------------------------------------------------

pub noinline fn objcDraw(tree: []Object, obj: i16, depth: i16, cx: i16, cy: i16, cw: i16, ch: i16) void {
    const int_in = [_]i16{ obj, depth, cx, cy, cw, ch };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.objc_draw, &args);
}

noinline fn objcFind(tree: []Object, obj: i16, depth: i16, mx: i16, my: i16) i16 {
    const int_in = [_]i16{ obj, depth, mx, my };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    return aesCall(.objc_find, &args);
}

// ---------------------------------------------------------------------------
// AES: events and cursor
// ---------------------------------------------------------------------------

/// Wait for a left-button event and/or a message, filling `message` (16 words)
/// and `ev`. `bstate` selects which button state ends the wait:
///   - 1 = button *pressed*  (used to detect a fresh click)
///   - 0 = button *released* (used to swallow the rest of a click)
///
/// The AES returns *immediately* when the requested state is already the
/// current one, so a fixed `bstate` would spin: `bstate=0` spins while the
/// button is up, `bstate=1` spins while it is held. Callers must therefore
/// wait for the press first, then the release.
noinline fn evntMulti(events: u16, bstate: i16, timer: u16, message: *[16]i16, ev: *Event) void {
    const int_in = [_]i16{
        @bitCast(events),
        1, // bclicks — a single click
        1, // bmask — left button only
        bstate,
        0, 0, 0, 0, 0, // m1 (unused)
        0, 0, 0, 0, 0, // m2 (unused)
        @intCast(timer), 0, // timer (lo, hi) — ms; 0 = wait forever
    };
    // evnt_multi always takes one addr_in (the 16-word message buffer), even
    // when MU_MESAG is not part of `events`; it is simply left untouched.
    const addr_in = [_]?[*]const u8{@ptrCast(message)};
    const args = AesArgs.from(&int_in, &addr_in, 7);
    _ = aesCall(.evnt_multi, &args);
    ev.ev = @bitCast(aes_out[0]);
    ev.mx = aes_out[1];
    ev.my = aes_out[2];
    ev.mb = aes_out[3];
    ev.ks = aes_out[4];
    ev.kc = aes_out[5];
    ev.mc = aes_out[6];
}

noinline fn grafMouse(mode: i16) void {
    const int_in = [_]i16{mode};
    const addr_in = [_]?[*]const u8{null};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.graf_mouse, &args);
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

/// A GEM window.
pub const Window = struct {
    id: i16,

    /// `wind_create` — create the window using the desktop work area as the
    /// maximum constraint. Fails if the AES returns no handle.
    pub fn create(kind: WindKind) !Window {
        var desktop: Rect = undefined;
        windGet(0, WindField.work_xywh, &desktop);
        const id = windCreate(@bitCast(kind), desktop.x, desktop.y, desktop.w, desktop.h);
        if (id <= 0) return error.WindCreateFailed;
        return .{ .id = id };
    }

    /// `wind_open` — display the window.
    pub fn open(self: *const Window, x: i16, y: i16, w: i16, h: i16) void {
        windOpen(self.id, x, y, w, h);
    }

    /// `wind_close` — remove the window from the screen.
    pub fn close(self: *const Window) void {
        windClose(self.id);
    }

    /// `wind_delete` — free the window.
    pub fn delete(self: *const Window) void {
        windDelete(self.id);
    }

    /// `wind_set` WF_NAME — set the title bar text.
    pub fn setTitle(self: *const Window, title: [*:0]const u8) void {
        windSetTitle(self.id, title);
    }

    /// `wind_set` WF_CURRXYWH — move/resize the window.
    pub fn moveTo(self: *const Window, x: i16, y: i16, w: i16, h: i16) void {
        windSet(self.id, WindField.curr_xywh, x, y, w, h);
    }

    /// Screen coordinates of the work-area origin (used to convert an
    /// `evnt_multi` screen coordinate into an object-tree coordinate).
    /// EmuTOS returns `work_xywh` in screen coordinates already, so no
    /// `curr_xywh` is added.
    pub fn workOrigin(self: *const Window) Point {
        var work: Rect = undefined;
        windGet(self.id, WindField.work_xywh, &work);
        return .{ .x = work.x, .y = work.y };
    }

    /// Full work-area rectangle in screen coordinates (EmuTOS returns
    /// `work_xywh` in screen coords). Used as the redraw clip after a resize.
    pub fn workRect(self: *const Window) Rect {
        var work: Rect = undefined;
        windGet(self.id, WindField.work_xywh, &work);
        return work;
    }
};

/// Draw the tree into the window on WM_REDRAW. EmuTOS draws the tree at its
/// root's `ob_x/ob_y` in *screen* coordinates (the objc_draw arguments are the
/// clip, not an origin), so the root is placed at the window's work-area
/// origin; its children stay window-relative.
fn redrawTree(window: *const Window, tree: []Object, xc: i16, yc: i16, wc: i16, hc: i16) void {
    const origin = window.workOrigin();
    tree[0].x = origin.x;
    tree[0].y = origin.y;
    windUpdate(WindUpdate.beg_update);
    objcDraw(tree, 0, 8, xc, yc, wc, hc);
    windUpdate(WindUpdate.end_update);
    // Restore the root so objc_find hit-tests in clean (0,0) tree coords.
    tree[0].x = 0;
    tree[0].y = 0;
}

// ---------------------------------------------------------------------------
// Application session
// ---------------------------------------------------------------------------

/// An AES application session, parameterised by static widget capacity.
///
/// `max_views` is how many windows may be open at once and `max_nodes` is how
/// many GEM objects any single window's tree may contain. Both are comptime so
/// the whole thing stays heap-free.
pub fn App(comptime max_views: usize, comptime max_nodes: usize) type {
    return struct {
        const Self = @This();

        /// Object-tree event kinds a widget can be bound to.
        pub const EventType = enum {
            click,
            select,
            edit,
        };

        /// A static event→handler binding for one widget. Add a variant here to
        /// extend the event set (and a matching `switch` arm in `run`).
        pub const Binding = union(EventType) {
            click: *const fn (*Self) bool,
            select: *const fn (*Self, bool) bool,
            edit: *const fn (*Self, i16) bool,
        };

        /// A tree node: a GEM object plus its static event bindings.
        pub const Node = struct {
            obj: Object,
            bindings: []const Binding = &[_]Binding{},

            pub fn box(w: i16, h: i16) Node {
                return .{ .obj = Object.box(w, h) };
            }

            pub fn filledBox(w: i16, h: i16, color: Color) Node {
                return .{ .obj = Object.filledBox(w, h, color) };
            }

            pub fn text(comptime s: []const u8, x: i16, y: i16, w: i16, h: i16) Node {
                return .{ .obj = Object.text(s, x, y, w, h) };
            }

            pub fn textTed(ted: *const TedInfo, x: i16, y: i16, w: i16, h: i16) Node {
                return .{ .obj = Object.textTed(ted, x, y, w, h) };
            }

            pub fn image(blk: *const BitBlk, x: i16, y: i16, w: i16, h: i16) Node {
                return .{ .obj = Object.image(blk, x, y, w, h) };
            }

            pub fn button(comptime s: []const u8, x: i16, y: i16, w: i16, h: i16, flags: ObjectFlag, bindings: []const Binding) Node {
                return .{ .obj = Object.button(s, x, y, w, h, flags), .bindings = bindings };
            }
        };

        /// Description of a window to create in `open`.
        pub const WindowSpec = struct {
            kind: WindKind,
            title: [*:0]const u8,
            x: i16,
            y: i16,
            w: i16,
            h: i16,
        };

        /// One open window: its AES handle, its own mutable tree copy, and its
        /// static bindings (indexed the same as the tree).
        const View = struct {
            window: Window,
            node_count: usize,
            tree: [max_nodes]Object,
            bindings: [max_nodes][]const Binding,

            fn treeSlice(self: *View) []Object {
                return self.tree[0..self.node_count];
            }
        };

        id: i16,
        views: [max_views]View,
        view_count: usize,
        music: [3]Track,

        /// `appl_init` — register the application with the AES.
        pub fn init() !Self {
            const args = AesArgs.none();
            const id = aesCall(.appl_init, &args);
            if (id == -1) return error.ApplInitFailed;
            return .{ .id = id, .views = undefined, .view_count = 0, .music = .{ .{}, .{}, .{} } };
        }

        /// Shared track arming: parse the notes, reset state, and sound the first
        /// note. Leaves the mixer untouched (the caller sets tone/noise routing).
        fn armCore(self: *Self, channel: Channel, comptime notes: []const u8, bpm: u8, volume: u8, from_rep: u8, to_rep: u8) void {
            const delay_ticks: u16 = @intCast(12000 / @as(u32, bpm));
            const t = &self.music[@intFromEnum(channel)];
            t.* = parseNotes(notes);
            t.index = 0;
            t.delay_ticks = delay_ticks;
            t.remaining = stepOnTicks(t);
            t.volume = volume;
            t.looping = true;
            t.active = true;
            t.gate_on = false;
            t.from_rep = from_rep;
            t.to_rep = to_rep;
            self.emitNote(channel, t); // sound the first note immediately
        }

        /// Start a one-shot note sequence on a channel. `bpm` is the tempo; one
        /// step = one beat (quarter note). Stops when the sequence ends.
        pub fn play(self: *Self, channel: Channel, comptime notes: []const u8, bpm: u8, volume: u8) void {
            psgInit(); // simple melodies are tone-only: restore the tone mixer
            self.armCore(channel, notes, bpm, volume, 0, 0);
            self.music[@intFromEnum(channel)].looping = false; // one-shot
        }

        /// Start a looping note sequence on a channel. Same as `play` but it
        /// restarts from the first note when it reaches the end.
        pub fn loop(self: *Self, channel: Channel, comptime notes: []const u8, bpm: u8, volume: u8) void {
            psgInit(); // simple melodies are tone-only: restore the tone mixer
            self.armCore(channel, notes, bpm, volume, 0, 0);
        }

        /// Arrange a full song: each part plays on its channel from `from_rep` to
        /// `to_rep`. The master clock is channel A — its loop wraps advance the
        /// rep counter. All parts share the same 16-step / 4-bar grid (one step =
        /// one beat). `parts` is a comptime array of `Part`.
        pub fn playSong(self: *Self, comptime parts: anytype) void {
            // Arm every part via the proven loop() path, then route the mixer
            // for tone/noise per channel. (stopMusic already ran in form_choice.)
            song_rep = 1;
            self.armAll(parts, 0);
            psgWrite(7, songMixer(parts));
            psgWrite(6, noise_period);
        }

        /// Comptime-recursive part arming: loop() per part (the proven path),
        /// then apply rep scheduling.
        fn armAll(self: *Self, comptime parts: anytype, comptime i: usize) void {
            if (i == parts.len) return;
            const p = parts[i];
            self.loop(p.channel, p.notes, p.bpm, p.volume);
            const t = &self.music[@intFromEnum(p.channel)];
            t.from_rep = p.from_rep;
            t.to_rep = p.to_rep;
            if (p.from_rep > 1) {
                // Not due yet — silence and mark dormant until its start rep.
                psgWriteVolume(p.channel, 0);
                t.active = false;
            }
            self.armAll(parts, i + 1);
        }

        /// Advance the rep counter after a master loop and (de)activate any
        /// scheduled tracks that are now due to start or stop.
        fn advanceSchedule(self: *Self) void {
            song_rep += 1;
            for (&self.music, 0..) |*t, ch| {
                if (t.from_rep == 0) continue;
                const chan: Channel = @enumFromInt(@as(u8, @intCast(ch)));
                if (!t.active and song_rep >= t.from_rep) {
                    t.active = true;
                    t.index = 0;
                    t.gate_on = false;
                    t.remaining = stepOnTicks(t);
                    self.emitNote(chan, t);
                } else if (t.active and t.to_rep != 0 and song_rep > t.to_rep) {
                    psgWriteVolume(chan, 0);
                    t.active = false;
                }
            }
        }

        /// Write the step at a track's current index to its channel: a tone note
        /// (period + volume) or a percussive drum hit (noise volume burst).
        fn emitNote(_: *Self, channel: Channel, t: *Track) void {
            const v = t.notes[t.index];
            if (v >= drum_kick) {
                // Drum hit: noise is already enabled on this channel (mixer set by
                // playSong) and R6 is shared; just raise the volume. stepMusic
                // drops it back to 0 after `stepOnTicks` for a crude percussive decay.
                psgWriteVolume(channel, t.volume);
            } else {
                const period = v & 0x0FFF;
                if (period == 0) {
                    psgWriteVolume(channel, 0);
                } else {
                    psgWritePeriod(channel, period);
                    psgWriteVolume(channel, t.volume);
                }
            }
        }

        /// True while any track is active (drives the run-loop poll).
        fn anyMusicActive(self: *Self) bool {
            for (&self.music) |*t| {
                if (t.active) return true;
            }
            return false;
        }

        /// Advance every active track by `elapsed` ms, stepping the ones due.
        /// Each step sounds for its own duration, then goes silent for the
        /// gate, so notes/drum hits don't bleed into each other.
        fn stepMusic(self: *Self, elapsed: u16) void {
            var master_wrapped = false;
            for (&self.music, 0..) |*t, ch| {
                if (!t.active) continue;
                if (t.remaining > elapsed) {
                    t.remaining -= elapsed;
                    continue;
                }
                const chan: Channel = @enumFromInt(@as(u8, @intCast(ch)));
                if (t.gate_on) {
                    // Gate finished — sound this step.
                    t.gate_on = false;
                    t.remaining = stepOnTicks(t);
                    self.emitNote(chan, t);
                } else {
                    // Step finished — silence and begin the gate.
                    psgWriteVolume(chan, 0);
                    const gate = stepTotalTicks(t) - stepOnTicks(t);
                    t.index += 1;
                    if (t.index >= t.count) {
                        if (t.looping) {
                            t.index = 0;
                            t.gate_on = true;
                            t.remaining = gate;
                            // The master (channel A) drives the song clock.
                            if (ch == 0 and t.from_rep != 0) master_wrapped = true;
                        } else {
                            psgWriteVolume(chan, 0);
                            t.active = false;
                        }
                    } else {
                        t.gate_on = true;
                        t.remaining = gate;
                    }
                }
            }
            if (master_wrapped) self.advanceSchedule();
        }

        /// `appl_exit` — release the application from the AES.
        pub fn exit(_: *Self) void {
            // Silence all PSG channels so the sound stops with the app (a
            // ringing square wave would otherwise keep sounding after quit).
            psgWriteVolume(.A, 0);
            psgWriteVolume(.B, 0);
            psgWriteVolume(.C, 0);
            const args = AesArgs.none();
            _ = aesCall(.appl_exit, &args);
        }

        /// Stop all tracks and silence every PSG channel.
        pub fn stopMusic(self: *Self) void {
            for (&self.music) |*t| {
                t.active = false;
                t.gate_on = false;
            }
            psgWriteVolume(.A, 0);
            psgWriteVolume(.B, 0);
            psgWriteVolume(.C, 0);
        }

        /// `form_alert` — show a modal alert dialog. Silences any playing music
        /// first (modal dialogs block the sequencer).
        pub fn form_alert(self: *Self, button: AlertButton, comptime text: []const u8) void {
            self.stopMusic();
            const msg: [*:0]const u8 = "[1][" ++ text ++ "][ OK ]";
            const int_in = [_]i16{@intFromEnum(button)};
            const addr_in = [_]?[*]const u8{@ptrCast(msg)};
            const args = AesArgs.from(&int_in, &addr_in, 1);
            _ = aesCall(.form_alert, &args);
        }

        /// `form_alert` with custom buttons — returns the 1-based index of the
        /// button pressed (e.g. 1 = first, 2 = second). Silences music first.
        pub fn form_choice(self: *Self, button: AlertButton, comptime text: []const u8, comptime buttons: []const u8) i16 {
            self.stopMusic();
            const msg: [*:0]const u8 = "[1][" ++ text ++ "][" ++ buttons ++ "]";
            const int_in = [_]i16{@intFromEnum(button)};
            const addr_in = [_]?[*]const u8{@ptrCast(msg)};
            const args = AesArgs.from(&int_in, &addr_in, 1);
            return aesCall(.form_alert, &args);
        }

        /// Create + open a window and register it (and its tree + bindings).
        pub fn open(self: *Self, spec: WindowSpec, comptime nodes: []const Node) !void {
            if (self.view_count >= max_views) return error.TooManyViews;
            if (nodes.len > max_nodes) return error.TooManyNodes;

            const built = buildTree(nodes);

            const win = try Window.create(spec.kind);
            win.setTitle(spec.title);
            win.open(spec.x, spec.y, spec.w, spec.h);

            const slot = self.view_count;
            const view = &self.views[slot];
            view.window = win;
            view.node_count = nodes.len;
            inline for (0..nodes.len) |i| {
                view.tree[i] = built.objects[i];
                view.bindings[i] = built.bindings[i];
            }
            self.view_count += 1;
        }

        /// Run the event loop until the last window is closed.
        pub fn run(self: *Self) void {
            var msg: [16]i16 = undefined;
            var ev: Event = undefined;

            // `appl_init` leaves the app in the busy (hourglass) state.
            grafMouse(GrafMouse.arrow);
            psgInit();

            var last_ticks: u32 = xbiosGetTime();
            while (true) {
                if (self.view_count == 0) return;

                // Wake every `poll_ms` while music plays, but measure the real
                // elapsed from the 200 Hz counter (5 ms granularity) so the AES
                // timer's jitter/coarseness never affects tempo.
                const playing = self.anyMusicActive();
                const poll: u16 = if (playing) poll_ms else 0;
                const events = if (playing)
                    EventMask.button | EventMask.mesag | EventMask.timer
                else
                    EventMask.button | EventMask.mesag;
                evntMulti(events, 1, poll, &msg, &ev);

                const now = xbiosGetTime();
                var ticks: u16 = @intCast(now -% last_ticks);
                last_ticks = now;
                if (ticks == 0) ticks = poll_ms / 5; // timer not advanced: use full poll

                if ((ev.ev & EventMask.mesag) != 0) self.handleMessage(&msg);
                if ((ev.ev & EventMask.button) != 0) self.handleClick(ev.mx, ev.my);
                if (playing) self.stepMusic(ticks);
            }
        }

        /// Build the linked GEM tree plus a parallel binding array from `nodes`.
        fn buildTree(comptime nodes: []const Node) struct {
            objects: [nodes.len]Object,
            bindings: [nodes.len][]const Binding,
        } {
            var objects: [nodes.len]Object = undefined;
            var bindings: [nodes.len][]const Binding = undefined;
            inline for (nodes, 0..) |node, i| {
                objects[i] = node.obj;
                bindings[i] = node.bindings;
            }
            if (nodes.len > 1) {
                objects[0].head = 1;
                objects[0].tail = @intCast(nodes.len - 1);
                inline for (1..nodes.len - 1) |i| objects[i].next = @intCast(i + 1);
                // GEM invariant: the last child's ob_next points at its parent.
                objects[nodes.len - 1].next = 0;
            }
            return .{ .objects = objects, .bindings = bindings };
        }

        fn findView(self: *Self, handle: i16, out: **View) bool {
            var i: usize = 0;
            while (i < self.view_count) : (i += 1) {
                if (self.views[i].window.id == handle) {
                    out.* = &self.views[i];
                    return true;
                }
            }
            return false;
        }

        fn closeView(self: *Self, handle: i16) void {
            var i: usize = 0;
            while (i < self.view_count) : (i += 1) {
                if (self.views[i].window.id != handle) continue;
                self.views[i].window.close();
                self.views[i].window.delete();
                self.view_count -= 1;
                if (i != self.view_count) {
                    self.views[i] = self.views[self.view_count];
                }
                return;
            }
        }

        fn handleMessage(self: *Self, msg: *const [16]i16) void {
            switch (msg[0]) {
                MessageType.wm_redraw => {
                    var v: *View = undefined;
                    if (!self.findView(msg[3], &v)) return;
                    redrawTree(&v.window, v.treeSlice(), msg[4], msg[5], msg[6], msg[7]);
                },
                MessageType.wm_moved => {
                    var v: *View = undefined;
                    if (!self.findView(msg[3], &v)) return;
                    v.window.moveTo(msg[4], msg[5], msg[6], msg[7]);
                },
                MessageType.wm_sized => {
                    var v: *View = undefined;
                    if (!self.findView(msg[3], &v)) return;
                    // TODO(tech-debt): never commits the resize — must call
                    // `v.window.moveTo(msg[4], msg[5], msg[6], msg[7])`
                    // (wind_set WF_CURRXYWH) BEFORE re-reading workRect(), else
                    // the AES rubber-band snaps back and the window keeps its
                    // old size.
                    const work = v.window.workRect();
                    v.tree[0].w = work.w;
                    v.tree[0].h = work.h;
                    redrawTree(&v.window, v.treeSlice(), work.x, work.y, work.w, work.h);
                },
                MessageType.wm_closed => self.closeView(msg[3]),
                else => {},
            }
        }

        fn handleClick(self: *Self, mx: i16, my: i16) void {
            const handle = windFind(mx, my);
            var v: *View = undefined;
            if (!self.findView(handle, &v)) return;

            // Swallow the button-up before dispatching so the next wait doesn't
            // spin and a modal dialog doesn't misread the release as its own.
            var release: Event = undefined;
            var msg: [16]i16 = undefined;
            evntMulti(EventMask.button, 0, 0, &msg, &release);

            const origin = v.window.workOrigin();
            const obj = objcFind(v.treeSlice(), 0, 8, mx - origin.x, my - origin.y);
            if (obj < 0) return;
            const idx: usize = @intCast(obj);
            if (idx >= v.node_count) return;

            const bindings = v.bindings[idx];
            for (bindings) |b| {
                switch (b) {
                    .click => |h| {
                        if (!h(self)) {
                            self.closeView(handle);
                            return;
                        }
                    },
                    else => {},
                }
            }

            // A click handler may have shown a modal dialog (form_alert), which
            // EmuTOS returns from on the button *press* — the button is still
            // down. Swallow that release so the run loop's next wait-for-press
            // doesn't re-fire on the same physical click (and stop the music).
            evntMulti(EventMask.button, 0, 0, &msg, &release);
        }
    };
}

// ---------------------------------------------------------------------------
// Runtime entry point — called from the user's `_start` shim.
// ---------------------------------------------------------------------------

/// Show a simple alert box without an `app` instance (used for error reporting).
pub fn alert(comptime text: []const u8) void {
    const msg: [*:0]const u8 = "[1][" ++ text ++ "][ OK ]";
    const int_in = [_]i16{1};
    const addr_in = [_]?[*]const u8{@ptrCast(msg)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.form_alert, &args);
}

/// Show a `[1][<name>][ OK ]` alert from a *runtime* string (e.g. an error
/// name). Builds the bytes with an incrementing many-pointer rather than a
/// slice, to avoid the m68k backend's indexed-store miscompile.
pub fn alertName(name: []const u8) void {
    var buf: [64]u8 = undefined;
    var p: [*]u8 = &buf;
    for ("[1]"[0..]) |c| {
        p[0] = c;
        p += 1;
    }
    for (name) |c| {
        p[0] = c;
        p += 1;
    }
    for ("][ OK ]"[0..]) |c| {
        p[0] = c;
        p += 1;
    }
    p[0] = 0;

    const int_in = [_]i16{1};
    const addr_in = [_]?[*]const u8{@ptrCast(&buf)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.form_alert, &args);
}

/// Call the root module's `main()`, report any error via an alert, then exit.
pub fn start() callconv(.c) noreturn {
    const root = @import("root");
    root.main() catch |err| alertName(@errorName(err));
    pterm0();
}

// ---------------------------------------------------------------------------
// Freestanding runtime stubs (needed because bundle_compiler_rt = false)
// ---------------------------------------------------------------------------

/// Re-exported by the user's root module as its panic handler.
pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(_: []const u8, _: ?usize) noreturn {
    abort();
}

export fn abort() noreturn {
    pterm0();
}

/// LLVM lowers struct zero-init to `memset`; compiler_rt's version uses
/// 68020+ instructions, so we provide our own 68000-safe one.
export fn memset(dest: [*]u8, c: i32, n: usize) [*]u8 {
    var i: usize = 0;
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    while (i < n) : (i += 1) dest[i] = byte;
    return dest;
}

/// LLVM lowers struct copies (e.g. returning `Rect`/`Point` by value) to a
/// `memcpy` call; provide our own 68000-safe one.
export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = src[i];
    return dest;
}

/// LLVM lowers potentially-overlapping struct moves (e.g. swap-removing a view)
/// to `memmove`; provide our own 68000-safe one.
export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        while (i < n) : (i += 1) dest[i] = src[i];
    } else {
        i = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}
