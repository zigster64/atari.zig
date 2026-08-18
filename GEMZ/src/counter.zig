//! GEMZ "Counter" — a minimal stateful app: a u16 counter with
//! increment / decrement / reset buttons and a live number display.

const gemz = @import("gemz");

// One window, a handful of objects.
const MyApp = gemz.App(1, 8);

// The counter state and its on-screen text buffer. These are module-level so
// the G_TEXT TEDINFO has a stable address and the click handlers can reach them.
var count: u16 = 0;

/// The on-screen text buffer: five digits plus a NUL. It is a plain byte array;
/// the final write goes through `gemz.storeBytes` because a direct byte store
/// to this global lowers to an illegal PC-relative MOVE destination on this
/// m68k backend.
var count_buf: [6]u8 = .{ '0', '0', '0', '0', '0', 0 };

// The TEDINFO for the number display.
const COUNT_TED = gemz.TedInfo{ .ptext = @ptrCast(&count_buf) };

/// Write the counter's value. A plain `count = v` is an immediate store to a
/// mutable global, which this m68k backend misencodes as an illegal
/// PC-relative destination (`0x31FC → 0x35FC`), so it goes through `storeWord`.
fn setCount(v: u16) void {
    gemz.storeWord(@intFromPtr(&count), v);
}

/// Write `v` as a right-aligned, space-padded, NUL-terminated decimal string.
noinline fn writeCount(v: u16) void {
    const d4: u8 = '0' + @as(u8, @intCast(v / 10000));
    const d3: u8 = '0' + @as(u8, @intCast((v / 1000) % 10));
    const d2: u8 = '0' + @as(u8, @intCast((v / 100) % 10));
    const d1: u8 = '0' + @as(u8, @intCast((v / 10) % 10));
    const d0: u8 = '0' + @as(u8, @intCast(v % 10));

    // Assemble the six display bytes into a stack buffer with a `blk`
    // expression, then copy them into the stable global TEDINFO buffer in one
    // `storeBytes` call. Building the array uses a pointer walk (indexed
    // stack-array stores are also fragile on this backend); the final copy into
    // the global still has to go through inline asm because LLVM folds any
    // direct global store into an illegal PC-relative `move.b`.
    const digits = blk: {
        var buf: [6]u8 = undefined;
        var p: [*]u8 = &buf;
        p[0] = if (v < 10000) ' ' else d4;
        p += 1;
        p[0] = if (v < 1000) ' ' else d3;
        p += 1;
        p[0] = if (v < 100) ' ' else d2;
        p += 1;
        p[0] = if (v < 10) ' ' else d1;
        p += 1;
        p[0] = d0;
        p += 1;
        p[0] = 0;
        break :blk buf;
    };

    const src: [*]const u8 = &digits;
    gemz.storeBytes(@intFromPtr(&count_buf), src, 6);
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
