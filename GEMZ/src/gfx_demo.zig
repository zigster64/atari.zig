//! Shared demo logic for the GFX-COLOR / GFX-MONO test programs.
//!
//! A resolution's "phase" (`runPhase`) sweeps every colour of that mode,
//! holds a one-colour-per-row rainbow, animates the rainbow by rotating the
//! start colour, then walks a space invader across the field. The two apps
//! differ only in which resolutions they run:
//!
//!   GFX-COLOR.PRG — Low Res (16 colour) + Med Res (4 colour); needs a
//!                   COLOUR monitor (`--monitor rgb` / nMonitorType = 1).
//!   GFX-MONO.PRG  — Hi Res (monochrome); needs a MONO monitor
//!                   (`--monitor mono` / nMonitorType = 0).
//!
//! Rez 2 (mono) only works with a mono monitor (GLUE mono-detect, real
//! hardware too) — requesting it on a colour monitor makes the machine
//! reset in Hatari (M68K_NOTES #17). Hence the split: each program only
//! switches between resolutions its monitor can display.
//!
//! m68k note: there is deliberately NO unified "clear/fill at any
//! resolution" dispatch here — a multi-branch wrapper around the noinline
//! fills miscompiled (M68K_NOTES #16). Each call site branches on `rez` and
//! calls the resolution-specific fill directly.
//!
//! Double-buffering note: every frame does `draw; vsync; flip` — the
//! Vsetscreen base change lands at the VBL boundary. `draw; flip; vsync`
//! tears in Hatari (M68K_NOTES #18). The draws are slow in Hatari's UAE
//! core (~3-6 VBLs per frame), so the animation advances irregularly here;
//! on real hardware each frame draws in a fraction of one VBL.

const gemz = @import("gemz");
const screen = @import("screen");
const sprites = @import("space_sprites");

// Comptime sanity: the ASCII-art sprites pack to the expected 1-bit bitmaps.
const _ = sprites.PLAYER.w_px + sprites.INVADER_A.w_px + sprites.INVADER_B.w_px + sprites.BULLET.w_px;

/// Wait `frames` vertical blanks (~2 s at 60 Hz for 120).
pub fn sleepVsyncs(gfx: *screen.gfx.Gfx, frames: u16) void {
    var i: u16 = 0;
    while (i < frames) : (i += 1) gfx.vsync();
}

/// Debug-print a resolution capture/restore value (`what` labels the step).
/// Reads the same `Rez` the code uses, so the marker shows exactly what gets
/// restored. Comptime strings selected by a runtime branch (the safe shape).
pub fn dbgRez(comptime what: []const u8, rez: screen.Rez) void {
    if (rez == .low) {
        gemz.dbg(what ++ " rez 0 (low 320x200)");
    } else if (rez == .medium) {
        gemz.dbg(what ++ " rez 1 (med 640x200)");
    } else {
        gemz.dbg(what ++ " rez 2 (high 640x400)");
    }
}

/// Fill the whole back buffer with `color` for the current resolution.
pub fn clearBack(gfx: *screen.gfx.Gfx, rez: screen.Rez, color: u8) void {
    if (rez == .low) {
        gfx.clear(@enumFromInt(@as(u16, color)));
    } else if (rez == .medium) {
        screen.clearMedium(@intFromPtr(gfx.ptr()), color);
    } else {
        screen.clearHigh(@intFromPtr(gfx.ptr()), color);
    }
}

/// Fill one row of the back buffer with `color` for the current resolution.
fn drawRow(gfx: *screen.gfx.Gfx, rez: screen.Rez, y: u16, color: u8) void {
    if (rez == .low) {
        gfx.fillRow(y, @enumFromInt(@as(u16, color)));
    } else if (rez == .medium) {
        screen.fillMediumRow(@intFromPtr(gfx.ptr()), y, color);
    } else {
        screen.fillHighRow(@intFromPtr(gfx.ptr()), y, color);
    }
}

/// One-colour-per-row "rainbow" frame. `ncolors` is a power of two
/// (16/4/2) — mask, never modulo.
fn drawRows(gfx: *screen.gfx.Gfx, rez: screen.Rez, height: u16, ncolors: u16, start: u16) void {
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        const c: u8 = @intCast((y + start) & (ncolors - 1));
        drawRow(gfx, rez, y, c);
    }
}

/// Field colour to clear to in `rez`. Low has 16 palette entries (15 =
/// black); med only exposes entries 0-3 (white/red/green/yellow — no
/// black), so the med field is white; high (mono) black is 0.
fn fieldColor(rez: screen.Rez) u8 {
    if (rez == .low) return 15; // black
    if (rez == .medium) return 1; // red (no black in the 4-colour palette; white hid the console text)
    return 0; // high: black
}

/// Clear the whole back buffer to the field colour and show it. Used
/// between phases so the pause (and the phase's dbg marker) sits on a clean
/// screen.
pub fn showField(gfx: *screen.gfx.Gfx, rez: screen.Rez) void {
    clearBack(gfx, rez, fieldColor(rez));
    gfx.vsync();
    gfx.flip();
}

/// Animate a space invader across the screen: field, then walk the sprite
/// left -> right, alternating INVADER_A / INVADER_B every step. Each step
/// re-clears the WHOLE back buffer: the fillRect-based erase miscompiles in
/// the walk loop (M68K_NOTES #19 — draw and erase read the same PLANE_TEST
/// row, so the erase is a no-op and every position trails), so this is the
/// reliable shape for now. ~6 s per phase at UAE speed.
fn runInvader(gfx: *screen.gfx.Gfx, rez: screen.Rez) void {
    const w: u16 = sprites.INVADER_A.w_px;
    const h: u16 = sprites.INVADER_A.h_px;
    const width: u16 = if (rez == .low) screen.width else 640;
    const height = screen.rezHeight(rez);
    const y_pos: u16 = (height - h) / 2;
    const fg: u8 = 0; // white sprite on every field
    const bg = fieldColor(rez);

    // Field in both buffers.
    clearBack(gfx, rez, bg);
    gfx.vsync();
    gfx.flip();
    clearBack(gfx, rez, bg);

    const max_x: u16 = 60;
    var x: u16 = 0;
    while (x < max_x and x + w <= width) : (x += 1) {
        clearBack(gfx, rez, bg);
        if ((x & 1) == 0) {
            screen.drawSprite(sprites.INVADER_A, rez, @intFromPtr(gfx.ptr()), x, y_pos, 1, fg);
        } else {
            screen.drawSprite(sprites.INVADER_B, rez, @intFromPtr(gfx.ptr()), x, y_pos, 1, fg);
        }
        gfx.vsync();
        gfx.flip();
    }
}

/// The per-resolution phase: sweep every colour, hold a rainbow, animate it,
/// then walk a space invader across the field.
pub fn runPhase(gfx: *screen.gfx.Gfx, rez: screen.Rez) void {
    var ncolors: u16 = 16;
    if (rez == .medium) ncolors = 4;
    if (rez == .high) ncolors = 2;
    const height = screen.rezHeight(rez);

    // Sweep every colour of this mode, one frame each.
    var c: u16 = 0;
    while (c < ncolors) : (c += 1) {
        clearBack(gfx, rez, @intCast(c));
        gfx.vsync();
        gfx.flip();
    }

    // One-colour-per-row frame, held briefly.
    drawRows(gfx, rez, height, ncolors, 0);
    gfx.vsync();
    gfx.flip();
    sleepVsyncs(gfx, 60);

    // Animate the rainbow by rotating the start colour.
    var start: u16 = 0;
    while (start < 64) : (start += 1) {
        drawRows(gfx, rez, height, ncolors, start);
        gfx.vsync();
        gfx.flip();
    }

    // Field, then walk an invader across, alternating the two animation
    // frames (INVADER_A / INVADER_B).
    runInvader(gfx, rez);
}
