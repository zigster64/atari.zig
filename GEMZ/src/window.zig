//! GEMZ "Demo" — the absolute minimum: a 320x200 window filled with a white box.
//! Move it via the title bar, close it via the close box.

const gemz = @import("gemz");

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    const app = try gemz.app.init();
    defer app.exit();

    // The white box: a single G_BOX object filling the window's work area.
    var box = [_]gemz.Object{.box(320, 200)};

    const win = try gemz.Window.create(.{ .name = true, .closer = true, .mover = true });
    defer {
        win.close();
        win.delete();
    }
    win.open(50, 50, 320, 200);
    win.setTitle("WINDOW DEMO");

    app.runBasic(&win, &box);
}
