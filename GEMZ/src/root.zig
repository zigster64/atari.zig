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

/// Input arrays for an AES call, passed to `aesCall` by pointer. Passing slices
/// instead trips an m68k backend bug: a slice *length* carried in `d1` arrives
/// as 0, so `int_in` gets nulled. Lengths read back from memory are safe.
const AesArgs = extern struct {
    int_in: ?[*]const i16,
    n_int_in: u16,
    addr_in: ?[*]const ?[*]const u8,
    n_addr_in: u16,
    n_int_out: u16,

    /// No inputs (appl_init, appl_exit).
    pub fn none() AesArgs {
        return .{ .int_in = null, .n_int_in = 0, .addr_in = null, .n_addr_in = 0, .n_int_out = 1 };
    }

    /// int_in only; explicit output count.
    pub fn ints(int_in: anytype, comptime out: u16) AesArgs {
        return .{ .int_in = int_in, .n_int_in = @intCast(int_in.len), .addr_in = null, .n_addr_in = 0, .n_int_out = out };
    }

    /// int_in + addr_in; explicit output count.
    pub fn from(int_in: anytype, addr_in: anytype, comptime out: u16) AesArgs {
        return .{ .int_in = int_in, .n_int_in = @intCast(int_in.len), .addr_in = addr_in, .n_addr_in = @intCast(addr_in.len), .n_int_out = out };
    }
};

/// AES opcodes (trap #2, d0 = $C8). Complete standard set.
pub const AesOpcode = enum(u16) {
    // appl_*
    appl_init = 10,
    appl_read = 11,
    appl_write = 12,
    appl_find = 13,
    appl_tplay = 14,
    appl_trecord = 15,
    appl_bvset = 16,
    appl_yield = 17,
    appl_search = 18,
    appl_exit = 19,

    // evnt_*
    evnt_keybd = 20,
    evnt_button = 21,
    evnt_mouse = 22,
    evnt_mesag = 23,
    evnt_timer = 24,
    evnt_multi = 25,
    evnt_dclick = 26,

    // menu_*
    menu_bar = 30,
    menu_icheck = 31,
    menu_ienable = 32,
    menu_tnormal = 33,
    menu_text = 34,
    menu_register = 35,
    menu_unregister = 36,

    // objc_*
    objc_add = 40,
    objc_delete = 41,
    objc_draw = 42,
    objc_find = 43,
    objc_offset = 44,
    objc_order = 45,
    objc_edit = 46,
    objc_change = 47,

    // form_*
    form_do = 50,
    form_dial = 51,
    form_alert = 52,
    form_error = 53,
    form_center = 54,
    form_keybd = 55,
    form_button = 56,

    // graf_*
    graf_rubberbox = 70,
    graf_dragbox = 71,
    graf_movebox = 72,
    graf_growbox = 73,
    graf_shrinkbox = 74,
    graf_watchbox = 75,
    graf_slidebox = 76,
    graf_handle = 77,
    graf_mouse = 78,
    graf_mkstate = 79,

    // scrp_*
    scrp_read = 80,
    scrp_write = 81,
    scrp_clear = 82,

    // fsel_*
    fsel_input = 90,

    // wind_*
    wind_create = 100,
    wind_open = 101,
    wind_close = 102,
    wind_delete = 103,
    wind_get = 104,
    wind_set = 105,
    wind_find = 106,
    wind_update = 107,
    wind_calc = 108,
    wind_new = 109,

    // rsrc_*
    rsrc_load = 110,
    rsrc_free = 111,
    rsrc_gaddr = 112,
    rsrc_saddr = 113,
    rsrc_obfix = 114,

    // shel_*
    shel_read = 120,
    shel_write = 121,
    shel_get = 122,
    shel_put = 123,
    shel_find = 124,
    shel_envrn = 125,
    shel_rdef = 126,
    shel_wdef = 127,

    // xgrf_*
    xgrf_stepcalc = 130,
    xgrf_2box = 131,

    // Unknown/extension opcode. Non-exhaustive so `@enumFromInt` of an
    // unlisted value is well-defined rather than UB.
    _,
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

/// The full 7-word output of the most recent AES call. Callers that need more
/// than the return code (`wind_get`, `evnt_multi`) read this after `aesCall`.
var aes_out: [7]i16 = .{ 0, 0, 0, 0, 0, 0, 0 };

fn aesTrap(pb: *const AesPb) void {
    asm volatile (
        \\move.l %[pb], %%d1
        \\move.w #0xc8, %%d0
        \\trap #2
        :
        : [pb] "r" (pb),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true });
}

/// Dispatch one AES call. `out[0]` is the implicit AES return code, declared
/// output integers start at index 1; the full 7 words are left in `aes_out`.
/// `n_int_out` is fixed at the AES maximum of 7; callers read only the words
/// they declared.
noinline fn aesCall(opcode: AesOpcode, args: *const AesArgs) i16 {
    var control = AesControl{
        .opcode = @intFromEnum(opcode),
        .n_int_in = args.n_int_in,
        .n_int_out = args.n_int_out,
        .n_addr_in = args.n_addr_in,
        .n_addr_out = 0,
    };
    var int_out: [7]i16 = .{ 0, 0, 0, 0, 0, 0, 0 };
    var addr_out: [1]?[*]u8 = .{null};

    const pb = AesPb{
        .control = &control,
        .global = &global,
        .int_in = args.int_in,
        .int_out = &int_out,
        .addr_in = args.addr_in,
        .addr_out = &addr_out,
    };

    aesTrap(&pb);
    aes_out = int_out;
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

/// GEMDOS Cconws (trap #1, function 9) — write a NUL-terminated string to the
/// console. Visible on the host via Hatari `--conout 2`.
fn cconws(s: [*:0]const u8) void {
    asm volatile (
        \\move.l %[s], -(%%sp)
        \\move.w #9, -(%%sp)
        \\trap #1
        \\lea 6(%%sp), %%sp
        :
        : [s] "r" (s),
        : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true });
}

/// TEMP DEBUG: print a comptime message to the GEMDOS console.
pub fn dbg(comptime msg: []const u8) void {
    const s: [*:0]const u8 = msg ++ "\r\n";
    cconws(s);
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
pub const WindKind = packed struct(u16) {
    name: bool = false, // bit 0 — title bar
    closer: bool = false, // bit 1 — close box
    fuller: bool = false, // bit 2 — full box
    mover: bool = false, // bit 3 — move bar
    info: bool = false, // bit 4 — info line
    sizer: bool = false, // bit 5 — size box
    _pad: u10 = 0,
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

/// GEM object flags (bitmask; combine with `ObjectFlag.flags`).
pub const ObjectFlag = enum(u16) {
    none = 0,
    selectable = 0x0001,
    default_ = 0x0002,
    exit = 0x0004,
    editable = 0x0008,
    r_button = 0x0010,
    last_obj = 0x0020,
    touch_exit = 0x0040,
    hide_tree = 0x0080,
    _, // arbitrary bit combinations are valid

    /// Build a combined flags value from a set of flags.
    pub fn flags(set: []const ObjectFlag) ObjectFlag {
        var result: u16 = 0;
        for (set) |f| result |= @intFromEnum(f);
        return @enumFromInt(result);
    }
};

/// GEM text info (`TEDINFO`). `G_TEXT`, `G_BOXTEXT`, `G_FTEXT` and `G_FBOXTEXT`
/// objects point at this instead of a raw string — EmuTOS dereferences it as a
/// pointer-to-structure. `G_BUTTON` uses a plain string, not a TEDINFO.
pub const TedInfo = extern struct {
    ptext: ?[*]const u8, // ptr to text (must be first)
    ptmplt: ?[*]const u8, // ptr to template
    pvalid: ?[*]const u8, // ptr to validation chars
    font: i16, // font id (3 = system font)
    junk1: i16,
    just: i16, // justification (0 = left)
    color: i16, // text colour (1 = black)
    junk2: i16,
    thickness: i16, // border thickness
    txtlen: i16, // text length
    tmplen: i16, // template length
};

/// A GEM object-tree node (24 bytes, layout per Atari GEM).
pub const Object = extern struct {
    next: i16 = -1, // next sibling, -1 = none
    head: i16 = -1, // first child, -1 = none
    tail: i16 = -1, // last child, -1 = none
    object_type: ObjectType,
    flags: ObjectFlag = .none,
    state: u16 = 0,
    spec: ?[*]const u8 = null, // text label for text/button objects
    x: i16 = 0,
    y: i16 = 0,
    w: i16 = 0,
    h: i16 = 0,

    /// A container box (typically the root of a subtree), at (0,0).
    pub fn box(w: i16, h: i16) Object {
        return .{ .object_type = .box, .w = w, .h = h };
    }

    /// A text object (G_TEXT). EmuTOS reads G_TEXT `ob_spec` as a `TEDINFO`
    /// (pointer-to-structure whose `ptext` is the string), so pass a
    /// `TedInfo` rather than a plain string.
    pub fn text(spec: *const TedInfo, x: i16, y: i16, w: i16, h: i16) Object {
        return .{ .object_type = .text, .spec = @ptrCast(spec), .x = x, .y = y, .w = w, .h = h };
    }

    /// A push button.
    pub fn button(spec: [*:0]const u8, x: i16, y: i16, w: i16, h: i16, flags: ObjectFlag) Object {
        return .{ .object_type = .button, .flags = flags, .spec = @ptrCast(spec), .x = x, .y = y, .w = w, .h = h };
    }

    /// Build a flat tree: node 0 is the root, nodes 1..N are its direct
    /// children. Fills in the next/head/tail links automatically.
    ///
    /// Uses `inline for` so the copies/link writes unroll to fixed-index stores
    /// at compile time — a runtime `for` here is miscompiled by the m68k
    /// backend (indexed store loses its index register).
    pub fn tree(comptime nodes: []const Object) [nodes.len]Object {
        var result: [nodes.len]Object = undefined;
        inline for (nodes, 0..) |node, i| result[i] = node;
        if (nodes.len > 1) {
            result[0].head = 1;
            result[0].tail = @intCast(nodes.len - 1);
            inline for (1..nodes.len - 1) |i| result[i].next = @intCast(i + 1);
        }
        return result;
    }
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

noinline fn windCreate(kind: u16, x: i16, y: i16, w: i16, h: i16) i16 {
    const int_in = [_]i16{ @bitCast(kind), x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    return aesCall(.wind_create, &args);
}

noinline fn windOpen(id: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ id, x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_open, &args);
}

noinline fn windClose(id: i16) void {
    const int_in = [_]i16{id};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_close, &args);
}

noinline fn windDelete(id: i16) void {
    const int_in = [_]i16{id};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_delete, &args);
}

noinline fn windSetTitle(id: i16, title: [*:0]const u8) void {
    // wind_set passes pointer args in the int_in array (the 32-bit address
    // split across two words), not via addr_in.
    const p: u32 = @intFromPtr(title);
    const int_in = [_]i16{
        id,
        WindField.name,
        @intCast(p >> 16),
        @intCast(p & 0xffff),
        0,
        0,
    };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_set, &args);
}

noinline fn windSet(id: i16, field: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ id, field, x, y, w, h };
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_set, &args);
}

noinline fn windGet(id: i16, field: i16, out: *Rect) void {
    const int_in = [_]i16{ id, field };
    const args = AesArgs.ints(&int_in, 5);
    _ = aesCall(.wind_get, &args);
    out.x = aes_out[1];
    out.y = aes_out[2];
    out.w = aes_out[3];
    out.h = aes_out[4];
}

noinline fn windUpdate(mode: i16) void {
    const int_in = [_]i16{mode};
    const args = AesArgs.ints(&int_in, 1);
    _ = aesCall(.wind_update, &args);
}

// ---------------------------------------------------------------------------
// AES: object trees
// ---------------------------------------------------------------------------

pub noinline fn objcDraw(tree: []Object, obj: i16, depth: i16, cx: i16, cy: i16, cw: i16, ch: i16) void {
    const int_in = [_]i16{ obj, depth, cx, cy, cw, ch };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.objc_draw, &args);
}

noinline fn objcFind(tree: []Object, obj: i16, depth: i16, mx: i16, my: i16) i16 {
    const int_in = [_]i16{ obj, depth, mx, my };
    const addr_in = [_]?[*]const u8{@ptrCast(tree.ptr)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    return aesCall(.objc_find, &args);
}

// ---------------------------------------------------------------------------
// AES: events and cursor
// ---------------------------------------------------------------------------

/// Wait for a button click (left button) or a message, filling `message`
/// (16 words) and `ev`. The `ev.mx`/`ev.my` are in *screen* coordinates.
noinline fn evntMulti(message: *[16]i16, ev: *Event) void {
    const int_in = [_]i16{
        @bitCast(EventMask.button | EventMask.mesag), // events
        1, // bclicks
        1, // bmask (left button)
        1, // bstate (pressed) — 0 (released) returns immediately when the
           // button is already up, causing a busy loop
        0, 0, 0, 0, 0, // m1 (unused)
        0, 0, 0, 0, 0, // m2 (unused)
        0, 0, // timer
    };
    const addr_in = [_]?[*]const u8{@ptrCast(message)};
    const args = AesArgs.from(&int_in, &addr_in, 7);
    _ = aesCall(.evnt_multi, &args);
    ev.ev = @bitCast(aes_out[0]);
    ev.mx = aes_out[1];
    ev.my = aes_out[2];
    ev.mb = aes_out[3];
    ev.ks = aes_out[4];
    ev.kc = aes_out[5];
    ev.mc = aes_out[6];
}

noinline fn grafMouse(mode: i16) void {
    const int_in = [_]i16{mode};
    const addr_in = [_]?[*]const u8{null};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.graf_mouse, &args);
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

/// A GEM window.
pub const Window = struct {
    id: i16,

    /// `wind_create` — create the window using the desktop work area as the
    /// maximum constraint. Fails if the AES returns no handle.
    pub fn create(kind: WindKind) !Window {
        var desktop: Rect = undefined;
        windGet(0, WindField.work_xywh, &desktop);
        const id = windCreate(@bitCast(kind), desktop.x, desktop.y, desktop.w, desktop.h);
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

    /// `wind_set` WF_CURRXYWH — move/resize the window.
    pub fn moveTo(self: *const Window, x: i16, y: i16, w: i16, h: i16) void {
        windSet(self.id, WindField.curr_xywh, x, y, w, h);
    }

    /// Screen coordinates of the work-area origin (used to convert an
    /// `evnt_multi` screen coordinate into an object-tree coordinate).
    /// EmuTOS returns `work_xywh` in screen coordinates already, so no
    /// `curr_xywh` is added.
    pub fn workOrigin(self: *const Window) Point {
        var work: Rect = undefined;
        windGet(self.id, WindField.work_xywh, &work);
        return .{ .x = work.x, .y = work.y };
    }
};

/// Draw the tree into the window on WM_REDRAW. EmuTOS draws the tree at its
/// root's `ob_x/ob_y` in *screen* coordinates (the objc_draw arguments are the
/// clip, not an origin), so the root is placed at the window's work-area
/// origin; its children stay window-relative.
fn redrawTree(window: *const Window, tree: []Object, xc: i16, yc: i16, wc: i16, hc: i16) void {
    const origin = window.workOrigin();
    tree[0].x = origin.x;
    tree[0].y = origin.y;
    windUpdate(WindUpdate.beg_update);
    objcDraw(tree, 0, 8, xc, yc, wc, hc);
    windUpdate(WindUpdate.end_update);
}

// ---------------------------------------------------------------------------
// Application session
// ---------------------------------------------------------------------------

/// An AES application session.
pub const app = struct {
    /// The application id assigned by `appl_init`.
    id: i16,

    /// `appl_init` — register the application with the AES.
    pub fn init() !app {
        const args = AesArgs.none();
        const id = aesCall(.appl_init, &args);
        if (id == -1) return error.ApplInitFailed;
        return .{ .id = id };
    }

    /// `appl_exit` — release the application from the AES.
    pub fn exit(_: *const app) void {
        const args = AesArgs.none();
        _ = aesCall(.appl_exit, &args);
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
        const args = AesArgs.from(&int_in, &addr_in, 1);
        _ = aesCall(.form_alert, &args);
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

        // `appl_init` leaves the app in the busy (hourglass) state; switch to
        // the arrow cursor now that setup is done and we're about to yield.
        grafMouse(GrafMouse.arrow);

        while (true) {
            evntMulti(&msg, &ev);

            if ((ev.ev & EventMask.mesag) != 0) {
                switch (msg[0]) {
                    MessageType.wm_redraw => redrawTree(window, tree, msg[4], msg[5], msg[6], msg[7]),
                    MessageType.wm_moved => window.moveTo(msg[4], msg[5], msg[6], msg[7]),
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

    /// Run a minimal modal event loop: redraws `tree` on WM_REDRAW, moves the
    /// window on WM_MOVED, and returns on WM_CLOSED. No button handling or
    /// click callback.
    pub fn runBasic(_: *const app, window: *const Window, tree: []Object) void {
        var msg: [16]i16 = undefined;
        var ev: Event = undefined;

        grafMouse(GrafMouse.arrow);

        while (true) {
            evntMulti(&msg, &ev);

            if ((ev.ev & EventMask.mesag) != 0) {
                switch (msg[0]) {
                    MessageType.wm_redraw => redrawTree(window, tree, msg[4], msg[5], msg[6], msg[7]),
                    MessageType.wm_moved => window.moveTo(msg[4], msg[5], msg[6], msg[7]),
                    MessageType.wm_closed => return,
                    else => {},
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Runtime entry point — called from the user's `_start` shim.
// ---------------------------------------------------------------------------

/// Show a simple alert box without an `app` instance (used for error reporting).
pub fn alert(comptime text: []const u8) void {
    const msg: [*:0]const u8 = "[1][" ++ text ++ "][ OK ]";
    const int_in = [_]i16{1};
    const addr_in = [_]?[*]const u8{@ptrCast(msg)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.form_alert, &args);
}

/// Show a `[1][<name>][ OK ]` alert from a *runtime* string (e.g. an error
/// name). Builds the bytes with an incrementing many-pointer rather than a
/// slice, to avoid the m68k backend's indexed-store miscompile.
pub fn alertName(name: []const u8) void {
    var buf: [64]u8 = undefined;
    var p: [*]u8 = &buf;
    for ("[1]"[0..]) |c| {
        p[0] = c;
        p += 1;
    }
    for (name) |c| {
        p[0] = c;
        p += 1;
    }
    for ("][ OK ]"[0..]) |c| {
        p[0] = c;
        p += 1;
    }
    p[0] = 0;

    const int_in = [_]i16{1};
    const addr_in = [_]?[*]const u8{@ptrCast(&buf)};
    const args = AesArgs.from(&int_in, &addr_in, 1);
    _ = aesCall(.form_alert, &args);
}

/// Call the root module's `main()`, report any error via an alert, then exit.
pub fn start() callconv(.c) noreturn {
    const root = @import("root");
    root.main() catch |err| alertName(@errorName(err));
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
