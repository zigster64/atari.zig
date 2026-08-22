//! GEMZ "Counter" — a minimal stateful app: a u16 counter with
//! increment / decrement / reset buttons and a live number display.

const gemz = @import("gemz");

// One window, a handful of objects.
const MyApp = gemz.App(1, 8);

// The counter state and its on-screen text buffer. These are module-level so
// the G_TEXT TEDINFO has a stable address and the click handlers can reach them.
var count: u16 = 0;

/// The on-screen text buffer, laid out as named bytes so each digit has a
/// stable address we can store to. The stores go through `storeByte` (inline
/// asm); a plain `buf.field = …` to a global lowers to an illegal PC-relative
/// MOVE destination on this m68k backend.
const CountText = extern struct {
    c0: u8,
    c1: u8,
    c2: u8,
    c3: u8,
    c4: u8,
    nul: u8,
    _pad0: u8,
    _pad1: u8,
};

var count_buf: CountText = .{ .c0 = '0', .c1 = '0', .c2 = '0', .c3 = '0', .c4 = '0', .nul = 0, ._pad0 = 0, ._pad1 = 0 };

// The TEDINFO for the number display.
const COUNT_TED = gemz.TedInfo{ .ptext = @ptrCast(&count_buf) };

/// Write the counter's value. A plain `count = v` is an immediate store to a
/// mutable global, which this m68k backend misencodes as an illegal
/// PC-relative destination (`0x31FC → 0x35FC`), so it goes through `storeWord`.
fn setCount(v: u16) void {
    gemz.storeWord(@intFromPtr(&count), v);
}

/// Write `v` as a right-aligned, space-padded, NUL-terminated decimal string.
/// Each byte goes through `storeByte` to a fixed field address — this exact
/// shape is verified good on the m68k backend (the fancier blk/pointer-copy
/// form miscompiled and displayed garbage).
noinline fn writeCount(v: u16) void {
    const d4: u8 = '0' + @as(u8, @intCast(v / 10000));
    const d3: u8 = '0' + @as(u8, @intCast((v / 1000) % 10));
    const d2: u8 = '0' + @as(u8, @intCast((v / 100) % 10));
    const d1: u8 = '0' + @as(u8, @intCast((v / 10) % 10));
    const d0: u8 = '0' + @as(u8, @intCast(v % 10));

    // Right-align: leading zeros become spaces.
    gemz.storeByte(@intFromPtr(&count_buf.c0), if (v < 10000) ' ' else d4);
    gemz.storeByte(@intFromPtr(&count_buf.c1), if (v < 1000) ' ' else d3);
    gemz.storeByte(@intFromPtr(&count_buf.c2), if (v < 100) ' ' else d2);
    gemz.storeByte(@intFromPtr(&count_buf.c3), if (v < 10) ' ' else d1);
    gemz.storeByte(@intFromPtr(&count_buf.c4), d0);
    gemz.storeByte(@intFromPtr(&count_buf.nul), 0);
}

fn updateCountBuf() void {
    writeCount(count);
}

fn increment(app: *MyApp) bool {
    setCount(count +% 1);
    updateCountBuf();
    app.redrawNode(1); // only the number text changed — avoid a full-tree flash
    return true;
}

fn decrement(app: *MyApp) bool {
    setCount(count -% 1);
    updateCountBuf();
    app.redrawNode(1);
    return true;
}

fn reset(app: *MyApp) bool {
    setCount(0);
    updateCountBuf();
    app.redrawNode(1);
    return true;
}

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    setCount(0);
    updateCountBuf();

    var app = try MyApp.init();
    defer app.exit();

    try app.open(.{
        .kind = .{ .name = true, .closer = true },
        .title = "Counter",
        .x = 60,
        .y = 40,
        .w = 200,
        .h = 160,
    }, &.{
        .box(200, 140),
        .textTed(&COUNT_TED, 8, 8, 184, 20),
        .button(" + Increment ", 8, 36, 184, 24, .selectable, &.{.{ .click = increment }}),
        .button(" - Decrement ", 8, 66, 184, 24, .selectable, &.{.{ .click = decrement }}),
        .button(" Reset ", 8, 96, 184, 24, .selectable, &.{.{ .click = reset }}),
    });

    app.run();
}
