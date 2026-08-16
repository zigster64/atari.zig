const gemz = @import("gemz");

// Declare up front the size of the app - Max Views / Max Objects
const MyApp = gemz.App(1, 16);

// A static TEDINFO for the red subtitle (must be a module-level const so its
// address is stable).
const RED = gemz.TedInfo.from("  .. GEMZ library v0.1.0", .magenta);

// The classic Atari "Fuji" mark, 48x24, packed from ASCII art at comptime.
const FUJI = @import("logo_atari.zig").FUJI;
const LOGO = gemz.BitBlk.from(&FUJI, .black);

fn aboutClicked(app: *MyApp) bool {
    app.form_alert(.default_button, "GEMZ Hello World|Build with Zig 0.16.0|m68k backend");
    return true;
}

fn closeClicked(_: *MyApp) bool {
    return false;
}

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var app = try MyApp.init();
    defer app.exit();

    try app.open(.{
        .kind = .{ .name = true, .closer = true, .mover = true, .sizer = true },
        .title = "GEMZ WINDOW DEMO",
        .x = 50,
        .y = 50,
        .w = 320,
        .h = 200,
    }, &.{
        .box(320, 200),
        .text("Mega GEM demo written in Zig", 8, 8, 300, 20),
        .textTed(&RED, 8, 32, 300, 20),
        .image(&LOGO, 120, 60, 48, 24),
        .button(" About ", 8, 140, 80, 24, .selectable, &.{.{ .click = aboutClicked }}),
        .button(" Close ", 96, 140, 80, 24, .flags(&.{ .selectable, .exit }), &.{.{ .click = closeClicked }}),
    });

    app.run();
}
