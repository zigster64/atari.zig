// GEM "Hello World" for Atari TOS / EmuTOS — m68k, freestanding, no std lib.
// Inline asm follows the LLVM m68k GAS dialect (%%registers, no CLR).
// Patterns informed by DominoTree/modern-m68k-toolchains.

// ── AES parameter block (trap #2, d0 = 0xC8) ─────────────────────────────

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

// aes_trap: dispatch an AES call. d0 = 0xC8 identifies XGEMDOS, d1 = pb ptr.
fn aes_trap(pb: *const AesPb) void {
    asm volatile (
        \\move.l %[pb], %%d1
        \\move.w #0xc8, %%d0
        \\trap #2
        :
        : [pb] "r" (pb),
        : .{ .memory = true });
}

// Build a parameter block on the stack and dispatch. Returns int_out[0].
fn aes_call(opcode: u16, int_in: []const i16, addr_in: []const ?[*]const u8, n_out: u16) i16 {
    var control = AesControl{
        .opcode = opcode,
        .n_int_in = @intCast(int_in.len),
        .n_int_out = n_out,
        .n_addr_in = @intCast(addr_in.len),
        .n_addr_out = 0,
    };
    var int_out: [7]i16 = .{0} ** 7;
    var addr_out: [1]?[*]u8 = .{null};

    const pb = AesPb{
        .control = &control,
        .global = &GLOBAL,
        .int_in = if (int_in.len == 0) null else int_in.ptr,
        .int_out = &int_out,
        .addr_in = if (addr_in.len == 0) null else addr_in.ptr,
        .addr_out = &addr_out,
    };

    aes_trap(&pb);
    return int_out[0];
}

// AES populates app_id in global at appl_init; must persist across app lifetime.
var GLOBAL: AesGlobal = .{
    .version = 0,
    .app_max = 0,
    .app_id = 0,
    .user = 0,
    .rsc = null,
    .reserved = .{0} ** 4,
};

// ── GEM helper wrappers ───────────────────────────────────────────────────

fn appl_init() i16 {
    return aes_call(10, &.{}, &.{}, 1);
}

fn appl_exit() void {
    _ = aes_call(19, &.{}, &.{}, 1);
}

fn wind_create(kind: i16, x: i16, y: i16, w: i16, h: i16) i16 {
    const int_in = [_]i16{ kind, x, y, w, h };
    return aes_call(100, &int_in, &.{}, 1);
}

fn wind_open(handle: i16, x: i16, y: i16, w: i16, h: i16) void {
    const int_in = [_]i16{ handle, x, y, w, h };
    _ = aes_call(101, &int_in, &.{}, 1);
}

fn wind_close(handle: i16) void {
    const int_in = [_]i16{handle};
    _ = aes_call(102, &int_in, &.{}, 1);
}

fn wind_delete(handle: i16) void {
    const int_in = [_]i16{handle};
    _ = aes_call(103, &int_in, &.{}, 1);
}

fn wind_set_str(handle: i16, field: i16, s: [*:0]const u8) void {
    const int_in = [_]i16{ handle, field };
    const addr_in = [_]?[*]const u8{@ptrCast(s)};
    _ = aes_call(105, &int_in, &addr_in, 1);
}

fn evnt_mesag() i16 {
    const int_in = [_]i16{0x0010} ** 16;
    const addr_in = [_]?[*]const u8{null};
    return aes_call(25, &int_in, &addr_in, 7);
}

// ── Pterm0 — clean exit via GEMDOS trap #1 ───────────────────────────────

fn pterm0() noreturn {
    asm volatile (
        \\move.w #0, -(%%sp)
        \\trap #1
        ::: .{ .memory = true });
    unreachable;
}

// ── Entry point ───────────────────────────────────────────────────────────

export fn _start() callconv(.c) noreturn {
    const ap_id = appl_init();
    if (ap_id < 0) {
        pterm0();
    }

    const NAME: i16 = 0x0001;
    const CLOSE: i16 = 0x0002;
    const MOVER: i16 = 0x0004;
    const kind = NAME | CLOSE | MOVER;

    const handle = wind_create(kind, 50, 50, 300, 150);
    if (handle > 0) {
        wind_set_str(handle, 2, "Zig 0.16 on m68k GEM");
        wind_open(handle, 50, 50, 300, 150);
        _ = evnt_mesag();   // wait for user to click close or quit
        wind_close(handle);
        wind_delete(handle);
    }

    appl_exit();
    pterm0();
}

// ── Required stubs (LLVM / compiler-rt may emit calls to these) ───────────

export fn abort() noreturn {
    pterm0();
}

export fn memset(dest: [*]u8, c: i32, n: usize) [*]u8 {
    var i: usize = 0;
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    while (i < n) : (i += 1) dest[i] = byte;
    return dest;
}
