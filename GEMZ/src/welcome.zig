//! GEMZ "Hello" — the classic welcome dialog, via the GEMZ library.

const gemz = @import("gemz");

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    const app = try gemz.app.init();
    defer app.exit();
    app.form_alert(.default_button, "All your base|are belong to|Zig m68k");
}
