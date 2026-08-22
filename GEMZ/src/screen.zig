//! GEMZ fullscreen graphics — low-res (320x200, 16 colours) direct framebuffer
//! access. Talks to the video hardware through XBIOS (trap #14): `Vsetscreen`
//! switches resolution and screen base, `Vsync` waits for vertical blank, and
//! the framebuffer helpers write the ST's interleaved bitplane layout.
//!
//! The idiomatic entry point is `gfx.lowRes()` / the `gfx.Gfx` type (a
//! double-buffered 320x200 16-colour framebuffer). The raw `physbase` /
//! `setScreen` / `clearScreen` / ... functions below are the building blocks
//! and stay public for advanced use.
//!
//! Freestanding m68k, no std lib. The AES bookkeeping (appl_init, graf_mouse,
//! wind_update) comes from the `gemz` module.

const gemz = @import("gemz");

// ---------------------------------------------------------------------------
// Video constants — low resolution (320x200, 16 colours, 4 bitplanes)
// ---------------------------------------------------------------------------

pub const width: u16 = 320;
pub const height: u16 = 200;
pub const planes: u16 = 4;
pub const bytes_per_line: u16 = 160; // 4 planes × 20 words/plane
pub const screen_bytes: usize = 32000; // 200 lines × 160 bytes

// ---------------------------------------------------------------------------
// XBIOS video calls (trap #14)
// ---------------------------------------------------------------------------

/// `physbase` (XBIOS 2) — the physical screen base the shifter is displaying.
pub fn physbase() usize {
    var r: usize = 0;
    asm volatile (
        \\move.w #2, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        \\move.l %%d0, %[r]
        : [r] "=m" (r),
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
    return r;
}

/// `logbase` (XBIOS 3) — the logical screen base used by VDI/line-A.
pub fn logbase() usize {
    var r: usize = 0;
    asm volatile (
        \\move.w #3, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        \\move.l %%d0, %[r]
        : [r] "=m" (r),
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
    return r;
}

/// `getrez` (XBIOS 4) — current resolution: 0 = low, 1 = medium, 2 = high.
pub fn getrez() i16 {
    var r: i16 = 0;
    asm volatile (
        \\move.w #4, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        \\move.w %%d0, %[r]
        : [r] "=m" (r),
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
    return r;
}

/// Detect the connected monitor type from the MFP GPIP MONO_DETECT line:
/// `$FFFA01` **bit 7** — 1 = colour, 0 = mono (the same test TOS does at
/// boot). With a mono monitor only rez 2 is displayable (colour modes still
/// *run* but render as monochrome patterns); with a colour monitor rez 2 is
/// ignored by the hardware (Hatari instead resets the machine — M68K_NOTES
/// #17).
///
/// A user-mode read of `$FFFA01` bus-errors under Hatari's compatible-CPU
/// IO protection (verified: `Panic: Bus Error`), so the read runs in
/// supervisor mode via **XBIOS 38 `Supexec`** (verified working on EmuTOS;
/// requires TOS 2.06+ — on older TOS, fall back to `getrez() == 2` at
/// startup, which is the same information). The GEMDOS 0x20 `Super` stack
/// switch was also tried but its read comes back wrong under Hatari
/// (M68K_NOTES #20).
pub fn monitorIsMono() bool {
    const gpip = supexec(&gpipRead);
    return (gpip & 0x80) == 0;
}

/// The Supexec routine: reads `$FFFA01` (runs in supervisor mode).
fn gpipRead() u16 {
    var v: u16 = 0;
    asm volatile (
        \\move.l #0xFFFFFA01, %%a0
        \\move.b (%%a0), %%d0
        \\move.w %%d0, %[v]
        : [v] "=m" (v),
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .a0 = true });
    return v;
}

/// XBIOS 38 `Supexec`: call `routine` in supervisor mode, return its d0.
fn supexec(routine: *const fn () u16) u16 {
    var r: u16 = 0;
    asm volatile (
        \\move.l %[f], -(%%sp)
        \\move.w #38, -(%%sp)
        \\trap #14
        \\lea 6(%%sp), %%sp
        \\move.w %%d0, %[r]
        : [r] "=m" (r),
        : [f] "d" (@as(u32, @intCast(@intFromPtr(routine)))),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
    return r;
}

/// `vsetscreen` (XBIOS 5) — set logical/physical screen base and resolution.
/// `rez` -1 and `mode` -1 leave the resolution/mode unchanged (used for flips).
pub fn setScreen(log: usize, phys: usize, rez: i16, mode: i16) void {
    asm volatile (
        \\move.w %[mode], -(%%sp)
        \\move.w %[rez], -(%%sp)
        \\move.l %[phys], -(%%sp)
        \\move.l %[log], -(%%sp)
        \\move.w #5, -(%%sp)
        \\trap #14
        \\lea 14(%%sp), %%sp
        :
        : [mode] "d" (@as(u32, @intCast(@as(u16, @bitCast(mode))))),
          [rez] "d" (@as(u32, @intCast(@as(u16, @bitCast(rez))))),
          [phys] "d" (@as(u32, @intCast(phys))),
          [log] "d" (@as(u32, @intCast(log))),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
}

/// `vsync` (XBIOS 37) — wait for the next vertical blank.
pub fn vsync() void {
    asm volatile (
        \\move.w #37, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        :
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
}

/// `setpalette` (XBIOS 6) — install a 16-entry colour palette. Each entry is a
/// 9-bit ST colour word (0x0RGB: red bits 0-2, green 4-6, blue 8-10).
pub noinline fn setPalette(pal: [*]const u16) void {
    asm volatile (
        \\move.l %[pal], -(%%sp)
        \\move.w #6, -(%%sp)
        \\trap #14
        \\lea 6(%%sp), %%sp
        :
        : [pal] "d" (@as(u32, @intCast(@intFromPtr(pal)))),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
}

// ---------------------------------------------------------------------------
// Framebuffer helpers (raw; used by `gfx` and by advanced callers)
// ---------------------------------------------------------------------------

/// Comptime lookup: for each colour, the two 32-bit words to write for one
/// 16-pixel group. A group is plane0..plane3 words (8 bytes); each plane word
/// is 0xFFFF when the colour's plane bit is set, else 0x0000, packed as two
/// longs (plane0|plane1 and plane2|plane3). Built on the host at comptime —
/// the m68k backend miscompiles the runtime select `if (color & bit) 0xFF
/// else 0x00` (inverted `seq`/`negb`, M68K_NOTES #12), and indexed byte
/// accesses are pathologically slow (#13). Writing 32-bit groups instead of
/// bytes makes a full-screen fill ~0.05-0.1 s instead of ~2 s.
const FILL_LONGS = blk: {
    var t: [16][2]u32 = undefined;
    for (0..16) |c| {
        const w0: u32 = if (c & 1 != 0) 0xFFFF else 0;
        const w1: u32 = if (c & 2 != 0) 0xFFFF else 0;
        const w2: u32 = if (c & 4 != 0) 0xFFFF else 0;
        const w3: u32 = if (c & 8 != 0) 0xFFFF else 0;
        t[c][0] = (w0 << 16) | w1;
        t[c][1] = (w2 << 16) | w3;
    }
    break :blk t;
};

/// Fill one 16-pixel group (8 bytes) with `color`. `base` is the group
/// address (must be 4-aligned).
inline fn fillGroup(base: usize, color: u8) void {
    gemz.storeLong(base, FILL_LONGS[color & 0xF][0]);
    gemz.storeLong(base + 4, FILL_LONGS[color & 0xF][1]);
}

/// Fill the whole low-res screen with one byte value. `value` is a raw plane
/// byte, so white = 0xFF and black = 0x00 (other solid colours need the plane
/// pattern written explicitly — see `clearScreen`). Writes via `gemz.storeByte`
/// (plain `(a0)` store): the compiler otherwise strength-reduces a pointer walk
/// into an indexed byte store that is both the documented risky shape and
/// pathologically slow in Hatari's UAE CPU core.
pub noinline fn fillScreen(base: usize, value: u8) void {
    var i: usize = 0;
    while (i < screen_bytes) : (i += 1) {
        gemz.storeByte(base + i, value);
    }
}

/// Fill the whole low-res screen with one solid colour (raw 4-bit hardware
/// index, 0-15). Writes 32-bit group words (8 bytes per 16-pixel group) via
/// `gemz.storeLong` — much faster than the byte loop, and avoids both the
/// inverted-select and indexed-access miscompiles (M68K_NOTES #12/#13).
pub noinline fn clearScreen(base: usize, color: u8) void {
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        fillGroup(base + i * 8, color);
    }
}

/// Fill one 320-pixel row with one solid colour (20 groups, 160 bytes).
pub noinline fn fillRow(base: usize, y: u16, color: u8) void {
    const row = base + @as(usize, y) * bytes_per_line;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        fillGroup(row + i * 8, color);
    }
}

// ---------------------------------------------------------------------------
// Other resolutions (medium 640x200 4-colour, high 640x400 monochrome)
// ---------------------------------------------------------------------------

/// ST screen resolution (the `rez` value passed to Vsetscreen).
pub const Rez = enum(u8) { low = 0, medium = 1, high = 2 };

/// Scanline count for a resolution.
pub fn rezHeight(rez: Rez) u16 {
    if (rez == .high) return 400;
    return 200;
}

/// Comptime medium-res group longs: 16 pixels = 2 plane words (4 bytes);
/// colour 0-3 -> plane0 = bit0, plane1 = bit1.
const FILL_MED_LONGS = blk: {
    var t: [4]u32 = undefined;
    for (0..4) |c| {
        const w0: u32 = if (c & 1 != 0) 0xFFFF else 0;
        const w1: u32 = if (c & 2 != 0) 0xFFFF else 0;
        t[c] = (w0 << 16) | w1;
    }
    break :blk t;
};

/// Comptime high-res long: mono, colour 0 = black, 1 = white.
const FILL_HIGH_LONGS = blk: {
    var t: [2]u32 = undefined;
    for (0..2) |c| {
        t[c] = if (c & 1 != 0) 0xFFFFFFFF else 0;
    }
    break :blk t;
};

/// Fill the whole medium-res screen (8000 groups of 4 bytes).
pub noinline fn clearMedium(base: usize, color: u8) void {
    const l = FILL_MED_LONGS[color & 3];
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        gemz.storeLong(base + i * 4, l);
    }
}

/// Fill the whole high-res screen (8000 longs).
pub noinline fn clearHigh(base: usize, color: u8) void {
    const l = FILL_HIGH_LONGS[color & 1];
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        gemz.storeLong(base + i * 4, l);
    }
}

/// Fill one medium-res row (640 px = 40 groups, 160 bytes).
pub noinline fn fillMediumRow(base: usize, y: u16, color: u8) void {
    const row = base + @as(usize, y) * 160;
    const l = FILL_MED_LONGS[color & 3];
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        gemz.storeLong(row + i * 4, l);
    }
}

/// Fill one high-res row (640 px = 80 bytes = 10 longs).
pub noinline fn fillHighRow(base: usize, y: u16, color: u8) void {
    const row = base + @as(usize, y) * 80;
    const l = FILL_HIGH_LONGS[color & 1];
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        gemz.storeLong(row + i * 8, l);
    }
}

/// NOTE: there is deliberately NO unified "fill at any resolution" dispatch
/// here — a multi-branch wrapper around these noinline fills miscompiled on
/// the m68k backend (each branch passed registers in a different ABI than
/// the callee expected, writing to garbage addresses; verified). Callers
/// branch at the call site and call the resolution-specific fill directly.

/// Plot one pixel in low-res mode. `color` is 0-15. Uses read-modify-write on
/// the appropriate interleaved plane word (MSB-first, bit 15 = leftmost).
/// Comptime mask lookup for the bit position (0 = MSB) — a runtime shift
/// `0x80 >> bit` makes the m68k backend drop the whole call (verified), the
/// FILL_LONGS-style table does not.
const BIT_MASK = [8]u8{ 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 };

/// Plane bit for the colour test (plane 0 = LSB of the colour index).
const PLANE_BIT = [4]u8{ 1, 2, 4, 8 };

/// Per-colour per-plane write mask: 0xFF when colour `c` uses plane `p`,
/// else 0. Lets putPixel OR the plane bit without any branch/continue —
/// a conditional call inside a loop makes the m68k backend drop the whole
/// function (verified: function compiles to a bare `rts`).
const PLANE_TEST = blk: {
    var t: [64]u8 = undefined;
    for (0..16) |c| {
        for (0..4) |p| {
            t[c * 4 + p] = if ((c & (@as(usize, 1) << @intCast(p))) != 0) 0xFF else 0;
        }
    }
    break :blk t;
};

/// Mask-and-replace one framebuffer byte: `(cur & ~inv) | col`. The whole
/// read-modify-write happens in asm — a Zig read-then-store through
/// `@ptrFromInt` is eliminated by the m68k backend (verified: the whole
/// `putPixel` compiled to a missing call). `inv` clears the pixel's bit,
/// `col` re-sets it when the colour uses this plane.
inline fn writePlane(addr: usize, inv: u8, col: u8) void {
    asm volatile (
        \\move.l %[addr], %%a0
        \\move.b (%%a0), %%d1
        \\and.b %[inv], %%d1
        \\or.b %[col], %%d1
        \\move.b %%d1, (%%a0)
        :
        : [addr] "d" (addr),
          [inv] "d" (inv),
          [col] "d" (col),
        : .{ .memory = true, .a0 = true, .d1 = true });
}

/// Plot one pixel in low-res mode. `color` is 0-15. Read-modify-write on
/// the interleaved plane word (MSB-first, bit 15 = leftmost).
///
/// m68k landmines worked around here (all verified in the PRG dump):
/// - a Zig read-then-store through `@ptrFromInt` is eliminated entirely;
///   the read-modify-write must happen inside the asm,
/// - ANY conditional call (`if`/`continue`) inside the plane loop drops the
///   whole function (compiles to a bare `rts`), so the plane mask is
///   computed arithmetically from comptime tables instead of a branch,
/// - the plane mask comes from comptime tables (`BIT_MASK`,
///   `PLANE_TEST`) — indexed reads are fine; the x-dependent byte offset is
///   computed arithmetically (a big u16 table's address was emitted 32
///   entries too high),
/// - the write is a mask-and-replace, not a plain OR: on a black field
///   (colour 15 = all plane bits SET) a white sprite (colour 0 = no plane
///   bits) must CLEAR bits — an OR-only pixel can never draw light on dark.
pub noinline fn putPixel(p: [*]u8, x: u16, y: u16, color: u32) void {
    // `p` is a real POINTER parameter — the m68k backend narrows a `usize`
    // base + small offsets to 16 bits (`andl #65535`); pointer arithmetic
    // cannot be narrowed.
    //
    // `color` is u32 on purpose (with u8 the backend reused the y*160
    // register for the PLANE_TEST colour offset, so draw and erase read the
    // same garbage row and the erase became a no-op — the walk's trail).
    const x_mask: u8 = BIT_MASK[x & 7];
    const x_inv: u8 = ~x_mask;
    const xw: u16 = x >> 4;
    const xb: u16 = x & 15;
    const low_byte: u16 = if (xb >= 8) 1 else 0;
    var q: [*]u8 = p + @as(usize, y) * bytes_per_line + @as(usize, xw) * 8 + @as(usize, low_byte);
    var plane: u8 = 0;
    while (plane < 4) : (plane += 1) {
        writePlane(@intFromPtr(q), x_inv, PLANE_TEST[color * 4 + @as(usize, plane)] & x_mask);
        q += 2;
    }
}

/// Plot one pixel in medium-res mode (2 planes, 640x200). `color` is 0-3.
/// Same shape as `putPixel` but the 16-pixel group is 4 bytes (two plane
/// words), so the group stride is `xw * 4` and only 2 planes are written.
pub noinline fn putPixelMed(p: [*]u8, x: u16, y: u16, color: u32) void {
    const x_mask: u8 = BIT_MASK[x & 7];
    const x_inv: u8 = ~x_mask;
    const xw: u16 = x >> 4;
    const xb: u16 = x & 15;
    const low_byte: u16 = if (xb >= 8) 1 else 0;
    var q: [*]u8 = p + @as(usize, y) * bytes_per_line + @as(usize, xw) * 4 + @as(usize, low_byte);
    var plane: u8 = 0;
    while (plane < 2) : (plane += 1) {
        writePlane(@intFromPtr(q), x_inv, PLANE_TEST[color * 4 + @as(usize, plane)] & x_mask);
        q += 2;
    }
}

/// Plot one pixel in high-res mode (1 plane, 640x400 mono). `color` is 0-1.
/// One plane: the byte is `y * 80 + (x >> 3)`, bit `x & 7`.
pub noinline fn putPixelHigh(p: [*]u8, x: u16, y: u16, color: u32) void {
    const x_mask: u8 = BIT_MASK[x & 7];
    const x_inv: u8 = ~x_mask;
    const q: [*]u8 = p + @as(usize, y) * 80 + @as(usize, x >> 3);
    writePlane(@intFromPtr(q), x_inv, PLANE_TEST[color * 4] & x_mask);
}

/// Fill a solid-colour rectangle. `x0`,`y0` is the top-left, `w`,`h` the size
/// in pixels, `color` 0-15. Implemented as a plain pixel loop so the m68k
/// backend does not have to juggle the mask/shift locals that previously made
/// `fillRect` miscompile (stack corruption on return).
pub noinline fn fillRect(base: usize, x0: u16, y0: u16, w: u16, h: u16, color: u8) void {
    if (w == 0 or h == 0) return;
    var y: u16 = y0;
    while (y < y0 + h) : (y += 1) {
        var x: u16 = x0;
        while (x < x0 + w) : (x += 1) {
            putPixel(@ptrFromInt(base), x, y, color);
        }
    }
}

/// Draw a 1-bit sprite into the framebuffer at `(x, y)`. Set bits paint
/// `color`, clear bits are transparent. `scale` draws each set pixel as a
/// `scale x scale` block (e.g. 2 = twice the width and height), so the
/// ascii-art bitmaps stay small and the on-screen size is a per-call knob.
/// `bmp` is a **comptime** parameter: passing a runtime `*const Bitmap` made
/// the m68k backend emit the comptime const as all zeros and compile this
/// function to an empty stub (verified in the PRG dump — `jsr` to a bare
/// `rts`, sprite data missing). With the bitmap folded in, the packed bytes
/// become immediates (the `FILL_LONGS` pattern).
pub noinline fn drawSprite(comptime bmp: gemz.Bitmap, rez: Rez, base: usize, x: u16, y: u16, scale: u8, color: u8) void {
    const wb: u16 = (bmp.w_px + 7) >> 3; // bytes per row
    const sc: u16 = scale;
    var sy: u16 = 0;
    while (sy < bmp.h_px) : (sy += 1) {
        var bx: u16 = 0;
        while (bx < wb) : (bx += 1) {
            const byte: u8 = bmp.data[@as(usize, sy) * @as(usize, wb) + @as(usize, bx)];
            if (byte == 0) continue;
            var bit: u16 = 0;
            while (bit < 8) : (bit += 1) {
                const px: u16 = bx * 8 + bit;
                if (px >= bmp.w_px) break;
                if ((byte & (@as(u8, 0x80) >> @intCast(bit))) != 0) {
                    // Scale: paint a `scale` x `scale` block per source pixel.
                    const x0: u16 = x + px * sc;
                    const y0: u16 = y + sy * sc;
                    var dy: u16 = 0;
                    while (dy < sc) : (dy += 1) {
                        var dx: u16 = 0;
                        while (dx < sc) : (dx += 1) {
                            if (rez == .low) {
                                putPixel(@ptrFromInt(base), x0 + dx, y0 + dy, color);
                            } else if (rez == .medium) {
                                putPixelMed(@ptrFromInt(base), x0 + dx, y0 + dy, color);
                            } else {
                                putPixelHigh(@ptrFromInt(base), x0 + dx, y0 + dy, color);
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// gfx — idiomatic fullscreen graphics API (double-buffered)
// ---------------------------------------------------------------------------


/// The two framebuffers, over-allocated and 256-byte-aligned at runtime (the
/// ST Shifter requires a 256-byte-aligned screen base; this bare linker only
/// guarantees 4-byte alignment).
///
/// Only `gfx_buf_a` is ever *referenced* — `lowRes()` derives the second
/// buffer's base by adding `screen_bytes + 256`. A PC-relative `lea` to
/// `gfx_buf_b` would cross the 32 KB signed-displacement boundary (the .bss
/// is huge), and toslink's displacement then lands ~64 KB before the buffer
/// (verified: the fill wrote over .text, "Panic: Line F").
/// Both framebuffers in ONE array (2 x 32 KB). Only the array head is ever
/// referenced: `lowRes()` derives both aligned bases by addition, because a
/// PC-relative reference to the second buffer would cross the 32 KB toslink
/// displacement boundary (M68K_NOTES failure mode 11) and a second
/// unreferenced array is dropped by the compiler (the derived base would then
/// point past the app's allocation).
var gfx_buf: [2 * (screen_bytes + 256)]u8 = [_]u8{0} ** (2 * (screen_bytes + 256));

/// Private alias of the raw XBIOS `vsync`, so the `Gfx.vsync` method can call
/// it without shadowing ambiguity.
const xbios_vsync = vsync;

/// Private alias of the file-scope `fillRow`, so the `Gfx.fillRow` method can
/// call it without shadowing ambiguity.
const screen_fill_row = fillRow;

/// Low-res fullscreen graphics.
pub const gfx = struct {
    /// A double-buffered 320x200 16-colour framebuffer plus saved desktop
    /// state, created by `gfx.lowRes()`.
    ///
    /// Draw into `back` (via `ptr()`/`clear()`/...), then `flip()` to show it
    /// and start drawing into the other buffer. `flip()` swaps `front`/`back`
    /// and re-points the Shifter at the new `front` via `Vsetscreen`.
    pub const Gfx = struct {
        buf_a: usize, // aligned base of buffer A
        buf_b: usize, // aligned base of buffer B
        front: usize, // currently displayed
        back: usize, // currently drawn-to
        old_phys: usize,
        old_log: usize,
        old_rez: i16,

        /// Raw framebuffer pointer into the back buffer. Advance with `p += 1`
        /// (never `p[i]` on a runtime index — the m68k backend can drop it).
        pub inline fn ptr(self: *const Gfx) [*]u8 {
            return @ptrFromInt(self.back);
        }

        /// Fill the whole back buffer with one solid colour (`gemz.Color`).
        pub fn clear(self: *const Gfx, color: gemz.Color) void {
            const c: u8 = @truncate(@as(u16, @intFromEnum(color)));
            clearScreen(self.back, c);
        }

        /// Fill one row (320x1) of the back buffer with a solid colour.
        pub fn fillRow(self: *const Gfx, y: u16, color: gemz.Color) void {
            const c: u8 = @truncate(@as(u16, @intFromEnum(color)));
            screen_fill_row(self.back, y, c);
        }

        /// Switch the displayed resolution (keeps the front buffer). After
        /// this, draw with the resolution-specific fills (`clearMedium` /
        /// `fillMediumRow` / `clearHigh` / `fillHighRow`) on `ptr()`.
        pub fn setRez(self: *const Gfx, rez: Rez) void {
            setScreen(self.front, self.front, @as(i16, @intFromEnum(rez)), -1);
        }


        /// Wait for the next vertical blank.
        pub fn vsync(self: *const Gfx) void {
            _ = self;
            xbios_vsync();
        }

        /// Show the back buffer: swap front/back and re-point the Shifter.
        /// Call **right after** a `vsync()` — the base change must land at a
        /// frame boundary. `flip(); vsync();` tears in Hatari (the Shifter
        /// picks up a mid-scanline base change, showing two frames in one
        /// scan; verified — see M68K_NOTES #18). `noinline` keeps the swap
        /// as a real field exchange — inlined, the backend folds the
        /// front/back swap away and the two buffers never alternate
        /// (verified in the PRG dump).
        pub noinline fn flip(self: *Gfx) void {
            const tmp = self.front;
            self.front = self.back;
            self.back = tmp;
            setScreen(self.front, self.front, -1, -1);
        }

        /// Restore the desktop screen base/resolution, resume window updates,
        /// and show the mouse cursor again.
        pub fn restore(self: *const Gfx) void {
            setScreen(self.old_log, self.old_phys, self.old_rez, -1);
            gemz.windUpdate(gemz.WindUpdate.end_update);
            gemz.grafMouse(gemz.GrafMouse.on);
        }
    };

    /// Enter 320x200 16-colour fullscreen mode:
    /// - saves the desktop screen base/resolution,
    /// - registers with the AES, hides the mouse, and suspends window
    ///   updates (`wind_update BEG_UPDATE`) so the desktop can't redraw
    ///   into the new screen base,
    /// - switches to low resolution (`mode = -1` leaves the video mode alone),
    /// - installs the default 16-colour palette (in `gemz.Color` order).
    pub fn lowRes() Gfx {
        // Align buffer A; derive buffer B from A by addition so no PC-relative
        // reference crosses the 32 KB displacement boundary (see the buffer
        // comment above). `screen_bytes + 256` is 256-aligned, so B lands on
        // the exact aligned base of the second half of the array.
        const a = (@intFromPtr(&gfx_buf) + 255) & ~@as(usize, 255);
        const b = a + screen_bytes + 256;
        const old_phys = physbase();
        const old_log = logbase();
        const old_rez = getrez();
        _ = gemz.applInit();
        gemz.grafMouse(gemz.GrafMouse.off);
        // The AES/desktop keeps drawing into whatever screen it thinks is
        // current; suspend its updates so it can't overwrite our buffer.
        gemz.windUpdate(gemz.WindUpdate.beg_update);
        setScreen(a, a, 0, -1);

        // Build the struct FIRST, then have getPalette write straight into
        // the old_palette field. A separate `var old_palette` local + return
        // copy miscompiles: the compiler passed &old_palette as the struct's
        // base (offset 0), so the 32-byte save clobbered buf_a..old_rez.
        // NOTE: no palette install/restore — `gemz.Color` matches the
        // desktop palette, so the game's colours work with the desktop's
        // palette and there is nothing to restore on exit (the ST's palette
        // registers are write-only and XBIOS has no Getpalette).
        return .{
            .buf_a = a,
            .buf_b = b,
            .front = a, // A is displayed first
            .back = b, // draw into B first
            .old_phys = old_phys,
            .old_log = old_log,
            .old_rez = old_rez,
        };
    }
};
