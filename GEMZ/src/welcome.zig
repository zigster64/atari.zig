//! GEMZ "Hello" — the classic welcome dialog, via the GEMZ library.

const gemz = @import("gemz");

const MyApp = gemz.App(1, 8);

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var app = try MyApp.init();
    defer app.exit();
    app.form_alert(.default_button, "All your base|are belong to|Zig m68k");
}
