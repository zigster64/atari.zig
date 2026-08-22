# m68k backend fragility — notes & workarounds

The m68k codegen in this toolchain is fragile. Several ordinary Zig code
shapes compile to *wrong machine code* even though the Zig IR is correct.
These notes record the failure modes we have actually hit, the patterns that
have survived, and how to verify a build before trusting it.

## Toolchain

- Compiler: `~/Atari/bin/zig` — Zig 0.16 with LLVM 21, m68k backend enabled.
- Target: `m68k-freestanding-none`.
- Build:

  ```sh
  cd ~/Atari/GEMZ
  ZIG_GLOBAL_CACHE_DIR=/Users/steve/Atari/.zig-cache-global ~/Atari/bin/zig build
  ```

- Output: `zig-out/atari/DAF.PRG` (the build also copies it to
  `~/Atari/CDrive/GEMZ/DAF.PRG`).
- Disassemble the shipped PRG:

  ```sh
  m68k-elf-objdump -b binary -m m68k --adjust-vma=0 -D zig-out/atari/DAF.PRG
  ```

  Relocatable `jsr`/`lea` targets in that dump are pre-relocation placeholders;
  PC-relative **branches** (`beq`, `bne`, `bccs`, …) are final and safe to read
  directly.

## Where the bugs live

These are **LLVM m68k backend** codegen bugs, not a Zig frontend bug and not a
`build.zig`/linker issue. Zig emits correct IR; the m68k lowering drops a value
or swaps a branch. There is no clean build-layer flag that fixes them — the
pragmatic mitigation is the source-level workarounds below, plus disassembly
verification. (Trying `-O Debug` vs `ReleaseFast` vs `ReleaseSmall` is worth a
shot if one specific pattern will not stop miscompiling, since a given
optimization pass may or may not trigger the bug.)

---

## Golden rule

**Do not carry a runtime pointer or offset around a loop.** Prefer
comptime-fixed addresses, or pass a stable pointer into a leaf function.

---

## Failure modes (verified)

### 1. Runtime `for` over an array drops the running element

```zig
// BROKEN
for (&self.music, 0..) |*t, ch| {
    // uses t.active, t.remaining, ...
}
```

Symptom: the loop advances a stride counter (`d4 += 144`), but then recomputes
the base (`lea self+524`) every iteration and never adds the counter. Result:
every iteration operates on `music[0]`. This is exactly what made channel B/C
stay armed but never step (the "kick = continuous noise" bug).

Fix — remove the runtime loop. Unroll with a comptime index so each access is a
fixed offset:

```zig
fn stepMusic(self: *Self, elapsed: u16) void {
    var rep_wrapped = self.stepTrack(0, elapsed);
    rep_wrapped = self.stepTrack(1, elapsed) or rep_wrapped;
    rep_wrapped = self.stepTrack(2, elapsed) or rep_wrapped;
}

fn stepTrack(self: *Self, comptime ch: usize, elapsed: u16) bool {
    const t = &self.music[ch];   // comptime ch -> fixed offset
    // ...
}
```

Also fix `anyMusicActive` the same way:

```zig
return self.music[0].active or self.music[1].active or self.music[2].active;
```

### 2. Runtime `while` parser with indexed stores + `continue` runs away

The original `parseNotes` (`while (i < src.len and count < max_notes)`, with
`continue` paths and `out.notes[out.count] = ...`) was compiled so the
loop-bound reload was skipped on `continue`. The string index ran past the
buffer and bus-errored.

Fix — force comptime evaluation. The parser only ever runs on comptime strings,
so bake the result:

```zig
t.* = comptime parseNotes(notes);
```

Comptime code runs on the host (x86_64) compiler, which is not affected by the
m68k bugs.

### 3. `>=` comparison swaps branch targets

```zig
// BROKEN
if (v >= drum_kick) { drum path } else { tone path }
```

Symptom: the two arms end up in the opposite order in the machine code.

Fix — invert to `<` with the tone path first:

```zig
if (v < drum_kick) { tone path } else { drum path }
```

Verified marker: correct dispatch shows `subw #-16` (i.e. `v - 0xFFF0`), not
`subw #-17`.

### 4. Indexed byte access to a **local/stack array** can drop the index register

```zig
// RISKY (read OR write)
var digits: [5]u8 = undefined;
digits[i] = c;        // store can drop `i`
const c = digits[i];  // read can drop `i` too
```

Symptom: every access touches the same fixed slot (e.g. `sp+2`/`sp+3`) instead of
`base + i`. This bit `todo.zig` in `writeDec` (`digits[i]` read) and `loadDb`
(`buf[i]` reads), producing garbled status text and item data.

Fix — use a `[*]u8` many-pointer and pointer arithmetic, never `arr[i]`:

```zig
var p: [*]u8 = &digits;
p[0] = c;   // write
p += 1;
// read: p[0], then p += 1
```

Slices (`s[i]` on a `[]const u8`) appear to be safe (the pointer+index form),
but a stack array (`arr[i]` on a `[N]u8`) is not. Prefer the pointer walk for
both. (`songMixer` was also rewritten from `tone[ci] = …` to a scalar
`mixer &= ~(1 << bit)` fold.)

### 5. `u32 * u32` (resolved: `__mulsi3` is now provided)

Originally a 32-bit multiply failed to link because `-fno-compiler-rt` left
`__mulsi3` undefined. GEMZ now ships a 68000-safe shift-and-add `__mulsi3`
(`export fn __mulsi3(a: u32, b: u32) u32`), so `u32 * u32` links and works.

It is still a runtime helper call, not a hardware multiply, so keep using
shifts for the hot doubling/halving paths (`<< 1` / `>> 1`) where it matters.

### 6. Comptime recursion + `inline for` over a struct array → dead code

A previous rep-scheduling attempt (`findPart`, `packSchedule`, `advanceSchedule`,
`applySched`) compiled to dead code — the rep counter never incremented and the
apply function was never called.

Fix — keep comptime recursion simple (the current `armRep` / `stopRep` form
works), and prefer explicit calls over `inline for` when struct-field stores are
involved. Disassemble to confirm the code is actually present.

### 7. Byte store to a **global** buffer → illegal PC-relative destination

```zig
// BROKEN (compiles, then bus-errors / corrupts memory)
var buf: [6]u8 = ...;
var ptr: *[6]u8 = undefined;   // even a runtime-loaded pointer
fn write() void {
    const b = ptr;             // LLVM folds this back to &buf
    b[0] = 'x';                // and emits: move.b Dn,(d16,PC)
}
```

`move.b Dn,(d16,PC)` is not a legal m68k MOVE destination (PC-relative
addressing is read-only). The backend still emits it for byte/word/long stores
to a global symbol, even when the address arrives through a runtime pointer or a
`@volatileCast` load — LLVM constant-folds the pointer back to the global.

The same bug also hits **immediate stores**: `move.{b,w,l} #imm, global` is
misencoded as the PC-relative form. The verified example is `0x31FC → 0x35FC`
(`move.w #0,(xxx).W` became `move.w -(sp),(d16,PC)`), which crashed
`counter.zig` at startup because `main`'s `count = 0` executed the illegal
instruction immediately.

Detection: the broken opcode families are `0x15C0-0x15FF` (byte),
`0x35C0-0x35FF` (word), `0x25C0-0x25FF` (long) — the destination mode nibble is
`c-f`, i.e. `move.{b,w,l} …, (d16,PC)`:

```sh
m68k-elf-objdump -b binary -m m68k --adjust-vma=0 -D zig-out/atari/MYAPP.PRG \
  | grep -cE '\.short 0x(15|25|35)[c-f][0-9a-f]'
# want 0
```

Note: an earlier pattern (`0x(15c|35c|25c)`) is **wrong** — it only matches the
`c0-cf` sub-range and missed `0x35fc`, the exact encoding that crashed the
counter. Also, object-tree data in `.rodata` can contain these byte patterns as
ordinary data (e.g. `0x0015` = `G_TEXT`), so scope the grep to the **text
section**: text starts at file offset 28 and its length is the big-endian
32-bit word at PRG offset 2. Then:

```sh
TEXT_LEN=$((16#$(xxd -p -s 2 -l 4 -r zig-out/atari/MYAPP.PRG | xxd -p)))
xxd -p -s 28 -l $TEXT_LEN zig-out/atari/MYAPP.PRG > /tmp/text.bin
m68k-elf-objdump -b binary -m m68k --adjust-vma=0 -D /tmp/text.bin \
  | grep -cE '\.short 0x(15|25|35)[c-f][0-9a-f]'
# want 0
```

For reference, GNU `m68k-elf-as` encodes a valid byte store as `1543 0f86`
(`move.b %d3,(0x0f86,%a2)`); the backend's broken form is `15c3 ...` — bit 7 of
the first word turns the destination mode `101` (`(d16,An)`) into `111`
(`(d16,PC)`).

Fix — write the bytes through **inline assembly** so the backend cannot
constant-fold the destination (`gemz.storeByte` / `gemz.storeWord`):

```zig
inline fn storeByte(dest: usize, value: u8) void {
    asm volatile (
        \\move.l %[dest], %%a0
        \\move.b %[value], (%%a0)
        :
        : [dest] "d" (dest),
          [value] "d" (value),
        : .{ .memory = true, .a0 = true }
    );
}
```

This is how `counter.zig` writes the live number into its global TEDINFO text
buffer. A `@volatileCast(&ptr).*` load alone is **not** enough — it still gets
folded. Verify with the grep above after every change.

### 8. Global compare → illegal `cmpi.{b,w,l} #imm,(d16,PC)`

```zig
// BROKEN (compiles, then "Illegal Instruction")
var count: u16 = 0;
fn f() void {
    if (count == 0) return;   // lowered to: cmpi.w #0,(d16,PC)
}
```

The m68k `CMPI` instruction does **not** allow PC-relative addressing for its
effective address (it needs Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn),
(xxx).W or (xxx).L). The backend emits `cmpi.w #imm,(d16,PC)` for a direct
compare against a mutable global, which is an illegal instruction on a 68000.

Detection: objdump shows `.short 0x0c3a` (byte), `.short 0x0c7a` (word) or
`.short 0x0cba` (long) — the `CMPI` + `(d16,PC)` opcodes (also the
`(d8,PC,Xn)`/`#imm` variants `0x…3b`/`0x…3c`):

```sh
m68k-elf-objdump -b binary -m m68k --adjust-vma=0 -D /tmp/text.bin \
  | grep -cE '\.short 0x0c(3|7|b)[abc]'
# want 0
```

Fix — force the global into a register before comparing. A `noinline` getter
works and survives optimization:

```zig
noinline fn getCount() u16 { return count; }   // -> move.w (d16,PC),d0 ; rts
fn f() void {
    if (getCount() == 0) return;               // -> cmp.w #0,d0 (legal)
}
```

This bit `todo.zig` in `clampScroll` (`if (item_count == 0)`), which is why the
app crashed with an illegal instruction after `loadDb`.

---

### 11. toslink PC-relative displacement over the 32 KB signed boundary (large .bss)

A PC-relative reference (`lea (d16,PC),An` / `R_68K_PC16`) to a symbol whose
**offset from the instruction exceeds `0x7FFF`** gets resolved by toslink into a
16-bit displacement that the 68000 then interprets as **signed negative** at
runtime. The reference lands ~64 KB before the real symbol.

Symptom (verified in `GFX.PRG`): the app's fill wrote over the TPA and its own
`.text`, producing `Panic: Illegal Instruction` / `Panic: Line F Emulator` —
with the panic PC either inside `.text` or 2 bytes into an instruction, and the
corrupted bytes being framebuffer data (`ff ff 00 00`) at the crash site. The
fill's base register read `0x18500` instead of `0x28500` (exactly `0x10000`
off). This only appears once a program's `.bss` is large enough for a symbol
past the 32 KB boundary — the two 32 KB framebuffers in `screen.zig`
(`gfx_buf_b` at `.bss + 0x7E00`) were the first such case; all earlier apps
had small `.bss` and never hit it.

Fix — derive far addresses by **addition from a near symbol**, so no second
PC-relative reference crosses the boundary:

```zig
const a = (@intFromPtr(&gfx_buf_a) + 255) & ~@as(usize, 255); // near: .bss + 0
const b = a + screen_bytes + 256; // derived, not referenced: .bss + 0x7E00
```

Detection — inspect the ELF's relocations before linking:

```sh
m68k-elf-readelf -r zig-out/atari/MYAPP.elf | grep R_68K_PC16
# any row with a symbol offset near or past 0x8000 is suspect
```

### 12. Runtime `select` compiles to an inverted test (`seq`/`negb`)

`p[0] = if ((color & bit) != 0) 0xFF else 0x00;` compiled to a `btst` +
`seq` + `andb #1` + `negb` sequence that **inverted** the test: set bit → `0x00`,
clear bit → `0xFF`. Verified: `clear(.cyan)` (colour 5, planes 0+2) filled
planes 1+3 instead — the framebuffer held colour index 10, not 5.

Fix — compute the select result at comptime and look it up:

```zig
const FILL_PLANE_BYTES = blk: {
    var t: [64]u8 = undefined;
    for (0..16) |c| for (0..4) |plane|
        t[c * 4 + plane] = if ((c & (@as(u8, 1) << @intCast(plane))) != 0) 0xFF else 0x00;
    break :blk t;
};
// ... p[0] = FILL_PLANE_BYTES[(color << 2) | plane];
```

Detection — in the disassembly, a colour fill should show `btst` + `sne`
(not `seq`) followed by `negb`; `seq` here means inverted.

### 13. Indexed byte store is pathologically slow in Hatari's UAE core

`move.b (d16,An,Xn),(d16,An,Xn)` (a double-indexed byte store, which the
compiler strength-reduces `p[0] = v; p += 1` into) ran at ~1900 cycles/byte in
Hatari — a 32 KB fill took **10+ seconds** instead of ~300 ms, making the app
look hung (the display only updated once per pass). The same shape is the
documented risk for dropped index registers (see item 4).

Fix — write through `gemz.storeByte` (inline asm, plain `(a0)` destination):

```zig
// loop body: gemz.storeByte(base + i, value);  // move.l dest,a0; move.b v,(a0)
```

The same applies to indexed byte READS (`moveb (d16,An,Xn.l),dn`) — the fill's
table lookup made a 32 KB clear take ~10 s. An arithmetic fill (`0 -%
((color >> plane) & 1)` → `lsrb`/`andb`/`negb`) avoids the read.

**Design implication (verified):** even the arithmetic fill costs ~0.5-2 s per
32 KB pass in this environment (the UAE core charges ~4x the 68000 cycle
count). A per-frame full-screen clear therefore caps the app at ~1 fps — the
game must use targeted rendering (dirty rectangles / draw-over), not
full-screen clears, in its hot loop. A one-shot clear + hold (as the M1 probe
does) is fine.

The same indexed-store bug lurks in the runtime `memcpy`/`memmove` stubs
(LLVM lowers large struct returns, e.g. a 58-byte `Gfx`, to a `memcpy` call):
the old `dest[i] = src[i]` form shifted the copy by 0x14 bytes and corrupted
the caller's `.text`. They now write via `gemz.storeByte` and walk the source
with a many-pointer.

### 15. The ST palette registers are write-only; there is NO XBIOS Getpalette

XBIOS 6 is `Setpalette` (write all 16), XBIOS 7 is `Setcolor` (write ONE
colour) — there is no way to READ the palette via XBIOS, and reading the
Shifter registers (`$FF8240-$FF825E`) directly from user mode **bus-errors**
in this Hatari/EmuTOS setup (verified). So a fullscreen app cannot save and
restore the desktop's palette.

**Design consequence:** don't install a palette at all — make the app use the
desktop's palette. `gemz.Color` is defined to match the EmuTOS desktop palette
(0 white, 1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan, 7 grey,
8-14 dark variants, 15 black), so the game's colours work with the desktop's
palette and there is nothing to restore on exit.

### 14. Struct-field front/back swap folded away when inlined (double buffering)

The `flip()` swap (`tmp = front; front = back; back = tmp;`) compiled to
dead code when inlined into the frame loop — the emitted loop always used
buffer B and never alternated (silent single-buffer degradation, no crash).

Fix — `pub noinline fn flip(...)` keeps the swap as a real field exchange:
verified in the disassembly (`movel a0@(12),d3; movel a0@(8),a0@(12);
movel d3,a0@(8)`).

### 16. Multi-branch wrapper around several `noinline` fills miscompiles

A "clear/fill at any resolution" dispatch — one function with a branch per
resolution, each branch calling a different `noinline` fill with a different
register signature — miscompiled on the m68k backend (GFX demo, med phase).
The `.medium` branch called `fillMediumRow` instead of `clearMedium`, and the
branches passed arguments in registers the callees didn't expect (the fills
take `d0` = base, `d1` = y, `a0` = colour; the wrapper passed a different
layout), so fills wrote to garbage addresses. Symptom: `Panic: Address Error`
in the TOS VBL with a corrupted stack pointer, then a silent machine reset.

Fix — **branch at the call site** (in the demo's own loop: `if (rez == .low)
... else if (rez == .medium) ...`) and call the resolution-specific fill
directly. No shared dispatch function, ever.

### 17. Rez 2 (mono) needs a mono monitor — Hatari: `--monitor mono`

On real hardware `Vsetscreen(rez=2)` only takes effect with a mono monitor
connected (GLUE mono-detect); with a colour monitor the switch is ignored.
Hatari 2.6.1 with a colour monitor (`nMonitorType = 1`) instead **resets the
machine** during the next VBL: EmuTOS double-faults and cold-boots (the
`EmuTOS Version` banner reappears and the program relaunches), and TOS 1.04
kills the app. Verified with a raw `Vsetscreen(..., 2, -1)` + `Vsync` loop —
no AES, no fills — it resets every time within the first 120 vsyncs after
the switch. Switching to low/med with a colour monitor is fine.

Fix — run Hatari with `--monitor mono` when the app switches to high res.
Note the gating is symmetric: with `--monitor mono` the shifter stays in
mono, so colour rezes run but render as monochrome patterns (real hardware
behaviour). Each monitor setting can only display its own resolutions — the
GFX demo therefore shows the low/med phases properly with the default
(colour) monitor and the high phase with `--monitor mono`.

**Expected side effect:** with `--monitor mono` the desktop itself boots in
hi-res (mono), so the app captures `rez 2` on start and restores `rez 2` on
exit — the machine looks "stuck in hi-res" afterwards, but that *is* its
original mode (verified: `GFX: captured rez 2` / `GFX: restore to rez 2`
markers, boot and after-exit screenshots identical). To end on a colour
desktop, run with the colour monitor — but then the demo cannot reach the
high phase (mono is required for it).

### 18. Mid-frame Vsetscreen base change tears in Hatari — flip after vsync

With `flip(); vsync();` the video-base write can land mid-scanline, and
Hatari's Shifter picks it up immediately: the frame shows a band from the
old buffer and the rest from the new one (verified with a two-buffer
flip test: 1 torn frame per ~43 flips, tear band ~8 rows at screen row
~95). On real hardware the base is latched at the next VBL so this is
harmless — in Hatari it is the visible "flicker" during the demo's
animation loop.

Fix — **`vsync(); flip();`** (wait for the VBL, then swap): the base write
lands during the vertical blank. Verified: 0 torn frames across 53 flips in
the same test. This is also the canonical ST double-buffer pattern.

Note the animation also *steps* irregularly in Hatari because each frame's
fill takes ~3-6 VBLs in the UAE core (M68K_NOTES #13) — that is emulator
speed, not a bug; on real hardware a 32000-byte fill is a fraction of one
VBL.

### 19. Pixel RMW path: read-then-store eliminated, usize base narrowed, u8 colour register-reuse — the sprite walk trail

The `putPixel`-based sprite pipeline (used by `drawSprite`, `fillRect`, and
Space Invaders' walk) hit a cluster of backend failures, each verified in the
PRG dump:

1. **Zig read-then-store through `@ptrFromInt` is eliminated entirely** —
   `cur = q[0]; q[0] = cur | mask` compiled to a missing call (the whole
   function dropped, `jsr` to a bare `rts`). The read-modify-write must
   happen inside inline asm (`move.b (a0),d1; and.b; or.b; move.b d1,(a0)`).
2. **ANY conditional call in the plane loop drops the function** —
   `if ((color & bit) != 0) write(...)` (or `continue`) compiled the whole
   `putPixel` to nothing. The plane mask is computed arithmetically from a
   comptime table instead: `PLANE_TEST[color][plane]` (0 or 0xFF) ANDed with
   the bit mask, so the write is always executed (ORing 0 is a no-op).
3. **A `usize` base + small offsets is narrowed to 16 bits** — `andl #65535`
   on the base, so pixels wrote to `base & 0xFFFF` (system RAM). Making the
   base a real `[*]u8` POINTER parameter fixes it (pointer arithmetic cannot
   be narrowed).
4. **u8 colour causes register reuse** — with `color: u8`, the PLANE_TEST
   offset `addl` used the *y* register (`addl d1, d4` = base + y*160 instead
   of colour*4). Both the draw (colour 0) and the erase (colour 15) then read
   the SAME garbage PLANE_TEST row (zeros), so the erase wrote a no-op and
   every sprite position stayed on screen — the walk's growing trail. Making
   `color: u32` fixes it (`lsll #2` uses a different register).
5. **The big u16 table's address is emitted 32 entries too high** — the
   `XBYTE_OFF[320]u16` byte-offset table was referenced with `lea` 0x40 past
   its start, smearing the sprite across the row. Replaced with arithmetic
   (`x >> 4`, `x & 15`) in the regular pointer-offset expression.
6. **The mask-and-replace write is mandatory** — an OR-only pixel cannot
   draw light-on-dark (colour 0 = no plane bits: ORing draws nothing on a
   black field where all bits are set).

Even with `putPixel` fixed, the fillRect-based erase STILL failed inside the
walk loop (draw+erase misread the same PLANE_TEST row in that instantiation)
— the reliable shape for now re-clears the whole back buffer each step
(`clearBack`) and walks a short distance; the fillRect erase needs a future
fix. Also note comptime tables in general are NOT safe to reference by
address (see failure mode 11's cousin: the sprite `Bitmap` consts came out
all-zeros when passed by pointer — `drawSprite` takes the bitmap as a
**comptime parameter** so the pixels fold to immediates).

### 20. Monitor detection: GPIP bit 7 via Supexec (user-mode reads bus-error)

The ST's monitor detect is the MFP GPIP register `$FFFA01`, **bit 7** —
1 = colour, 0 = mono (the same test TOS does at boot; the bit-0 memory
is wrong). Verified under Hatari both ways: colour reads bit 7 = 1, mono
reads bit 7 = 0.

A **user-mode** read of `$FFFA01` bus-errors under Hatari's
compatible-CPU IO protection (verified: `Panic: Bus Error` — same class
as #15). The read needs supervisor mode:

- **XBIOS 38 `Supexec`** (verified working on EmuTOS): pass a routine
  pointer, the trap runs it in supervisor mode. `screen.monitorIsMono()`
  uses this. Requires TOS 2.06+ (not on TOS 1.04 — fall back to
  `getrez() == 2` at startup, which conveys the same information).
- **GEMDOS 0x20 `Super`** stack-switch detour: the switch itself works
  (old SSP returned non-zero), but the MFP read through that detour comes
  back `0xFF` under BOTH monitor types in Hatari — the emulated read is
  wrong in that state. Don't use it for this.

Also note the shifter mode register `$FF8260` does NOT reflect the
monitor: it reads whatever software last wrote, even when the GLUE forces
mono.

### 21. Sprite bit mask mirrored in the first byte of each 16-px group

The `putPixel` bit-position table mapped column `xb` (0-7) to `7 - xb`,
mirroring every 8-pixel block: the sprite's left 8 pixels painted at
mirrored positions, and the mirror region shifted every time the walk
crossed a byte boundary — the sprite looked like its pixels slid/shifted
inside the shape as it moved. Fix: the mask index is simply `x & 7`
(`BIT_MASK[x & 7]`, matching the framebuffer's MSB-first layout). Verified:
walk frames now render the sprite identically at every x.

Residual (unresolved): the sprite's exact shape still doesn't perfectly
match the ASCII art — some right-side (second-byte, columns 8-10) pixels
render off by one. Pixel-map probes and framebuffer dumps were
inconclusive (emulator memory-address ambiguity); needs a focused session
comparing the rendered plane bytes against the expected values.

**Follow-up:** the med-res walk had its own wrap-around — `putPixel` was
low-res-only (4 planes) and in medium res (2 planes, 4-byte groups) the
extra plane writes smeared into neighbouring groups. Fixed with
`putPixelMed` (2 planes, `xw * 4` group stride) and `putPixelHigh` (1 plane,
`y * 80 + (x >> 3)`), and `drawSprite` now takes the `Rez` and branches at
the call site. Verified: the med walk sprite is rigid and alternating with
no smear. The med phase field colour was also changed from white to red
(colour 1) — the white field made the console text (yellow) invisible.

### Benign boot noise: EmuTOS bus-error probes

At boot, EmuTOS deliberately probes addresses (installs a vector-8 handler,
`tst.b (a0)` at ROM `0xE00D96`, expecting bus errors) to test memory — Hatari
logs `WARN : Bus Error reading at address $...` for each. These are **normal**
(they also occur on a bare boot with no program) — not a crash.

---

## GEMDOS trap #1 convention (not a backend bug, but a trap that's easy to get wrong)

GEMDOS (`trap #1`) reads the **function opcode from the stack**, not from `d0`:

```zig
// Correct (matches toslibc's trap_opcode and cconws):
asm volatile (
    \\move.l %[name], -(%%sp)   // args pushed right-to-left
    \\move.w %[mode], -(%%sp)
    \\move.w #0x3d, -(%%sp)    // opcode pushed LAST (on top)
    \\trap #1
    \\lea 8(%%sp), %%sp        // clean args + opcode word
    :
    : [name] "d" (@intFromPtr(name)), [mode] "d" (mode),
    : .{ .memory = true, .ccr = true, .d0 = true, .d1 = true, .d2 = true, .a0 = true, .a1 = true, .a2 = true }
);
```

Putting the opcode in `d0` (the XBIOS/timer_test-style mistake) silently
dispatches the *wrong* function — `fopen`'s `0x3D` ended up executing as
`Cconout` (`0x02`) because GEMDOS read the opcode word from the stack top. XBIOS
(`trap #14`) also reads its opcode from the stack; only the trap number differs.

---

## EmuTOS `Bconin(2)` returns the scancode BYTE, not `(scancode<<8)|ascii`

TOS 1.x/2.x `Bconin(2)` returns `D0.W = (scancode << 8) | ascii` (scancode in
the high byte). **EmuTOS** (Hatari's bundled `tos.img`, used by all configs in
this repo) returns just the scancode byte in the low byte. The classic
`(k >> 8) & 0xFF` extraction reads `0x00` for every key on EmuTOS, so keys are
silently dead.

Fix — normalize in the library (`gemz.readKey`): the two formats are
distinguishable because ASCII is always `<= 0x7F`, so a result `<= 0xFF` is the
EmuTOS form:

```zig
if (r > 0xFF) r >>= 8;
return r; // scancode in the low byte, for both TOS variants
```

Verified against the running EmuTOS: dev-2 `Bconin` handler at `$E0CA3C`
reads a **32-bit** entry from the ring at the base pointer stored in `$30D4`
(size `$30D8`, tail `$30DA`, head `$30DC`); entries are `(conv<<16) |
(scancode<<8) | status` and live at `base+4` upward (the consumer advances
tail by 4 *before* reading, so the first live slot is `base+4`, not `base+0`).

---

## Interrupts can clobber a compiler-kept flag register (use a volatile flag)

A loop flag the compiler keeps in a register across interruptible work can be
silently lost. In `space.zig` the `quit` flag lived in `d4` across the whole
frame (key scan, update, draw, vsync, flip). With a key injected, the ESC
branch reliably set `d4 = 1` (verified in the disassembly and by breakpoints
at the ESC branch and at the loop check with `d4 = 1`), yet the game
**sometimes** kept running — the flag had been clobbered between the ESC
branch and the check. The VBL/timer/interrupt handlers examined all save and
restore `d0-%fp`, so the clobberer was never pinned down, but the fix is
robust regardless:

```zig
var quit: bool = false;
const q: *volatile bool = &quit;   // memory flag — immune to register clobber
while (!q.*) {
    // ...
    q.* = true; // ESC pressed, or game over
}
```

After the change the ESC key quits the game reliably (verified end-to-end:
key injected into EmuTOS's CON ring, `SPACE: done` printed, desktop restored).
Rule: any state that must survive across `vsync`/traps/interrupts should live
in memory, not in a register the backend keeps live.

---

## Patterns that have worked

- `self.music[comptime_index].field` — fixed offset through `self`.
- Leaf functions taking `*Track` and using `t.field` / `t.notes[t.index]` —
  runtime index into a **stable pointer** is fine (`stepTotalTicks`,
  `stepOnTicks`, `emitNote`).
- Comptime recursion over a comptime array (`armRep`, `stopRep`) — works when
  it stays simple.
- Comptime `for` with a scalar accumulator (`songMixer`).
- Comptime-only helpers (`parseNotes`, `pitchShift`, `transpose`) — safe because
  they run on the host compiler.
- Struct-field stores through `self` — the reliable form. Avoid mutable `var`
  globals.

---

## Verification workflow

Never trust a change that touches one of the risky shapes until you have looked
at the disassembly.

1. Build.
2. Dump the PRG.
3. Check the specific markers for the code in question:
   - sequencer tone/drum dispatch: `subw #-16` (correct) vs `subw #-17`.
   - `parseNotes` runtime loop: char-classification `subb #46`/`subb #63` should
     be **absent** once it is comptime.
   - stepMusic channel coverage: fixed offsets for all three tracks
     (`music[0]`, `music[1]`, `music[2]`), not just `music[0]`.
4. For music data, decode the baked periods from the PRG and compare against the
   note string (or just eyeball the `.rodata`).
5. Any app with a large `.bss` (e.g. framebuffers): check the ELF relocations
   for `R_68K_PC16` entries whose symbol offset approaches/exceeds `0x8000`
   (failure mode 11). `m68k-elf-readelf -r` on the `.elf` in `.zig-cache/o/`.
6. Colour fills: confirm the disassembly has `btst` + `sne` (not `seq`) before
   the `negb` (failure mode 12), and that the store is a plain `(a0)`
   (`move.b d2,(a0)`), not a double-indexed form (failure mode 13).

A good litmus test before asking the user to run anything: rebuild, disassemble,
and confirm the expected instruction actually exists and the broken form is
gone.
