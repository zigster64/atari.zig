# GEMZ - a Zig wrapper lib for GEM functions for Atari ST

## Scope

This Zig library exports a set of objects and functions that allow 
a Zig program to easily interface with GEM via AES and VDI

Each function takes Zig types, so it benefits from zig enums, null handling, error values, etc
and then provides a lightweight wrapper to the m68k asm instructions to exec the GEM calls.

## Procedure - How we are going to build this

What we will do is - come up with an ideal end user program using
the simplest possible API to have really clean and idiomatic Zig DX, 
and then work backwards from that 'finished code' to implement just 
those missing bits from the library !

## Build tools

if you run `zig build` - thats not going to work, because it will use the system
zig. 

Use ~/Atari/bin/zig to get the m68k version of zig that knows how to target
the m68k backend

### Task 1 - Hello World

In the hello/ dir in the project root is a simple program that generates 
and Atari ST .PRG executable that pops up a simple dialog box using Gem functions

What we want to do is add a build target to this GEMZ/ project that builds 
its own HELLO.PRG using the code in ./src/hello.zig, but using this GEMZ lib
instead of all the raw AES calls.

This will mean updating the build.zig in here of course

Then - we want the build.zig to use src/root.zig to hold the code for the gemz library target
and then when buiding hello.prg, import the gemz package

So the code in src/hello.zig should end up looking really simple like

const gemz = @import("gemz");
main() !void {
   const app = try gemz.app.init();
   defer app.exit();
   app.form_alert(.default_button, "Hello World");
}

You will need to do some tricky stuff in build.zig in here to 
inject _start() that calls main(), handles errors, and then fiddles with
the linker config to make _start the initial entry point in the PRG

### Task 1 - Done ✅

Builds cleanly with `~/Atari/bin/zig build` and produces `./zig-out/atari/HELLO.PRG`
(561 bytes, valid GEMDOS header `0x601A`).

**Files**
- `src/root.zig` — the GEMZ library (AES param block, trap #2 dispatch, the `app`
  API, `start()` runtime, and freestanding `panic`/`memset`/`abort` stubs).
- `src/hello.zig` — the end-user program (imports `gemz`).
- `src/startup.s` + `prg.ld` — the trampoline + linker script (mirrors `../hello`).
- `build.zig` — rewritten: `gemz` module + `hello` module (m68k) + trampoline +
  `m68k-elf-ld --relocatable` + `toslink`. Removed the `zig init` template `src/main.zig`.

**The `_start` injection** (the "tricky stuff")
- GEMZ exposes `start()` which does `@import("root").main() catch {}` then `Pterm0`.
- `src/hello.zig` keeps a 3-line shim: `export fn _start` → `gemz.start()`, plus
  `pub const panic = gemz.panic`. (`_start` must live in the *root* module — Zig 0.16
  drops `export fn` from imported modules.)
- `build.zig` sets `obj.entry = .{ .symbol_name = "_start" }` and the trampoline
  (`src/startup.s`) + `prg.ld` put the entry at text offset 0, exactly like `../hello`.

**API shape delivered**
```zig
const gemz = @import("gemz");
// gemz.app.init() -> !app   (appl_init, error.ApplInitFailed on -1)
// app.exit()               (appl_exit)
// app.form_alert(.default_button, "Hello World")
```
`form_alert` auto-wraps plain text into the GEM alert format `[1][<text>][ OK ]`
(icon fixed to note, single "OK" button for now). `.default_button` is the
`AlertButton` enum (`= 1`). `text` must be comptime-known (a string literal):
the full string is built with comptime `++` concatenation — runtime byte-by-byte
string building trips an LLVM m68k backend bug (indexed byte stores lose their
index register, writing every byte to the same address and corrupting the dialog).

**Notes / next refinements**
- `AlertButton` currently only carries `default_button = 1`; arbitrary button
  indices and multi-button/icon selection are future work.
- AES dispatch returns only `int_out[0]`; functions needing multiple `int_out`/`addr_out`
  values (e.g. `wind_get`, `rsrc_gaddr`) will need a richer return shape.
- Requires `m68k-elf-binutils` on PATH (`brew install m68k-elf-binutils`) — now installed.

### Task 2 - More Dialogs

Now, lets change the hello app so that on boot it presents a GEM window that 
- has a title 'GEMZ Demo'
- has a banner saying 'This is a demo of GEMZ functions'

- then has a number of buttons stacked in a grid at the bottom

The first button is 'alert' - on click it should call the form_alert() that 
we currently have

The last button will be 'Close' - clicking that exits the app

So the new main will look something like

main() !void {
  const app = try gemz.app.init();
  
  ... do whatever to render the window, the title, the banner and the grid of buttons

  connect the click event on the 'Alert' button to the alert function
}

alert(app: *App) !void {
  app.form_alert(.default_button, "GEMZ Hello World|Built with Zig 0.16.0|m68k backend");
}

### Task 2 - Done ✅

Builds cleanly and produces `./zig-out/atari/HELLO.PRG` (1737 bytes). The demo
opens a GEM window ("GEMZ Demo" title), draws a banner + two buttons via an
object tree, and runs an event loop.

**New in the library (`src/root.zig`)**
- Types: `Rect`, `Point`, `Object` (+ `ObjectType`/`ObjectFlag`), `WindKind`,
  `WindField`, `WindUpdate`, `MessageType`, `EventMask`, `Event`.
- AES: `wind_create/open/close/delete/set/get/update`, `objc_draw/find`,
  `evnt_multi`, `graf_mouse`.
- `Window` struct: `create`/`open`/`close`/`delete`/`setTitle`/`workOrigin`.
- `app.run(window, tree, onClick)` — the event loop: redraws the tree on
  WM_REDRAW, exits on WM_CLOSED, and dispatches button clicks (via `objc_find`,
  screen→work-area coords) to a comptime `onClick(app, obj_index)` callback
  that returns `false` to quit.

**hello.zig now looks like**
```zig
pub fn main() !void {
    const app = try gemz.app.init();
    defer app.exit();

    var tree = [_]gemz.Object{ /* root box + banner text + Alert + Close buttons */ };

    const win = try gemz.Window.create(name|closer|mover, 50, 50, 320, 200);
    defer { win.close(); win.delete(); }
    win.setTitle("GEMZ Demo");
    win.open(50, 50, 320, 200);

    app.run(&win, &tree, onClick);
}
```

**Notes / gotchas**
- LLVM emits a `memcpy` call for the `Rect`/`Point` by-value returns — added a
  `memcpy` stub alongside `memset`. (Its `dest[i] = src[i]` byte loop compiles
  fine: the earlier indexed-store bug only bit slice-of-stack-array stores, not
  register-pointer stores.)
- `evnt_multi` returns screen coords; `Window.workOrigin()` (via
  `wind_get` CURRXYWH + WORKXYWH) converts to object-tree coords for `objc_find`.
- Object tree is a mutable stack array initialized at comptime; the button
  labels / title / banner are comptime string literals (no runtime string work).
- `wind_set` title uses `addr_in` (WF_NAME=2); `wind_get` work/current rect uses
  `int_out` (WF_WORKXYWH=4 / WF_CURRXYWH=5).
- `graf_mouse`/`GrafMouse` are defined but not yet wired into the demo.




