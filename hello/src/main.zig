// main.zig - GEM Windowed "Hello World" in Pure Freestanding Zig (Zig 0.16)

// --- GEM / System Data Structures ---
const ControlArray = [5]i16;
const IntInArray = [16]i16;
const IntOutArray = [16]i16;
const AddrInArray = [16]?*const anyopaque;
const AddrOutArray = [16]?*const anyopaque;

const AESBlock = extern struct {
    control: *ControlArray,
    global: *[15]i16,
    intin: *IntInArray,
    intout: *IntOutArray,
    addrin: *AddrInArray,
    addrout: *AddrOutArray,
};

// Application state globals
var aes_control: ControlArray = undefined;
var aes_global: [15]i16 = undefined;
var aes_intin: IntInArray = undefined;
var aes_intout: IntOutArray = undefined;
var aes_addrin: AddrInArray = undefined;
var aes_addrout: AddrOutArray = undefined;

var aes_pb = AESBlock{
    .control = &aes_control,
    .global = &aes_global,
    .intin = &aes_intin,
    .intout = &aes_intout,
    .addrin = &aes_addrin,
    .addrout = &aes_addrout,
};

// --- Low-Level AES Trap #2 Invocation ---
//
fn aesCall(opcode: i16, num_intin: i16, num_intout: i16, num_addrin: i16) void {
    aes_control[0] = opcode;
    aes_control[1] = num_intin;
    aes_control[2] = num_intout;
    aes_control[3] = num_addrin;
    aes_control[4] = 0;

    asm volatile (
        \\ move.l %[pb], %d1      ; Pass AES parameter block pointer in D1
        \\ move.w #200, %d0      ; Opcode 200 (0xC8) = AES Trap
        \\ trap #2               ; Execute GEM Trap #2
        :
        : [pb] "r" (&aes_pb),
        : .{
          .d0 = true,
          .d1 = true,
          .d2 = true,
          .a0 = true,
          .a1 = true,
          .a2 = true,
          .memory = true,
        });
}

fn pterm0() noreturn {
    asm volatile (
        \\ clr.w -(%sp)
        \\ trap #1              ; GEMDOS Pterm0 exit
        ::: .{ .memory = true });
    while (true) {}
}
// --- GEM Helper Bindings ---
fn applInit() i16 {
    aesCall(10, 0, 1, 0); // appl_init
    return aes_intout[0];
}

fn applExit() void {
    aesCall(19, 0, 1, 0); // appl_exit
}

fn windCreate(kind: i16, x: i16, y: i16, w: i16, h: i16) i16 {
    aes_intin[0] = kind;
    aes_intin[1] = x;
    aes_intin[2] = y;
    aes_intin[3] = w;
    aes_intin[4] = h;
    aesCall(100, 5, 1, 0); // wind_create
    return aes_intout[0];
}

fn windOpen(handle: i16, x: i16, y: i16, w: i16, h: i16) void {
    aes_intin[0] = handle;
    aes_intin[1] = x;
    aes_intin[2] = y;
    aes_intin[3] = w;
    aes_intin[4] = h;
    aesCall(101, 5, 1, 0); // wind_open
}

fn windSetTitle(handle: i16, title: [*:0]const u8) void {
    aes_intin[0] = handle;
    aes_intin[1] = 2; // WF_NAME
    aes_addrin[0] = title;
    aesCall(105, 2, 1, 1); // wind_set
}

fn windDelete(handle: i16) void {
    aes_intin[0] = handle;
    aesCall(103, 1, 1, 0); // wind_delete
}

fn evntMulti() i16 {
    // Wait for message events (like window close clicks)
    aes_intin[0] = 0x0010; // MU_MESAG
    aesCall(25, 16, 7, 1); // evnt_multi
    return aes_intout[0];
}

// --- Freestanding Entry Point ---
export fn _start() callconv(.c) noreturn {
    const ap_id = applInit();
    if (ap_id >= 0) {
        // Window Components: Name Bar + Close Box + Move Handle
        const NAME = 0x0001;
        const CLOSE = 0x0002;
        const MOVE = 0x0004;
        const window_kind = NAME | CLOSE | MOVE;

        // Create window frame at X:50, Y:50, W:300, H:150
        const handle = windCreate(window_kind, 50, 50, 300, 150);
        if (handle > 0) {
            windSetTitle(handle, "Zig 0.16 GEM Window");
            windOpen(handle, 50, 50, 300, 150);

            // Wait for user interaction
            _ = evntMulti();

            windDelete(handle);
        }

        applExit();
    }

    pterm0();
}
