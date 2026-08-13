//! GEMZ — idiomatic Zig wrappers for Atari ST GEM (AES + VDI).
//!
//! Freestanding m68k, no std lib; every system call is inline m68k asm.
//! The AES (trap #2, d0 = $C8) parameter block layout and calling convention
//! follow the working `hello/src/main.zig` example and the canonical reference
//! at `libs/toslibc/include/toslibc/tos/aes.h`.
//!
//! Everything lives in this one file for now; the structs (`app`, `Window`,
//! `Object`, …) will be split into separate files later.

const std = @import("std");

// ---------------------------------------------------------------------------
// AES parameter block (trap #2, d0 = $C8)
// ---------------------------------------------------------------------------

const AesControl = extern struct {
    opcode: u16,
    n_int_in: u16,
    n_int_out: u16,
    n_addr_in: u16,
    n_addr_out: u16,
};

const AesGlobal = extern struct {
    version: u16,
    app_max: u16,
    app_id: u16,
    user: u32,
    rsc: ?[*]const u8,
    reserved: [4]u32,
};

const AesPb = extern struct {
    control: *AesControl,
    global: *AesGlobal,
    int_in: ?[*]const i16,
    int_out: [*]i16,
    addr_in: ?[*]const ?[*]const u8,
    addr_out: [*]?[*]u8,
};

/// The single AES global block. `appl_init` writes `app_id` here and it must
/// persist for the whole application lifetime.
var global: AesGlobal = .{
    .version = 0,
    .app_max = 0,
    .app_id = 0,
    .user = 0,
    .rsc = null,
    .reserved = .{0} ** 4,
};

fn aesTrap(pb: *const AesPb) void {
    asm volatile (
        \\move.l %[pb], %%d1
        \\move.w #0xc8, %%d0
        \\trap #2
        :
        : [pb] "r" (pb),
        : .{ .memory = true });
}

/// Dispatch one AES call. The caller supplies `int_out` (its length becomes
/// `n_int_out`); `int_out[0]` is the implicit AES return code, declared output
/// integers start at index 1. Returns `int_out[0]`.
fn aesCall(opcode: u16, int_in: []const i16, addr_in: []const ?[*]const u8, int_out: []i16) i16 {
    var control = AesControl{
        .opcode = opcode,
        .n_int_in = @intCast(int_in.len),
        .n_int_out = @intCast(int_out.len),
        .n_addr_in = @intCast(addr_in.len),
        .n_addr_out = 0,
    };
    var addr_out: [1]?[*]u8 = .{null};

    const pb = AesPb{
        .control = &control,
        .global = &global,
        .int_in = if (int_in.len == 0) null else int_in.ptr,
        .int_out = int_out.ptr,
        .addr_in = if (addr_in.len == 0) null else addr_in.ptr,
        .addr_out = &addr_out,
    };

    aesTrap(&pb);
    return int_out[0];
}

// ---------------------------------------------------------------------------
// GEMDOS exit (trap #1, function 0 = Pterm0)
// ---------------------------------------------------------------------------

fn pterm0() noreturn {
    asm volatile (
        \\move.w #0, -(%%sp)
        \\trap #1
        ::: .{ .memory = true });
    unreachable;
}

// ---------------------------------------------------------------------------
// Public GEM types
// ---------------------------------------------------------------------------

pub const Rect = extern struct {
    x: i16,
    y: i16,
    w: i16,
    h: i16,
};

pub const Point = extern struct {
    x: i16,
    y: i16,
};

/// `wind_create` attribute bits (kind).
pub const WindKind = struct {
    pub const name: i16 = 0x0001; // title bar
    pub const closer: i16 = 0x0002; // close box
    pub const fuller: i16 = 0x0004; // full box
    pub const mover: i16 = 0x0008; // move bar
    pub const info: i16 = 0x0010; // info line
    pub const sizer: i16 = 0x0020; // size box
};

/// `wind_set` / `wind_get` field selectors.
pub const WindField = struct {
    pub const name: i16 = 2; // window title (string, addr_in)
    pub const info: i16 = 3; // info line (string, addr_in)
    pub const work_xywh: i16 = 4; // work area (window-relative)
    pub const curr_xywh: i16 = 5; // current window rect (screen-relative)
};

/// `wind_update` modes.
pub const WindUpdate = struct {
    pub const end_update: i16 = 0;
    pub const beg_update: i16 = 1;
};

/// GEM object types (`ob_type`).
pub const ObjectType = enum(u16) {
    box = 20,
    text = 21,
    box_text = 22,
    image = 23,
    prog_def = 24,
    i_box = 25,
    button = 26,
    string = 27,
    f_text = 28,
    f_box_text = 29,
    icon = 30,
    title = 31,
};

/// GEM object flags (`ob_flags`).
pub const ObjectFlag = struct {
    pub const selectable: u16 = 0x0001;
    pub const default_: u16 = 0x0002;
    pub const exit: u16 = 0x0004;
    pub const editable: u16 = 0x0008;
    pub const r_button: u16 = 0x0010;
    pub const last_obj: u16 = 0x0020;
    pub const touch_exit: u16 = 0x0040;
    pub const hide_tree: u16 = 0x0080;
};

/// A GEM object-tree node (24 bytes, layout per Atari GEM).
pub const Object = extern struct {
    next: i16, // next sibling, -1 = none
    head: i16, // first child, -1 = none
    tail: i16, // last child, -1 = none
    object_type: ObjectType,
    flags: u16,
    state: u16,
    spec: ?[*]const u8, // text label for text/button objects
    x: i16,
    y: i16,
    w: i16,
    h: i16,
};

/// Message types delivered through `evnt_multi`'s message buffer.
pub const MessageType = struct {
    pub const wm_redraw: i16 = 20;
    pub const wm_topped: i16 = 21;
    pub const wm_closed: i16 = 22;
    pub const wm_fulled: i16 = 23;
    pub const wm_arrowed: i16 = 24;
    pub const wm_sized: i16 = 27;
    pub const wm_moved: i16 = 28;
};

/// `evnt_multi` event mask bits.
pub const EventMask = struct {
    pub const keybd: u16 = 0x0001;
    pub const button: u16 = 0x0002;
    pub const m1: u16 = 0x0004;
    pub const m2: u16 = 0x0008;
    pub const mesag: u16 = 0x0010;
    pub const timer: u16 = 0x0020;
};

/// Result of one `evnt_multi` wait.
pub const Event = struct {
    ev: u16, // which event(s) fired (EventMask bits)
    mx: i16,
    my: i16,
    mb: i16, // button state
    ks: i16, // keyboard state
    kc: i16, // key code
    mc: i16, // mouse clicks
};

/// `graf_mouse` cursor shapes.
pub const GrafMouse = struct {
    pub const arrow: i16 = 0;
    pub const hand: i16 = 4;
};

/// The default (single) alert button in a `form_alert` dialog.
pub const AlertButton = enum(i16) {
    default_button = 1,
};

// ---------------------------------------------------------------------------
// AES: window management
// ---------------------------------------------------------------------------

fn windCreate(kind: i16, x: i16, y: i16, w: i16, h: i16) i16 {
    const int_in = [_]i16{ kind, x, y, w, h };
    var out: [1]i16 = undefined;
    return aesCall(100, &int_in, &.{}, &out);
}

fn windOpen(id: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ id, x, y, w, h };
    var out: [1]i16 = undefined;
    _ = aesCall(101, &int_in, &.{}, &out);
}

fn windClose(id: i16) void {
    const int_in = [_]i16{id};
    var out: [1]i16 = undefined;
    _ = aesCall(102, &int_in, &.{}, &out);
}

fn windDelete(id: i16) void {
    const int_in = [_]i16{id};
    var out: [1]i16 = undefined;
    _ = aesCall(103, &int_in, &.{}, &out);
}

fn windSetTitle(id: i16, title: [*:0]const u8) void {
    const int_in = [_]i16{ id, WindField.name };
    const addr_in = [_]?[*]const u8{@ptrCast(title)};
    var out: [1]i16 = undefined;
    _ = aesCall(105, &int_in, &addr_in, &out);
}

fn windGet(id: i16, field: i16) Rect {
    const int_in = [_]i16{ id, field };
    var out: [5]i16 = undefined;
    _ = aesCall(104, &int_in, &.{}, &out);
    return .{ .x = out[1], .y = out[2], .w = out[3], .h = out[4] };
}

fn windUpdate(mode: i16) void {
    const int_in = [_]i16{mode};
    var out: [1]i16 = undefined;
    _ = aesCall(107, &int_in, &.{}, &out);
}

// ---------------------------------------------------------------------------
// AES: object trees
// ---------------------------------------------------------------------------

fn objcDraw(tree: []Object, obj: i16, depth: i16, clip: Rect) void {
    const int_in = [_]i16{ obj, depth, clip.x, clip.y, clip.w, clip.h };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    var out: [1]i16 = undefined;
    _ = aesCall(42, &int_in, &addr_in, &out);
}

fn objcFind(tree: []Object, obj: i16, depth: i16, mx: i16, my: i16) i16 {
    const int_in = [_]i16{ obj, depth, mx, my };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    var out: [1]i16 = undefined;
    return aesCall(43, &int_in, &addr_in, &out);
}

// ---------------------------------------------------------------------------
// AES: events and cursor
// ---------------------------------------------------------------------------

/// Wait for a button click (left button) or a message, filling `message`
/// (16 words) and `ev`. The `ev.mx`/`ev.my` are in *screen* coordinates.
fn evntMulti(message: *[16]i16, ev: *Event) void {
    const int_in = [_]i16{
        @bitCast(EventMask.button | EventMask.mesag), // events
        1, // bclicks
        1, // bmask (left button)
        0, // bstate (released)
        0, 0, 0, 0, 0, // m1 (unused)
        0, 0, 0, 0, 0, // m2 (unused)
        0, 0, // timer
    };
    const addr_in = [_]?[*]const u8{@ptrCast(message)};
    var out: [7]i16 = undefined;
    _ = aesCall(25, &int_in, &addr_in, &out);
    ev.ev = @bitCast(out[0]);
    ev.mx = out[1];
    ev.my = out[2];
    ev.mb = out[3];
    ev.ks = out[4];
    ev.kc = out[5];
    ev.mc = out[6];
}

fn grafMouse(mode: i16) void {
    const int_in = [_]i16{mode};
    const addr_in = [_]?[*]const u8{null};
    var out: [1]i16 = undefined;
    _ = aesCall(78, &int_in, &addr_in, &out);
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

/// A GEM window.
pub const Window = struct {
    id: i16,

    /// `wind_create` — create the window. Fails if the AES returns no handle.
    pub fn create(kind: i16, x: i16, y: i16, w: i16, h: i16) !Window {
        const id = windCreate(kind, x, y, w, h);
        if (id <= 0) return error.WindCreateFailed;
        return .{ .id = id };
    }

    /// `wind_open` — display the window.
    pub fn open(self: *const Window, x: i16, y: i16, w: i16, h: i16) void {
        windOpen(self.id, x, y, w, h);
    }

    /// `wind_close` — remove the window from the screen.
    pub fn close(self: *const Window) void {
        windClose(self.id);
    }

    /// `wind_delete` — free the window.
    pub fn delete(self: *const Window) void {
        windDelete(self.id);
    }

    /// `wind_set` WF_NAME — set the title bar text.
    pub fn setTitle(self: *const Window, comptime title: [*:0]const u8) void {
        windSetTitle(self.id, title);
    }

    /// Screen coordinates of the work-area origin (used to convert an
    /// `evnt_multi` screen coordinate into an object-tree coordinate).
    pub fn workOrigin(self: *const Window) Point {
        const curr = windGet(self.id, WindField.curr_xywh);
        const work = windGet(self.id, WindField.work_xywh);
        return .{ .x = curr.x + work.x, .y = curr.y + work.y };
    }
};

// ---------------------------------------------------------------------------
// Application session
// ---------------------------------------------------------------------------

/// An AES application session.
pub const app = struct {
    /// The application id assigned by `appl_init`.
    id: i16,

    /// `appl_init` — register the application with the AES.
    pub fn init() !app {
        var out: [1]i16 = undefined;
        const id = aesCall(10, &.{}, &.{}, &out);
        if (id == -1) return error.ApplInitFailed;
        return .{ .id = id };
    }

    /// `appl_exit` — release the application from the AES.
    pub fn exit(_: *const app) void {
        var out: [1]i16 = undefined;
        _ = aesCall(19, &.{}, &.{}, &out);
    }

    /// `form_alert` — show a modal alert dialog.
    ///
    /// `text` is plain message text; it is wrapped into the GEM alert format
    /// `"[1][<text>][ OK ]"` (icon 1 = note, one "OK" button). The full string
    /// is built at comptime (like `hello/`) — runtime byte stores trip an m68k
    /// backend codegen bug where indexed stores lose their index register.
    pub fn form_alert(_: *const app, button: AlertButton, comptime text: []const u8) void {
        const msg: [*:0]const u8 = "[1][" ++ text ++ "][ OK ]";
        const int_in = [_]i16{@intFromEnum(button)};
        const addr_in = [_]?[*]const u8{@ptrCast(msg)};
        var out: [1]i16 = undefined;
        _ = aesCall(52, &int_in, &addr_in, &out);
    }

    /// Run the modal event loop for a window.
    ///
    /// Redraws `tree` on WM_REDRAW, returns on WM_CLOSED, and dispatches
    /// button clicks to `onClick` (passing this app); `onClick` returns false
    /// to stop the loop (e.g. a "Close" button).
    pub fn run(
        self: *const app,
        window: *const Window,
        tree: []Object,
        comptime onClick: fn (*const app, i16) bool,
    ) void {
        var msg: [16]i16 = undefined;
        var ev: Event = undefined;
        const depth: i16 = 8;

        while (true) {
            evntMulti(&msg, &ev);

            if ((ev.ev & EventMask.mesag) != 0) {
                switch (msg[0]) {
                    MessageType.wm_redraw => {
                        const clip = Rect{ .x = msg[4], .y = msg[5], .w = msg[6], .h = msg[7] };
                        windUpdate(WindUpdate.beg_update);
                        objcDraw(tree, 0, depth, clip);
                        windUpdate(WindUpdate.end_update);
                    },
                    MessageType.wm_closed => return,
                    else => {},
                }
            }

            if ((ev.ev & EventMask.button) != 0) {
                const origin = window.workOrigin();
                const obj = objcFind(tree, 0, depth, ev.mx - origin.x, ev.my - origin.y);
                if (obj >= 0 and !onClick(self, obj)) return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Runtime entry point — called from the user's `_start` shim.
// ---------------------------------------------------------------------------

/// Call the root module's `main()`, swallow any error, then exit cleanly.
pub fn start() callconv(.c) noreturn {
    const root = @import("root");
    root.main() catch {};
    pterm0();
}

// ---------------------------------------------------------------------------
// Freestanding runtime stubs (needed because bundle_compiler_rt = false)
// ---------------------------------------------------------------------------

/// Re-exported by the user's root module as its panic handler.
pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(_: []const u8, _: ?usize) noreturn {
    abort();
}

export fn abort() noreturn {
    pterm0();
}

/// LLVM lowers struct zero-init to `memset`; compiler_rt's version uses
/// 68020+ instructions, so we provide our own 68000-safe one.
export fn memset(dest: [*]u8, c: i32, n: usize) [*]u8 {
    var i: usize = 0;
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    while (i < n) : (i += 1) dest[i] = byte;
    return dest;
}

/// LLVM lowers struct copies (e.g. returning `Rect`/`Point` by value) to a
/// `memcpy` call; provide our own 68000-safe one.
export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = src[i];
    return dest;
}
