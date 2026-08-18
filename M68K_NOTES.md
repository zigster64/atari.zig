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

A good litmus test before asking the user to run anything: rebuild, disassemble,
and confirm the expected instruction actually exists and the broken form is
gone.
