//! GEMZ "Counter" — a minimal stateful app: a u16 counter with
//! increment / decrement / reset buttons and a live number display.

const gemz = @import("gemz");

// One window, a handful of objects.
const MyApp = gemz.App(1, 8);

// The counter state and its on-screen text buffer. These are module-level so
// the G_TEXT TEDINFO has a stable address and the click handlers can reach them.
var count: u16 = 0;
var count_buf: [8]u8 = [_]u8{0} ** 8;

// The TEDINFO for the number display. `ptext` points at the mutable buffer;
// the object tree stores a pointer to this TEDINFO, not a copy.
const COUNT_TED = gemz.TedInfo{ .ptext = &count_buf };

/// Write `v` as a fixed-width (5-digit, leading-zero) NUL-terminated decimal
/// string into `buf`. `noinline` + an opaque pointer parameter: direct
/// global-array byte stores (`count_buf[i] = …`) are miscompiled on this m68k
/// backend into PC-relative `move.b Dn,(d16,PC)` — not a legal MOVE
/// destination. Writing through an opaque pointer keeps the stores
/// register-indirect (`(d16,An)`), which is the valid form.
noinline fn writeCount(buf: [*]u8, v: u16) void {
    buf[0] = '0' + @as(u8, @intCast(v / 10000));
    buf[1] = '0' + @as(u8, @intCast((v / 1000) % 10));
    buf[2] = '0' + @as(u8, @intCast((v / 100) % 10));
    buf[3] = '0' + @as(u8, @intCast((v / 10) % 10));
    buf[4] = '0' + @as(u8, @intCast(v % 10));
    buf[5] = 0;
}

fn updateCountBuf() void {
    writeCount(&count_buf, count);
}

fn increment(app: *MyApp) bool {
    count +%= 1;
    updateCountBuf();
    app.redraw();
    return true;
}

fn decrement(app: *MyApp) bool {
    count -%= 1;
    updateCountBuf();
    app.redraw();
    return true;
}

fn reset(app: *MyApp) bool {
    count = 0;
    updateCountBuf();
    app.redraw();
    return true;
}

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    count = 0;
    updateCountBuf();

    var app = try MyApp.init();
    defer app.exit();

    try app.open(.{
        .kind = .{ .name = true, .closer = true },
        .title = "Counter",
        .x = 60,
        .y = 40,
        .w = 200,
        .h = 140,
    }, &.{
        .box(200, 140),
        .textTed(&COUNT_TED, 8, 8, 184, 20),
        .button(" + Increment ", 8, 36, 184, 24, .selectable, &.{.{ .click = increment }}),
        .button(" - Decrement ", 8, 66, 184, 24, .selectable, &.{.{ .click = decrement }}),
        .button(" Reset ", 8, 96, 184, 24, .selectable, &.{.{ .click = reset }}),
    });

    app.run();
}
