//! GEMZ "GFX-MONO" — the mono-monitor test program: Hi Res monochrome.
//!
//!   Hi Res 640 x 400 monochrome -> sleep 2s -> phase loop
//!
//! Then restore the desktop and exit. Run Hatari with a MONO monitor
//! (`--monitor mono` / nMonitorType = 0) — rez 2 only works with a mono
//! monitor (GLUE mono-detect, real hardware too; M68K_NOTES #17). The
//! colour resolutions live in GFX-COLOR.PRG.

const gemz = @import("gemz");
const screen = @import("screen");
const demo = @import("gfx_demo");

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var gfx = screen.gfx.lowRes();
    defer {
        demo.dbgRez("GFX-MONO: restore to", @enumFromInt(@as(u8, @intCast(gfx.old_rez))));
        gfx.restore();
        gemz.applExit();
    }

    demo.dbgRez("GFX-MONO: captured", @enumFromInt(@as(u8, @intCast(gfx.old_rez))));

    gemz.dbg("Hi Res 640 x 400 monochrome");
    gfx.setRez(.high);
    demo.showField(&gfx, .high);
    demo.sleepVsyncs(&gfx, 120);
    demo.runPhase(&gfx, .high);

    demo.showField(&gfx, .high);
    gemz.dbg("GFX-MONO: done");
}
