const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .m68k,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    // ── 1. Compile to object (.o) — LLD has no m68k backend ───────────────

    const obj = b.addObject(.{
        .name = "HELLO",
        .root_module = mod,
    });
    obj.entry = .{ .symbol_name = "_start" };
    obj.bundle_compiler_rt = false;

    // ── 2. Link + binary extract + GEMDOS header → HELLO.PRG ──────────────

    const prg = b.addSystemCommand(&.{ "sh", "-c" });
    prg.addArg(
        \\set -e
        \\mkdir -p ~/Atari/CDrive
        \\DIR="$(mktemp -d)"
        \\m68k-elf-ld --gc-sections --script "$1" -o "$DIR/hello.elf" "$0"
        \\
        \\# Find _start offset in the ELF (relative to text section)
        \\START_HEX=$(m68k-elf-nm "$DIR/hello.elf" | awk '$3=="_start"{print $1}')
        \\START_DEC=$((16#$START_HEX))
        \\
        \\# Build the 28-byte GEMDOS header:
        \\#   bytes 0-1: BRA.W with displacement = _start_addr - 2
        \\#   bytes 2-27: zero
        \\DISP=$((START_DEC - 2))
        \\HI=$(( (DISP >> 8) & 0xFF ))
        \\LO=$(( DISP & 0xFF ))
        \\printf "\\x60\\x$(printf '%02x' $HI)\\x$(printf '%02x' $LO)" > "$DIR/header.bin"
        \\dd if=/dev/zero bs=26 count=1 >> "$DIR/header.bin" 2>/dev/null
        \\
        \\m68k-elf-objcopy -O binary "$DIR/hello.elf" "$DIR/hello.bin"
        \\cat "$DIR/header.bin" "$DIR/hello.bin" > ~/Atari/CDrive/HELLO.PRG
        \\rm -rf "$DIR"
    );
    prg.addFileArg(obj.getEmittedBin());    // $0
    prg.addFileArg(b.path("prg.ld"));        // $1

    b.getInstallStep().dependOn(&prg.step);
}
