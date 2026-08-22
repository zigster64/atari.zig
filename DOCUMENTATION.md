# Build Pipeline: Zig → m68k Atari TOS .PRG

> **Toolchain location:** the m68k-enabled Zig + LLVM toolchain is in
> **`~/Atari/bin`** (zig, clang, toslink, prgify, m68k-elf-*, …). Build with
> `~/Atari/bin/zig build` — *not* the system `zig`, which has no m68k backend
> and fails confusingly. In a sandboxed shell you may also need to redirect the
> Zig global cache: `ZIG_GLOBAL_CACHE_DIR=~/Atari/.zig-cache-global ~/Atari/bin/zig build`.

## Overview

This project compiles Zig source code into Atari ST / TOS `.PRG` executables,
targeting the Motorola 68000 CPU with the GEMDOS operating system (EmuTOS /
Hatari emulator).

The pipeline has four stages:

```
┌──────────┐     ┌──────────────┐     ┌───────────┐     ┌──────────┐
│ Zig      │     │ m68k-elf-ld  │     │ toslink   │     │ Hatari   │
│ build-obj│ ──→ │ --relocatable│ ──→ │ (elf→prg) │ ──→ │ (emu)    │
│ → .o     │     │ → .elf       │     │ → .PRG    │     │          │
└──────────┘     └──────────────┘     └───────────┘     └──────────┘
                      ↑                    ↑
                  startup.s            prg.ld
                  (trampoline)      (linker script)
```

---

## Stage 1: Zig → Object File (.o)

**Tool:** `~/Atari/bin/zig build-obj` (via `build.zig`)

Zig compiles `src/main.zig` to a relocatable ELF object file targeting
`m68k-freestanding-none`. Key build flags:

| Flag | Purpose |
|------|---------|
| `-target m68k-freestanding-none` | Cross-compile to 68000, no OS |
| `-O ReleaseSmall` | Size-optimized code |
| `-fno-compiler-rt` | No compiler runtime (we provide memset/abort) |

**Output:** `HELLO.o` — m68k ELF relocatable object

### The `_start` ordering problem

Zig emits all functions into a single `.text` section. The compiler sorts
functions **alphabetically**, not in source order. This means:

```
Symbol table order in HELLO.o:
  00000000 T memset      ← 'm'
  0000003a T abort       ← 'a'
  00000040 T _start      ← '_'
```

`_start` (the entry point) lands at VMA `0x40`, not at VMA `0`. The GEMDOS
PRG format requires the entry point at text offset 0 — the PRG header magic
number `0x601A` is a `BRA.S` instruction that jumps to exactly `header + 0x1C`
(the first byte after the 28-byte header).

**Note:** The reference project at
[DominoTree/modern-m68k-toolchains](https://github.com/DominoTree/modern-m68k-toolchains)
also uses Zig 0.16.0 but *does not* have this problem — `_start` is at VMA 0
in their `.o` files. This suggests their custom Zig build (at
`/opt/m68k/zig-install/bin/zig`) has a different function ordering, possibly
due to a different LLVM configuration, build flags, or source patches.

### The trampoline fix (`startup.s`)

To guarantee code at text offset 0 regardless of Zig's function ordering, we
assemble a small trampoline in assembly:

```asm
    .section .text._startup,"ax",@progbits
    .globl _startup
_startup:
    bra _start
```

This is a single PC-relative branch instruction (6 bytes). It's placed in its
own section `.text._startup` which the linker script puts first via
`KEEP(*(.text._startup))`.

At runtime, the flow is:
1. GEMDOS loads the PRG, branches to text offset 0 → hits the trampoline
2. Trampoline executes `bra _start` → jumps to wherever Zig placed `_start`
3. `_start` runs normally

The `bra` instruction (not `jmp`) is critical — it's PC-relative, so it
works regardless of where GEMDOS loads the program in memory. An absolute
`jmp` would encode the linked VMA (e.g. `0x48`) and fail when the program
is loaded at a different address.

---

## Stage 2: Link → Relocatable ELF (.elf)

**Tool:** `m68k-elf-ld` (GNU binutils for m68k)

The Zig `.o` file and the trampoline `startup.o` are linked together with
`--relocatable`. This produces a partially-linked ELF that still contains
relocation entries. The linker script `prg.ld` controls section layout.

### Linker script (`prg.ld`)

```
ENTRY(_startup)

SECTIONS {
    .text : ALIGN(4) {
        KEEP(*(.text._startup))   ← trampoline first, keep despite --gc-sections
        *(.text._start)
        *(.text)                  ← all Zig functions
        *(.text.*)
    }
    .data : ALIGN(4) {
        *(.data) *(.data.*)
        *(.rodata) *(.rodata.*)   ← string literals go here
    }
    .bss : ALIGN(4) {
        *(.bss) *(.bss.*)         ← uninitialized globals (allocated at load)
    }
    /DISCARD/ : {                 ← stripped sections
        *(.comment) *(.note.*) *(.eh_frame*) *(.debug*)
    }
}
```

Key points:
- `ENTRY(_startup)` — tells the linker (and toslink) the entry is the trampoline at VMA 0
- `KEEP(*(.text._startup))` — prevents `--gc-sections` from discarding the trampoline
- `.rodata` is merged into `.data` — Atari PRG has only text + data + bss segments
- `/DISCARD/` removes debug info, exception frames, and other host sections

**Output:** `HELLO.elf` — partially linked ELF with unresolved relocations

---

## Stage 3: ELF → Atari PRG (.PRG)

**Tool:** `toslink` (from [toslibc](https://github.com/frno7/toslibc))

`toslink` reads the relocatable ELF and produces a GEMDOS-compatible `.PRG` file.

### What toslink does

1. **Parses the ELF** — reads section headers, symbol table, relocation entries
2. **Computes the PRG header** — 28-byte header with sizes and the `0x601A` magic
3. **Resolves PC-relative relocations in-place** — `R_68K_PC8`, `R_68K_PC16`, `R_68K_PC32` are computed and written directly into the binary
4. **Builds an absolute relocation table** — `R_68K_32` relocations are recorded in a compact delta-encoded table at the end of the PRG, so GEMDOS can fix them up at load time
5. **Writes the `.PRG` file** — header + text + data + relocation table

### The `-s` flag

`toslink -s` strips the GEMDOS symbol table from the output, producing a
smaller PRG. Without `-s`, the symbol table is included for debugging.

### PRG header format (28 bytes)

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 2 | Magic (`BRA.S`) | `0x601A` (hardcoded, not computed) |
| 2 | 4 | Text size | From `.text` section |
| 6 | 4 | Data size | From `.data` section |
| 10 | 4 | BSS size | From `.bss` section |
| 14 | 4 | Symbol table size | 0 (stripped) |
| 18 | 4 | Reserved | 0 |
| 22 | 4 | Program flags | 0 |
| 26 | 2 | ABSFLAG | 0 (relocatable) |

**Output:** `HELLO.PRG` — Atari GEMDOS executable

---

## Stage 4: Execution (Hatari)

**Tool:** Hatari 2.6.1 with EmuTOS

The PRG is placed in `~/Atari/CDrive/` which Hatari mounts as the GEMDOS `C:`
drive. The program is loaded by double-clicking in the GEM desktop or passing
it as a command-line argument.

A minimal Hatari config (`hatari-st.cfg`) sets up a stock 68000 ST with 4MB
RAM, monochrome display, no blitter/FPU/DSP, and GEMDOS HD emulation.

---

## The `prgify` tool (deprecated)

`prgify` was an earlier attempt to replace `toslink` with a pure-Zig
ELF→PRG converter. It used `m68k-elf-objcopy -O binary` to extract a flat
binary from a fully-linked ELF, then manually constructed the PRG header.

### Why it was abandoned

`objcopy -O binary` extracts raw section data but **does not resolve
relocations**. The approach failed for two reasons:

1. **With `--relocatable` ELFs:** relocation entries are present but
   `objcopy` copies the placeholder bytes (zeros) instead of resolved
   addresses. The resulting binary has `JSR 0` at every call site.

2. **With fully-linked ELFs (no `--relocatable`):** all relocations are
   resolved at link time to absolute addresses (e.g. VMA `0x48`). But
   GEMDOS loads the program at a different base address (`basepage + 0x100`),
   so all absolute addresses are wrong → bus errors.

`toslink` handles both cases: it resolves PC-relative relocations in the
binary and builds a relocation table for absolute ones, letting GEMDOS
fix them at load time.

`prgify` is kept in the repo at `~/Atari/zig-m68k/prgify/` for reference
but is **not used** in the current build pipeline.

---

## Future Work

### Replace `toslink` with a pure-Zig tool

`toslink` is a C program that depends on `gcc-14` to build (Apple Clang
lacks the `__scalar_storage_order__` attribute needed by the toslibc headers).
The goal is to write a replacement in Zig that:

1. **Parses m68k ELF files** — section headers, symbol table, relocations
2. **Resolves PC-relative relocations** (`R_68K_PC8/16/32`) and writes
   resolved values into the binary
3. **Builds an absolute relocation table** for `R_68K_32` relocations
4. **Constructs the 28-byte GEMDOS PRG header**
5. **Writes the final `.PRG` file**

This eliminates the dependency on:
- `m68k-elf-ld` (for linking)
- `m68k-elf-objcopy` (for binary extraction)
- `m68k-elf-nm` / `m68k-elf-size` (for symbol/section inspection)
- `toslink` itself (for PRG generation)

### Bundle linker script functionality

Currently `prg.ld` controls section layout and discards debug sections.
A future Zig-based linker could handle this internally:
- Place the trampoline at text offset 0
- Merge `.rodata` into `.data`
- Strip debug/exception sections
- Set correct section alignment for the PRG format

### Handle the `_start` ordering at the tool level

Instead of requiring a separate `startup.s` assembly file, the Zig tool
could automatically insert a trampoline at offset 0 when it detects that
`_start` is not at the beginning of `.text`.

### Drop `m68k-elf-binutils` dependency

Once the Zig tool handles linking and PRG generation, the only external
tool needed would be the Zig compiler itself (for `build-obj`). The entire
pipeline becomes `zig build-obj` → `zig-prgify` (our tool).

---

## File Reference

| File | Purpose |
|------|---------|
| `src/main.zig` | Application source (freestanding, no stdlib) |
| `src/startup.s` | Assembly trampoline (`bra _start`) |
| `prg.ld` | Linker script (section layout) |
| `build.zig` | Build orchestrator (Zig build system) |
| `build.zig.zon` | Package manifest |
| `~/Atari/bin/prgify` | Deprecated ELF→PRG tool (kept for reference) |
| `~/Atari/bin/toslink` | Current ELF→PRG tool (from toslibc) |
| `~/Atari/Configs/hatari-st.cfg` | Hatari emulator config (68000 ST) |
| `~/Atari/zig-m68k/prgify/` | Deprecated prgify source |
| `~/Atari/zig-m68k/ds-zig-build.sh` | Zig compiler build script (LLVM 21 + m68k) |

## AES argument conventions — gotchas (learned the hard way)

### wind_set / wind_get pass pointers in int_in, NOT addr_in
`wind_set(handle, what, ...)` is variadic. Its pointer arguments — the title for
`WF_NAME` (2), the info line for `WF_INFO` (3) — are passed as the 32-bit address
split across two 16-bit `int_in` words, not via `addr_in`:

    wind_set(handle, WF_NAME, title)
    => int_in = [handle, 2, title>>16, title & 0xffff, 0, 0]

Known-good trace: `wind_set(intin: 0x1, 0x2, 0x2, 0xd862, 0x0, 0x0)` — handle 1,
field 2, then the title pointer `0x0002d862` split into `0x0002, 0xd862`.

Contrast: `objc_draw`, `form_alert`, `rsrc_load` DO take their pointers via
`addr_in`. The AES is inconsistent — check the doc for each call.

### wind_get(work_xywh) returns screen coordinates (EmuTOS)
Not window-relative. Do not add `curr_xywh` to it.

### G_TEXT / G_BOXTEXT use a TEDINFO, not a raw string
EmuTOS dereferences `ob_spec` as a pointer-to-TEDINFO (first field `ptext` is the
string). `G_BUTTON` and `G_TITLE` take plain strings.

### TEDINFO (not the text string) must be word-aligned
For `G_TEXT`/`G_BOXTEXT`, `ob_spec` is a pointer to a `TEDINFO`; the AES reads
that structure with word/long accesses, so the *TEDINFO* must be 2-aligned.
Zig's `extern struct` already gives it the required alignment. The text string
itself (`te_ptext`, and the plain string for `G_BUTTON`/`G_TITLE`) is read
byte-by-byte and needs no special alignment — no `align(2)` buffer is required.

`TEDINFO.te_color` is a packed bitfield, not a colour index: bits 8-11 select
the text colour. `1` means "black *fill* colour", which gives white (invisible)
text on the mono screen; black text is `0x0100`.

### Object-tree invariant: the last child's `ob_next` points at its parent
GEM links a parent's children in a sibling chain: `parent.ob_head` is the first
child, `parent.ob_tail` is the last child, and each child's `ob_next` points to
the next sibling — **except the last child, whose `ob_next` points back to the
parent**.

The AES relies on this to walk trees. `get_par()` (used by `objc_find` /
`objc_offset`) does:

    next = tree[obj].ob_next;
    while (tree[next].ob_tail != obj)
        next = tree[next].ob_next;

If the last child's `ob_next` is left at `-1` (NIL) instead of the parent, that
loop reads `tree[-1]` — one `OBJECT` before the array — and spins forever on
garbage.

**Symptom:** a window draws fine, but the very first click inside it hangs the
app in a tight loop inside the AES (Hatari debugger shows the PC stuck in TOS
`get_par`, ~`0xE7AA46` in the bundled EmuTOS). Buttons never get `onClick`.

**Fix:** when building a flat tree, set the last child's `ob_next` to the root
(`0`), e.g. `tree[last].next = 0`. `GEMZ.Object.tree()` now does this.

### `evnt_multi` returns immediately when the requested button state is already current
`evnt_multi`'s button wait is satisfied *immediately* if the mouse is already in
the requested state (`downorup` checks `bstate == button`, not a transition):

- `bstate = 0` ("released") returns at once while the button is up → busy loop
  at idle.
- `bstate = 1` ("pressed") returns at once while the button is held → busy loop
  during the hold.

To detect a click without spinning: wait for the press first (`bstate = 1`),
then swallow the release with a second wait (`bstate = 0`).

### `te_color` colour indices (Atari ST palette)
`te_color` packs the *text* colour into bits 8–11 (border 12–15, fill 0–3,
replace-mode bit 7). The standard palette indices are 0 white, 1 black, 2 red,
3 green, 4 blue, 5 cyan, 6 yellow, 7 magenta (8–15 are the low-intensity set).
So red text is `0x0200`. GEMZ wraps this as `Color` (enum) + `textColor(color)`
(`Color.red` → `0x0200`).

### G_IMAGE / BITBLK — 1-bit images
`G_IMAGE` (object type 23) draws a monochrome bitmap; `ob_spec` points at a
`BITBLK`:

    void *bi_pdata;   // packed bit data (row-major, MSB-first)
    WORD  bi_wb;      // width in bytes
    WORD  bi_hl;      // height in lines
    WORD  bi_x;       // source x offset (usually 0)
    WORD  bi_y;       // source y offset (usually 0)
    WORD  bi_color;   // foreground colour index

"1" bits draw in `bi_color`; "0" bits are transparent. Pack 8 pixels per byte,
MSB = leftmost pixel. The BITBLK (and its data) must be a stable, word-aligned
static — pass `&module_level_const`, never a temporary.

### Comptime ASCII-art → bitmap
`gemz.bitmap(&.{ "..#..", ... })` packs `#`-and-`.` rows into a 1-bit bitmap at
compile time, so the app never hand-writes bytes and no runtime packing code is
emitted. The ASCII source does **not** appear in the binary — only the packed
bytes (48×24 → 144 bytes). The triple-nested `inline for` exceeds the comptime
evaluator's default 1000-branch quota, so the helper calls
`@setEvalBranchQuota(10000)`.

### LLVM lowers struct moves to `memmove`
Swap-removing a pool entry (`views[i] = views[last]`) copies a whole struct; LLVM
emits `memmove` for potentially-overlapping copies. Freestanding m68k must
provide `memmove` (forward/backward byte loop) next to `memcpy`/`memset`.

### m68k backend: indexed byte stores lose their index register
The LLVM m68k backend has a bug where an indexed byte store
(`arr[i] = byte_value`) drops the index register and writes every byte to the
*same* address. Symptom: runtime byte-by-byte buffers come out corrupted — every
byte ends up equal to the last one written.

This bit us hard: `Track` briefly carried a `drums: [64]u8` byte array, and the
struct copy (`t.* = parseNotes(...)`) corrupted the whole struct — `count`,
`notes`, and `active` all came out garbage. That is what caused the "bassline
stuck on note 1 + noise" bug (see the post-mortem below).

**Rule:** never put a *byte array* in a struct that gets copied on this target.
Use `u16` word arrays, or encode small enums/flags into spare high bits of an
existing word. (Scalar `u8`/`bool` fields are fine — the bug is the *indexed*
byte store, not the byte type.)

### m68k backend: no 32-bit hardware multiply/divide (helpers provided)
The 68000's `MULU.W` / `MULS.W` only multiply two **16-bit** values, and it has
no 32-bit divide. Zig lowers `u32 * u32` / `u32 / u32` / `u32 % u32` to
compiler-rt helpers (`__mulsi3`, `__udivsi3`, `__umodsi3`). This project builds
with `-fno-compiler-rt` (freestanding), so GEMZ exports 68000-safe Zig versions
of all three (`__mulsi3` = shift-add, `__udivsi3` = shift-subtract, `__umodsi3`
wraps it).

**Rule:** 32-bit arithmetic now links and works, but it is a runtime helper
call, not hardware — keep shifts for the hot doubling/halving paths. Note
durations still use `delay_ms << dashes` instead of `delay_ms * beats`.

### YM2149 mixer (register R7) bit map
The mixer selects, per channel, whether its **tone**, its **noise**, both, or
neither reach the output. Bits are active-low (0 = enabled):

| Bit | Source |
|-----|--------|
| 0 | Tone A |
| 1 | Tone B |
| 2 | Tone C |
| 3 | Noise A |
| 4 | Noise B |
| 5 | Noise C |
| 6–7 | I/O ports (not sound) |

There is **one** noise generator (shared; period in R6) but three tone
generators. Channel volume (R8–R10) is separate — enabling noise in the mixer
but leaving the channel volume at 0 is still silent.

`playSong` derives the mixer from each part's notes (drum tokens `k/s/h/t/x` →
noise, otherwise → tone) rather than hardcoding A=tone / B,C=noise. This standard
map matches observed behaviour (`0xFA` = tone A + tone C) but has not been
empirically verified against the emulator.

### Noise-bug post-mortem
Symptom: after a broken `playSong`, plain `play()` melodies had "noise on every
beat that blanked on the gate".

The gated behaviour was the tell: the noise was on the *active* tone channel, not
on unmuted noise channels (the sequencer gate only silences active tracks). The
corrupted `drums` byte array made `emitNote` take the drum branch for a tone
channel — writing **volume without a tone period** — so the channel rang its
stale period at full volume, gated per step, which reads as noise.

The fix was the sentinel encoding: drum hits are stored as `0xFFF0+` sentinels in
the existing `notes` word array instead of a separate byte array, eliminating the
corruption.

### m68k backend: stores to `var` globals misencoded as PC-relative (illegal opcodes)

The backend sometimes emits a store to a *global* (`var x: u32 = 0` at file scope) with
a PC-relative destination instead of absolute-long, producing **illegal opcodes** that
write to code memory and crash later with `Illegal instruction` (PC inside `.text`).

Observed misencodings (correct → emitted):

| correct | emitted | meaning |
|---------|---------|---------|
| `0x31FC` | `0x35FC` | `move.w #imm,(An)+` → wrong dest mode |
| `0x157C` | `0x15FC` | `move.b #imm,d16(An)` → `(d16,PC)` |
| `0x23C1` | `0x25C1` | `move.l Dn,(abs).l` → `(d16,PC)` |

The tell-tale is a destination addressing mode that should be absolute but instead uses
the PC-relative register sub-field (`010`). The write lands in *code* memory, and the
corruption surfaces later, often at a different point than the store itself.

**Rule:** don't keep *mutable runtime state* in `var` globals. Put it in the `App`
struct and access it through the `self` pointer — struct-field stores via `self` are
the one store form the backend reliably gets right.

### m68k backend: comptime recursion / `inline for` over a comptime array of structs

A previous rep-scheduling attempt (`findPart`/`packSchedule`/`advanceSchedule`/
`applySched`) compiled to dead code — the rep counter never incremented and the
apply function was never called. The current form (`armRep`/`stopRep` recursing
into a simple `armCore` call) **works**: keep comptime recursion simple, avoid
`inline for` when struct-field stores are involved, and disassemble to confirm
the code is actually present.

### m68k backend: while-loop step state can swap a null-check branch

Rewriting `stepTrack` as a `while (left > 0)` loop with carried locals (`left`,
`wrapped`) made **TODO bus-error even though it never plays music**. The crash
was `jsr (a1)` with `a1 = 0`: `if (self.song_advancer) |adv| adv(...)` ran
through its null pointer even though the emitted `cmpil #0, d2; beq` guard sat
immediately before it — the branch condition was effectively wrong for that
inlined code shape.

**Rule:** for the sequencer hot path, keep the original early-return structure
and avoid a `while` loop with extra carried state. The synch fix is expressed as
`const leftover = elapsed - t.remaining;` plus `if (t.remaining > leftover)
t.remaining -= leftover;` in each branch — same shape as the working code, no
new loop.

### Sequencer channel drift (B/C vs A)

Tracks B/C drifted out of synch with A over long songs because `stepTrack`
discarded `elapsed - t.remaining` every time a phase boundary was crossed. Each
channel crosses boundaries at different times, so each lost a slightly different
amount per wake; over reps the offsets accumulated.

**Fix:** carry the leftover into the next phase (see above). This keeps all three
channels advancing at exactly the same rate.

## GEMZ application model (App / Node / View)

`gemz.App(comptime max_views, comptime max_nodes)` is a comptime function that
returns the app *type*, sized for heap-free static allocation:

- `max_views` — windows open at once.
- `max_nodes` — largest single tree (**per view**, not global).

A live window is a `View`: its own mutable copy of the tree (redraw/resize
mutate `tree[0]`), plus a parallel binding array. Footprint ≈
`max_views × (6 + 32 × max_nodes)` bytes — declare the app as a module-level
global if you size it large, since a `var` in `main()` is on the stack.

Behaviour is bound at the widget, not by tree index (reordering can't desync):

    const MyApp = gemz.App(1, 16);
    var app = try MyApp.init();
    defer app.exit();

    try app.open(.{ .kind = .{ .name = true, .closer = true, .mover = true, .sizer = true },
                    .title = "WINDOW", .x = 50, .y = 50, .w = 320, .h = 200 }, &.{
        .box(320, 200),
        .text("banner", 8, 8, 300, 20),
        .textTed(&RED, 8, 32, 300, 20),
        .image(&LOGO, 8, 60, 48, 24),
        .button(" Alert ", 8, 140, 80, 24, .selectable, &.{.{ .click = alertClicked }}),
    });

    app.run();

`Node = { obj, bindings }`. `bindings` is `[]const Binding`, a tagged union
(`click`, `select`, `edit` — only `click` dispatched today). `buildTree()` splits
the `Node` list into the linked GEM tree + the handler array in one place, so the
two can't drift.

`run()` re-reads `views[0..view_count]` every pass: handlers can `app.open(...)`
mid-run, `WM_CLOSED` swap-removes a view, and the loop exits when the pool
empties. Messages route by `msg[3]`, clicks by `wind_find`.

## Fullscreen graphics (`screen.zig`)

Fullscreen apps bypass GEM: XBIOS `Vsetscreen` switches resolution/screen base,
`Vsync` waits for VBL, and the app writes the ST's interleaved 4-plane bitplane
layout directly.

**Framebuffer alignment gotcha:** the ST Shifter requires the screen base to be
256-byte aligned, but this bare linker only guarantees 4-byte alignment for
`.bss` (even with `align(256)` on the Zig symbol). Over-allocate and align at
runtime instead: `(addr + 255) & ~@as(usize, 255)`.

**Space Invaders post-mortem (crash signatures + what fixed them):**

The first fullscreen game (`SPACE.PRG`) exposed a cluster of m68k-backend
miscompiles that all presented as "random" crashes whose PC moved every time the
code changed:

- `Panic: Illegal Instruction` (PC inside `.text`)
- `Panic: Bus Error` on `rts` (corrupted return address)
- `Panic: Line F Emulator` (executed data/garbage as a `0xFxxx` coprocessor op)

**The tell:** the reported PC was often a *valid* instruction in the disassembly,
or landed 2 bytes into one. That means the text in memory had been overwritten —
a memory-corruption crash, not a bad opcode. Do not trust the panic PC blindly;
check whether the bytes at that PC match the file before assuming an illegal
instruction.

**Root cause (double-buffering):** `var front`/`back` plus the swap, fed by two
runtime `aligned(&buf_a_raw)` / `aligned(&buf_b_raw)` calls, got miscompiled: the
framebuffer address ended up as `0x18700` instead of `0x20900`/`0x30700`, so
`clearScreen` wrote over the program's own `.text`. The compiler even swapped the
two `&buf_*` references (harmless on its own, but a symptom of the same
reordering bug).

**Fix:** collapse to a single framebuffer and inline the alignment:
`(@intFromPtr(&buf_raw) + 255) & ~@as(usize, 255)`. No `front`/`back`, no swap.
Double-buffering is still desirable (single-buffer shows tearing) but must be
re-approached with the address arithmetic verified by disassembly.

**Palette is mandatory:** framebuffer pixel values are *hardware* colour indices
(0..15 into the Shifter palette), not the `gemz.Color`/VDI logical indices. The
GEM desktop palette does not match the `Color` enum, so `BG = .black = 1`
renders red, not black. Install an explicit 16-word palette via `Setpalette`
(XBIOS 6) after `Vsetscreen`, mapping `0=white, 1=black, 2=red, ..., 5=cyan`.

**Partially solved — the crash was the toslink displacement bug; the remaining band is a Hatari rendering quirk:**

What the "coloured band at the top" actually was, once `GFX.PRG` (the minimal
probe) reproduced it:

1. **The app crashed** — EmuTOS showed `Panic: Illegal Instruction` / `Panic:
   Line F Emulator` (the panic screen waits for a keypress forever, so the
   machine looks hung and needs a reset). Root cause: a PC-relative reference
   to `gfx_buf_b` (`.bss + 0x7E00` in a 64 KB `.bss`) crossed the 32 KB signed
   displacement boundary, toslink emitted a 16-bit displacement the 68000
   reads as negative, and the fill wrote ~64 KB early — over the TPA and
   `.text`. **Fixed** by deriving buffer B from buffer A by addition
   (`b = a + screen_bytes + 256`); see M68K_NOTES.md failure mode 11. The
   app now runs its full loop with no panic.
2. **The remaining "band"** — resolved: it was Hatari's *extended VDI
   resolutions* mode (`bUseExtVdiResolutions = TRUE`). In that mode the
   desktop/VDI runs at a custom resolution, so a 320x200 app screen only
   covers part of the display area and the rest renders as leftover
   content. **Fix:** `bUseExtVdiResolutions = FALSE` (and `nFrameSkips = 0`)
   in the Hatari config — done in `Configs/hatari.cfg` and
   `Configs/hatari-st.cfg`. Interactive Hatari must be restarted with
   `-c ~/Atari/Configs/hatari.cfg` for the fix to apply.
3. **Resolution switches and the monitor type** — `Vsetscreen(rez=2)`
   (mono) requires a mono monitor, exactly as on real hardware (GLUE
   mono-detect). Hatari defaults to a colour monitor; requesting rez 2
   then **resets the emulated machine** (EmuTOS cold-boots, TOS 1.04 kills
   the app). Run high-res apps with `--monitor mono` (M68K_NOTES.md #17).
   With a mono monitor the colour rezes still run but display as
   monochrome patterns — so the GFX demo shows low/med properly with the
   default monitor and high with `--monitor mono`.

**Safer fullscreen shapes:**

- Write `clearScreen` as a flat byte loop (index `i`, `plane = (i >> 1) & 3`),
  not the triple-nested line/group/plane loops.
- Use `u8` for the plane counter, not `u3` (and cast the shift amount with
  `@intCast`).
- Use pointer arithmetic (`p += 1` / `q = p + 1`) instead of `p[1]` indexed byte
  access.

**Mouse control API added:** `gemz.applInit()` and `gemz.grafMouse(mode)` are now
public; `GrafMouse.off = 256`, `GrafMouse.on = 257`. `appl_init` leaves the app
in the busy/hourglass state, so call `grafMouse(GrafMouse.arrow)` or `.off`
after `applInit`.

## Tech Debt

### Window resize never commits (`WM_SIZED`)

**Symptom:** dragging the sizer corner shows the AES rubber-band rect, but on
release the window snaps back — it never actually resizes. Pre-existing, not a
regression.

**Cause:** the `WM_SIZED` arm in `handleMessage` resizes `tree[0]` and redraws,
but never tells the AES the new size. A resize is only applied when the app
calls `wind_set(handle, WF_CURRXYWH, x, y, w, h)`; the handler skips it.

**Fix:** call `v.window.moveTo(msg[4], msg[5], msg[6], msg[7])` (already wraps
`wind_set` `WF_CURRXYWH`) *before* re-reading `workRect()` and resizing `tree[0]`
to the new work area.

## Backlog

### window.zig — "Code" button opens the source in a second window

Add a `Code` button to the existing window. On click, open a second window that
displays the literal contents of `src/window.zig`.

Implementation notes:

- Embed the source at comptime with `@embedFile("window.zig")`; split it into
  lines (also comptime) and emit one `G_TEXT` node per line, plus a root box and
  a Close button.
- The app currently allocates `App(1, 16)` — one view, 16 nodes. A second window
  needs `max_views = 2`, and `max_nodes` must cover the source line count plus
  the box/button. `window.zig` is ~45 lines, so `App(2, 64)` is safe.
- The click handler calls `app.open(...)` mid-run (supported: `run()` re-reads
  `view_count` every pass). The second window is just another tree; its Close
  button reuses the existing `WM_CLOSED` path.
