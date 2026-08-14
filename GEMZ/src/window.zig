//! GEMZ "Demo" — a GEM window with a banner and a grid of buttons.

const gemz = @import("gemz");

pub const panic = gemz.panic;

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

// Button click handler. Returns false to end the app.
fn onClick(app: *const gemz.app, obj: i16) bool {
    switch (obj) {
        2 => app.form_alert(.default_button, "GEMZ Hello World|Built with Zig 0.16.0|m68k backend"),
        3 => return false, // "Close"
        else => {},
    }
    return true;
}

pub fn main() !void {
    const app = try gemz.app.init();
    defer app.exit();

    // TEMP DEBUG: prove boot/init works before the window + event loop.
    app.form_alert(.default_button, "boot ok");

    // Object tree: root box (0), banner text (1), " Alert " button (2),
    // " Close " button (3).
    var tree = [_]gemz.Object{
        .{
            .next = -1, .head = 1, .tail = 3,
            .object_type = .box,
            .flags = 0, .state = 0, .spec = null,
            .x = 0, .y = 0, .w = 320, .h = 200,
        },
        .{
            .next = 2, .head = -1, .tail = -1,
            .object_type = .text,
            .flags = 0, .state = 0,
            .spec = "This is a demo of GEMZ functions",
            .x = 8, .y = 8, .w = 300, .h = 20,
        },
        .{
            .next = 3, .head = -1, .tail = -1,
            .object_type = .button,
            .flags = gemz.ObjectFlag.selectable,
            .state = 0, .spec = " Alert ",
            .x = 8, .y = 140, .w = 80, .h = 24,
        },
        .{
            .next = -1, .head = -1, .tail = -1,
            .object_type = .button,
            .flags = gemz.ObjectFlag.selectable | gemz.ObjectFlag.exit,
            .state = 0, .spec = " Close ",
            .x = 96, .y = 140, .w = 80, .h = 24,
        },
    };

    const win = try gemz.Window.create(
        gemz.WindKind.name | gemz.WindKind.closer | gemz.WindKind.mover,
        50, 50, 320, 200,
    );
    defer {
        win.close();
        win.delete();
    }
    win.setTitle("GEMZ Demo");
    win.open(50, 50, 320, 200);

    app.run(&win, &tree, onClick);
}
