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

### 4. Indexed byte store can drop the index register

```zig
// RISKY
arr[i] = some_u8;
```

Symptom: the store can lose the `i` register and write the wrong address.

Fix — avoid runtime byte stores into arrays. Use a scalar accumulator and write
once, or make the index comptime. (`songMixer` was rewritten from `tone[ci] = …`
to a scalar `mixer &= ~(1 << bit)` fold.)

### 5. No `u32 * u32` (no `__mulsi3` with `-fno-compiler-rt`)

```zig
// AVOID
const x: u32 = a * b;
```

Fix — use shifts for doubling/halving. Our frequency/period work is all
`<< 1` / `>> 1` / `<< dashes` for exactly this reason.

### 6. Comptime recursion + `inline for` over a struct array → dead code

A previous rep-scheduling attempt (`findPart`, `packSchedule`, `advanceSchedule`,
`applySched`) compiled to dead code — the rep counter never incremented and the
apply function was never called.

Fix — keep comptime recursion simple (the current `armRep` / `stopRep` form
works), and prefer explicit calls over `inline for` when struct-field stores are
involved. Disassemble to confirm the code is actually present.

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
