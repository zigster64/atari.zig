//! GEMZ "GFX-COLOR" — the colour-monitor test program: Low Res + Med Res.
//!
//!   Low Res 320x200 16 color  -> sleep 2s -> phase loop
//!   Med Res 640x200 4 color   -> sleep 2s -> phase loop
//!
//! Then restore the desktop and exit. Run Hatari with a COLOUR monitor
//! (the default; `--monitor rgb` / nMonitorType = 1). The mono phase lives
//! in GFX-MONO.PRG — rez 2 needs a mono monitor (M68K_NOTES #17).

const gemz = @import("gemz");
const screen = @import("screen");
const demo = @import("gfx_demo");

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var gfx = screen.gfx.lowRes();
    defer {
        demo.dbgRez("GFX-COLOR: restore to", @enumFromInt(@as(u8, @intCast(gfx.old_rez))));
        gfx.restore();
        gemz.applExit();
    }

    demo.dbgRez("GFX-COLOR: captured", @enumFromInt(@as(u8, @intCast(gfx.old_rez))));

    gemz.dbg("Low Res 320x200 16 color");
    demo.sleepVsyncs(&gfx, 120);
    demo.runPhase(&gfx, .low);

    // Clear the screen so the phase pause (and the dbg marker) is on a
    // clean field.
    demo.showField(&gfx, .low);
    gemz.dbg("Med Res 640 x 200 4 color");
    gfx.setRez(.medium);
    demo.showField(&gfx, .medium);
    demo.sleepVsyncs(&gfx, 120);
    demo.runPhase(&gfx, .medium);

    demo.showField(&gfx, .medium);
    gemz.dbg("GFX-COLOR: done");
}
