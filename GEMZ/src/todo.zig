//! GEMZ "TODO" — a small GEM todo list that persists to `TODO.db`.
//!
//! `TODO.db` is a simple line-based database: one task per line, the first
//! character is a status sentinel — `D` = done, `T` = todo — followed by the
//! task text and a newline.
//!
//! This app is also a worked example of the m68k backend workarounds:
//!   * every write into a mutable module-level buffer goes through
//!     `gemz.storeByte` / `gemz.storeWord` (a plain `buf[i] = ...` would be
//!     lowered to an illegal PC-relative store),
//!   * runtime iteration uses pointer arithmetic, never `for (&arr, 0..)`,
//!   * no `u32 * u32` (indices are walked with `p += 1`).

const gemz = @import("gemz");

// ---------------------------------------------------------------------------
// Sizes / limits
// ---------------------------------------------------------------------------

const MAX_ITEMS = 64; // max stored tasks
const TEXT_LEN = 40; // task text bytes (incl. NUL)
const VISIBLE = 9; // list rows on screen
const LINE_LEN = 45; // rendered row text (incl. NUL)
const STATUS_LEN = 48; // footer status text
const FILE_CAP = MAX_ITEMS * (TEXT_LEN + 2); // worst-case TODO.db size

const WIN_W: i16 = 380;
const WIN_H: i16 = 320;
const LIST_X: i16 = 12;
const LIST_Y: i16 = 36;
const LIST_W: i16 = 356;
const LINE_H: i16 = 20;

// Node indices in the object tree.
const TOTAL = 19;
const N_HEADER = 1;
const N_LINE0 = 2;
const N_STATUS = 2 + VISIBLE;
const N_ADD = N_STATUS + 1;
const N_TOGGLE = N_ADD + 1;
const N_DELETE = N_TOGGLE + 1;
const N_SAVE = N_DELETE + 1;
const N_UP = N_SAVE + 1;
const N_DOWN = N_UP + 1;
const N_QUIT = N_DOWN + 1;

const MyApp = gemz.App(1, TOTAL);

// ---------------------------------------------------------------------------
// Mutable state (module-level so the object tree + handlers can reach it)
// ---------------------------------------------------------------------------

const Item = extern struct {
    done: u8, // 'D' = done, 'T' = todo
    text: [TEXT_LEN]u8,
};

var items: [MAX_ITEMS]Item = [_]Item{.{ .done = 'T', .text = [_]u8{0} ** TEXT_LEN }} ** MAX_ITEMS;
var item_count: u16 = 0;
var cursor: u16 = 0; // selected item index
var scroll: u16 = 0; // first visible item index

var line_buf: [VISIBLE * LINE_LEN]u8 = [_]u8{0} ** (VISIBLE * LINE_LEN);
var status_buf: [STATUS_LEN]u8 = [_]u8{0} ** STATUS_LEN;

const HEADER_TED = gemz.TedInfo.from("  TODO — ATARI GEM", .blue);
const STATUS_TED = gemz.TedInfo{ .ptext = @ptrCast(&status_buf), .color = gemz.textColor(.magenta) };

// One TEDINFO per visible row; its colour is rewritten at render time so done
// items are green, the selected item is red, and the rest are black.
var line_ted: [VISIBLE]gemz.TedInfo = blk: {
    var arr: [VISIBLE]gemz.TedInfo = undefined;
    for (0..VISIBLE) |row| {
        arr[row] = gemz.TedInfo{ .ptext = @ptrCast(&line_buf[row * LINE_LEN]) };
    }
    break :blk arr;
};

// ---------------------------------------------------------------------------
// Safe global-state helpers
// ---------------------------------------------------------------------------

fn setCount(v: u16) void {
    gemz.storeWord(@intFromPtr(&item_count), v);
}

fn setCursor(v: u16) void {
    gemz.storeWord(@intFromPtr(&cursor), v);
}

fn setScroll(v: u16) void {
    gemz.storeWord(@intFromPtr(&scroll), v);
}

/// Read the mutable globals through `noinline` functions so the backend loads
/// them into a register (`move.w (d16,PC),dN` — legal) rather than emitting
/// the illegal `cmpi.w #imm,(d16,PC)` direct-compare-on-memory form.
noinline fn getCount() u16 {
    return item_count;
}

noinline fn getCursor() u16 {
    return cursor;
}

noinline fn getScroll() u16 {
    return scroll;
}

/// Address of `items[idx]`, walked with pointer arithmetic so the m68k backend
/// never has to multiply a 32-bit index by `sizeof(Item)`.
fn itemAddr(idx: u16) usize {
    var p: [*]Item = &items;
    var i: u16 = 0;
    while (i < idx) : (i += 1) p += 1;
    return @intFromPtr(p);
}

fn itemDone(idx: u16) u8 {
    const p: [*]const u8 = @ptrFromInt(itemAddr(idx));
    return p[0];
}

fn itemText(idx: u16, pos: usize) u8 {
    const p: [*]const u8 = @ptrFromInt(itemAddr(idx) + 1 + pos);
    return p[0];
}

fn copyItem(dst: u16, src: u16) void {
    gemz.storeByte(itemAddr(dst) + 0, itemDone(src));
    var t: usize = 0;
    while (t < TEXT_LEN) : (t += 1) {
        gemz.storeByte(itemAddr(dst) + 1 + t, itemText(src, t));
    }
}

fn colorWord(color: gemz.Color) u16 {
    return @bitCast(gemz.textColor(color));
}

/// Write `s` into a global byte buffer starting at `dst + off`. Returns the new
/// offset.
fn writeText(dst: usize, off: usize, s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        gemz.storeByte(dst + off + i, s[i]);
    }
    return off + s.len;
}

/// Write a decimal `v` into a global byte buffer at `dst + off`. Returns the new
/// offset.
fn writeDec(dst: usize, off: usize, v: u16) usize {
    var digits: [5]u8 = undefined;
    var p: [*]u8 = &digits;
    var n: usize = 0;
    var x: u16 = v;
    if (x == 0) {
        gemz.storeByte(dst + off, '0');
        return off + 1;
    }
    while (x != 0) {
        p[0] = '0' + @as(u8, @intCast(x % 10));
        p += 1;
        n += 1;
        x = x / 10;
    }
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        gemz.storeByte(dst + off + (n - 1 - i), digits[i]);
    }
    return off + n;
}

/// Keep the cursor inside the visible window.
fn clampScroll() void {
    const count = getCount();
    const cur = getCursor();
    const scr = getScroll();
    if (count == 0) {
        setScroll(0);
        return;
    }
    if (cur < scr) setScroll(cur);
    if (cur > scr + VISIBLE - 1) setScroll(cur - (VISIBLE - 1));
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn loadDb() void {
    const h = gemz.fopen("TODO.db", 0);
    if (h < 0) return;

    var buf: [FILE_CAP]u8 = undefined;
    const n = gemz.fread(h, &buf, FILE_CAP);
    _ = gemz.fclose(h);
    if (n < 1) return;

    setCount(0);
    var wp: [*]Item = &items;
    var i: usize = 0;
    const total: usize = @intCast(n);

    while (i < total and getCount() < MAX_ITEMS) {
        const sentinel = buf[i];
        i += 1;

        if (sentinel == 'D' or sentinel == 'T') {
            const addr = @intFromPtr(wp);
            gemz.storeByte(addr + 0, sentinel);
            var t: usize = 0;
            while (i < total and buf[i] != '\n' and buf[i] != '\r' and t < TEXT_LEN - 1) {
                gemz.storeByte(addr + 1 + t, buf[i]);
                i += 1;
                t += 1;
            }
            gemz.storeByte(addr + 1 + t, 0);
            wp += 1;
            setCount(getCount() + 1);
        }

        // Skip the rest of this line (whether or not it was a valid item).
        while (i < total and buf[i] != '\n' and buf[i] != '\r') i += 1;
        while (i < total and (buf[i] == '\n' or buf[i] == '\r')) i += 1;
    }
}

fn saveDb() void {
    var buf: [FILE_CAP]u8 = undefined;
    var p: [*]u8 = &buf;
    var ip: [*]Item = &items;
    var i: usize = 0;

    while (i < getCount()) : (i += 1) {
        p[0] = ip[0].done;
        p += 1;
        var t: usize = 0;
        while (t < TEXT_LEN - 1 and ip[0].text[t] != 0) : (t += 1) {
            p[0] = ip[0].text[t];
            p += 1;
        }
        p[0] = '\n';
        p += 1;
        ip += 1;
    }

    const len: u32 = @intCast(@intFromPtr(p) - @intFromPtr(&buf));
    const h = gemz.fcreate("TODO.db");
    if (h < 0) return;
    _ = gemz.fwrite(h, &buf, len);
    _ = gemz.fclose(h);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn render(app: *MyApp) void {
    clampScroll();

    var lp: [*]u8 = &line_buf;
    var tp: [*]gemz.TedInfo = &line_ted;
    var ip: [*]Item = &items;
    var si: u16 = 0;
    while (si < getScroll()) : (si += 1) ip += 1;

    var row: usize = 0;
    while (row < VISIBLE) : (row += 1) {
        const base = @intFromPtr(lp);
        if (si < getCount()) {
            const done = ip[0].done == 'D';
            const selected = si == getCursor();

            gemz.storeByte(base + 0, if (selected) '>' else ' ');
            gemz.storeByte(base + 1, '[');
            gemz.storeByte(base + 2, if (done) 'X' else ' ');
            gemz.storeByte(base + 3, ']');
            gemz.storeByte(base + 4, ' ');

            var t: usize = 0;
            while (t < TEXT_LEN - 1 and ip[0].text[t] != 0) : (t += 1) {
                gemz.storeByte(base + 5 + t, ip[0].text[t]);
            }
            gemz.storeByte(base + 5 + t, 0);

            const color = if (selected) gemz.Color.red else if (done) gemz.Color.green else gemz.Color.black;
            gemz.storeWord(@intFromPtr(tp) + @offsetOf(gemz.TedInfo, "color"), colorWord(color));
        } else {
            gemz.storeByte(base + 0, 0);
            gemz.storeWord(@intFromPtr(tp) + @offsetOf(gemz.TedInfo, "color"), colorWord(.black));
        }

        lp += LINE_LEN;
        tp += 1;
        ip += 1;
        si += 1;
    }

    // Status line: task + done counts and the selected index.
    var dp: [*]Item = &items;
    var done: u16 = 0;
    var i: usize = 0;
    while (i < getCount()) : (i += 1) {
        if (dp[0].done == 'D') done += 1;
        dp += 1;
    }

    const sb = @intFromPtr(&status_buf);
    var off: usize = 0;
    off = writeText(sb, off, "TASKS ");
    off = writeDec(sb, off, getCount());
    off = writeText(sb, off, "   DONE ");
    off = writeDec(sb, off, done);
    off = writeText(sb, off, "   SEL ");
    off = writeDec(sb, off, if (getCount() == 0) 0 else getCursor() + 1);
    gemz.storeByte(sb + off, 0);

    app.redraw();
}

// ---------------------------------------------------------------------------
// Click handlers
// ---------------------------------------------------------------------------

fn addClicked(app: *MyApp) bool {
    if (getCount() > MAX_ITEMS - 1) {
        app.form_alert(.default_button, "TODO list is full");
        return true;
    }

    var input: [TEXT_LEN]u8 = undefined;
    input[0] = 0;
    if (!gemz.formInput("New task:", &input, TEXT_LEN)) return true;

    const idx = getCount();
    gemz.storeByte(itemAddr(idx) + 0, 'T');
    var t: usize = 0;
    while (t < TEXT_LEN - 1 and input[t] != 0) : (t += 1) {
        gemz.storeByte(itemAddr(idx) + 1 + t, input[t]);
    }
    gemz.storeByte(itemAddr(idx) + 1 + t, 0);

    setCount(idx + 1);
    setCursor(idx);
    clampScroll();
    render(app);
    saveDb();
    return true;
}

fn toggleClicked(app: *MyApp) bool {
    if (getCount() == 0) return true;
    const idx = getCursor();
    const done = itemDone(idx);
    gemz.storeByte(itemAddr(idx) + 0, if (done == 'D') 'T' else 'D');
    render(app);
    saveDb();
    return true;
}

fn deleteClicked(app: *MyApp) bool {
    if (getCount() == 0) return true;
    const idx = getCursor();
    var i: u16 = idx;
    while (i + 1 < getCount()) : (i += 1) {
        copyItem(i, i + 1);
    }
    setCount(getCount() - 1);
    if (getCount() == 0) {
        setCursor(0);
    } else if (getCursor() > getCount() - 1) {
        setCursor(getCount() - 1);
    }
    clampScroll();
    render(app);
    saveDb();
    return true;
}

fn saveClicked(app: *MyApp) bool {
    saveDb();
    app.form_alert(.default_button, "Saved TODO.db");
    return true;
}

fn upClicked(app: *MyApp) bool {
    if (getCursor() > 0) setCursor(getCursor() - 1);
    clampScroll();
    render(app);
    return true;
}

fn downClicked(app: *MyApp) bool {
    if (getCount() == 0) return true;
    if (getCursor() < getCount() - 1) setCursor(getCursor() + 1);
    clampScroll();
    render(app);
    return true;
}

fn quitClicked(_: *MyApp) bool {
    return false;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var app = try MyApp.init();
    defer app.exit();

    loadDb();
    setCursor(0);
    setScroll(0);

    const nodes = comptime blk: {
        var arr: [TOTAL]MyApp.Node = undefined;
        arr[0] = MyApp.Node.box(WIN_W, WIN_H);
        arr[N_HEADER] = MyApp.Node.textTed(&HEADER_TED, 8, 8, 360, 20);
        for (0..VISIBLE) |row| {
            arr[N_LINE0 + row] = MyApp.Node.textTed(
                &line_ted[row],
                LIST_X,
                LIST_Y + @as(i16, @intCast(row * LINE_H)),
                LIST_W,
                LINE_H,
            );
        }
        arr[N_STATUS] = MyApp.Node.textTed(&STATUS_TED, 8, 224, 360, 20);
        arr[N_ADD] = MyApp.Node.button(" Add ", 8, 250, 80, 24, .selectable, &.{.{ .click = addClicked }});
        arr[N_TOGGLE] = MyApp.Node.button(" Toggle ", 96, 250, 84, 24, .selectable, &.{.{ .click = toggleClicked }});
        arr[N_DELETE] = MyApp.Node.button(" Delete ", 188, 250, 84, 24, .selectable, &.{.{ .click = deleteClicked }});
        arr[N_SAVE] = MyApp.Node.button(" Save ", 280, 250, 80, 24, .selectable, &.{.{ .click = saveClicked }});
        arr[N_UP] = MyApp.Node.button(" Up ", 8, 284, 80, 24, .selectable, &.{.{ .click = upClicked }});
        arr[N_DOWN] = MyApp.Node.button(" Down ", 96, 284, 80, 24, .selectable, &.{.{ .click = downClicked }});
        arr[N_QUIT] = MyApp.Node.button(" Quit ", 280, 284, 80, 24, .flags(&.{ .selectable, .exit }), &.{.{ .click = quitClicked }});
        break :blk arr;
    };

    try app.open(.{
        .kind = .{ .name = true, .closer = true, .mover = true, .sizer = true },
        .title = "TODO",
        .x = 40,
        .y = 30,
        .w = WIN_W,
        .h = WIN_H,
    }, &nodes);

    render(&app);
    app.run();
}
