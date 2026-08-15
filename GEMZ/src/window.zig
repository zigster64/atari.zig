const gemz = @import("gemz");

fn onClick(app: *const gemz.app, object_id: i16, obj: gemz.Object) bool {
    _ = obj; // autofix
    // switch (obj.object_type) {
    //     .button => {
    //         if (obj.spec) |lbl| {
    //             if (gemz.hasPrefix(" Alert ", lbl)) app.form_alert(.default_button, "GEMZ Hello World|Build with Zig 0.16.0|m68k backend");
    //             if (gemz.hasPrefix(" Close ", lbl)) return false;
    //         }
    //     },
    //     else => {},
    // }
    switch (object_id) {
        3 => app.form_alert(.default_button, "GEMZ Hello World|Built with Zig 0.16.0|m68k backend"),
        4 => return false,
        else => {},
    }
    return true;
}

// Needs this to setup the correct code at 0x0000 to exec the program
export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    const app = try gemz.app.init();
    defer app.exit();

    var tree = gemz.Object.tree(&.{
        .box(320, 200),
        .text("Mega GEM demo written in Zig", 8, 8, 300, 20),
        .text("  .. GEMZ library v0.1.0", 8, 32, 300, 20),
        .button(" Alert ", 8, 140, 80, 24, .selectable),
        .button(" Close ", 96, 140, 80, 24, .flags(&.{ .selectable, .exit })),
    });

    const win = try gemz.Window.create(.{ .name = true, .closer = true, .mover = true, .sizer = true });
    defer {
        win.close();
        win.delete();
    }
    win.open(50, 50, 320, 200);
    win.setTitle("GEMZ WINDOW DEMO");

    app.run(&win, &tree, onClick);
}
