//! GEMZ "GFX2" — variant for Hatari builds that only render the top lines of
//! a custom screen base: draw DIRECTLY into the desktop's own screen buffer
//! (no Vsetscreen base change, single buffer). If this fills the whole screen
//! where GFX.PRG doesn't, the issue is the base address / resolution switch in
//! that particular Hatari build.

const gemz = @import("gemz");
const screen = @import("screen");

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    gemz.dbg("GFX2: start");
    const base = screen.physbase(); // the desktop's current screen base
    _ = gemz.applInit();
    gemz.grafMouse(gemz.GrafMouse.off);
    gemz.windUpdate(gemz.WindUpdate.beg_update);

    // Sweep the whole (desktop) screen through the 16 colours, double-free.
    var c: u16 = 0;
    while (true) : (c += 1) {
        screen.clearScreen(base, @intCast(c & 15));
        screen.vsync();
    }
}
