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

    // Object tree: root box (0), banner text (1), " Alert " button (2),
    // " Close " button (3).
    var tree = [_]gemz.Object{
        .{
            .ob_next = -1, .ob_head = 1, .ob_tail = 3,
            .ob_type = @intFromEnum(gemz.ObjectType.box),
            .ob_flags = 0, .ob_state = 0, .ob_spec = null,
            .ob_x = 0, .ob_y = 0, .ob_w = 320, .ob_h = 200,
        },
        .{
            .ob_next = 2, .ob_head = -1, .ob_tail = -1,
            .ob_type = @intFromEnum(gemz.ObjectType.text),
            .ob_flags = 0, .ob_state = 0,
            .ob_spec = "This is a demo of GEMZ functions",
            .ob_x = 8, .ob_y = 8, .ob_w = 300, .ob_h = 20,
        },
        .{
            .ob_next = 3, .ob_head = -1, .ob_tail = -1,
            .ob_type = @intFromEnum(gemz.ObjectType.button),
            .ob_flags = gemz.ObjectFlag.selectable,
            .ob_state = 0, .ob_spec = " Alert ",
            .ob_x = 8, .ob_y = 140, .ob_w = 80, .ob_h = 24,
        },
        .{
            .ob_next = -1, .ob_head = -1, .ob_tail = -1,
            .ob_type = @intFromEnum(gemz.ObjectType.button),
            .ob_flags = gemz.ObjectFlag.selectable | gemz.ObjectFlag.exit,
            .ob_state = 0, .ob_spec = " Close ",
            .ob_x = 96, .ob_y = 140, .ob_w = 80, .ob_h = 24,
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
