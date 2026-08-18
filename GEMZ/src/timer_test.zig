//! TIMER.TOS — diagnostic: cross-check the XBIOS Gettime counter against the
//! VBL clock (XBIOS Vsync). Samples Gettime, waits 200 VBLs, samples again,
//! and reports the tick delta: to the console via Cconws (visible on the host
//! with `hatari --conout 2`) and to C:\TIMER.TXT (host: ~/Atari/CDrive/TIMER.TXT).
//!
//! Expected: with a 200 Hz Gettime counter and a 50 Hz (PAL) VBL, delta =
//! 200 VBL × 4 ticks = 800 = 0x00000320. Mono (71 Hz) gives ~562 = 0x232.
//! A 66.67 Hz counter (the suspected 3x-slow bug) gives ~267 = 0x10B.

fn gettime() u32 {
    // `_hz_200` low word — XBIOS Gettime (opcode 23) returns the keyboard
    // RTC, not this counter, so read $4BA directly (word read: 68000-safe).
    var low: u16 = 0;
    asm volatile (
        \\move.w 0x4ba, %[low]
        : [low] "=m" (low),
        :
        : .{ .memory = true }
    );
    return @as(u32, low);
}

fn vsyncWait() void {
    asm volatile (
        \\move.w #37, -(%%sp)
        \\trap #14
        \\lea 2(%%sp), %%sp
        :
        :
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
}

fn pterm0() noreturn {
    asm volatile (
        \\move.w #0, -(%%sp)
        \\trap #1
    );
    unreachable;
}

/// GEMDOS Cconws (opcode 9) — print a null-terminated string to the console.
/// With `hatari --conout 2` the text lands on the host stderr.
fn conout(str: [*:0]const u8) void {
    asm volatile (
        \\move.l %[str], -(%%sp)
        \\move.w #0x09, -(%%sp)
        \\trap #1
        \\lea 6(%%sp), %%sp
        :
        : [str] "d" (@intFromPtr(str)),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
}

// GEMDOS bindings. Argument order matters: args are pushed right-to-left,
// i.e. the LAST C argument ends up on top of the stack at trap time.

fn fcreate(name: [*:0]const u8) i32 {
    var r: i32 = 0;
    asm volatile (
        \\move.w #0, -(%%sp)
        \\move.l %[name], -(%%sp)
        \\move.w #0x3c, -(%%sp)
        \\trap #1
        \\lea 8(%%sp), %%sp
        \\move.l %%d0, %[r]
        : [r] "=m" (r),
        : [name] "d" (@intFromPtr(name)),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
    return r;
}

fn fwrite(handle: i32, len: u32, buf: [*]const u8) i32 {
    var r: i32 = 0;
    asm volatile (
        \\move.l %[buf], -(%%sp)
        \\move.l %[len], -(%%sp)
        \\move.w %[handle], -(%%sp)
        \\move.w #0x40, -(%%sp)
        \\trap #1
        \\lea 12(%%sp), %%sp
        \\move.l %%d0, %[r]
        : [r] "=m" (r),
        : [handle] "d" (@as(u32, @bitCast(handle))),
          [len] "d" (len),
          [buf] "d" (@intFromPtr(buf)),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
    return r;
}

fn fclose(handle: i32) i32 {
    var r: i32 = 0;
    asm volatile (
        \\move.w %[handle], -(%%sp)
        \\move.w #0x3e, -(%%sp)
        \\trap #1
        \\lea 4(%%sp), %%sp
        \\move.l %%d0, %[r]
        : [r] "=m" (r),
        : [handle] "d" (@as(u32, @bitCast(handle))),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
    );
    return r;
}

export fn _start() callconv(.c) noreturn {
    main() catch {};
    pterm0();
}

pub fn main() !void {
    conout("TIMER: start\r\n");
    const t0 = gettime();
    var i: u16 = 0;
    while (i < 200) : (i += 1) vsyncWait();
    const t1 = gettime();
    const delta = t1 - t0;

    // 8 hex digits, MSB first, written with a many-pointer (never an indexed
    // byte store — the m68k backend drops the index register on those).
    var buf: [64]u8 = undefined;
    var p: [*]u8 = &buf;
    const hex = "0123456789ABCDEF";
    var sh: u5 = 28;
    while (true) {
        const nib: u5 = @intCast((delta >> sh) & 0xF);
        p[0] = hex[nib];
        p += 1;
        if (sh == 0) break;
        sh -= 4;
    }
    // " ticks/200vbl\r\n" suffix, one char at a time.
    const suffix = " ticks/200vbl\r\n";
    var s: usize = 0;
    while (s < suffix.len) : (s += 1) {
        p[0] = suffix[s];
        p += 1;
    }
    p[0] = 0;

    conout(@ptrCast(&buf));

    const h = fcreate("C:\\TIMER.TXT");
    if (h > 0) {
        const len: u32 = @intCast(@intFromPtr(p) - @intFromPtr(&buf));
        _ = fwrite(h, len, &buf);
        _ = fclose(h);
    }
    conout("TIMER: done\r\n");
}
