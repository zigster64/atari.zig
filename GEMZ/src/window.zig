const gemz = @import("gemz");

const MyApp = gemz.App(8, 32);

fn alertClicked(app: *MyApp) bool {
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
        .text("  .. GEMZ library v0.1.0", 8, 32, 300, 20),
        .button(" Alert ", 8, 140, 80, 24, .selectable, &.{.{ .click = alertClicked }}),
        .button(" Close ", 96, 140, 80, 24, .flags(&.{ .selectable, .exit }), &.{.{ .click = closeClicked }}),
    });

    app.run();
}
