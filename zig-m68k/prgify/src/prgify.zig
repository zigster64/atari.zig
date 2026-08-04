// prgify — convert m68k ELF to Atari ST .PRG

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub fn convert(alloc: Allocator, io: std.Io, elf_path: []const u8, prg_path: []const u8) !void {
    const cwd = Dir.cwd();
    const start_vma = try getStartVma(alloc, io, elf_path);
    const sizes = try getSectionSizes(alloc, io, elf_path);
    const bin = try extractBinary(alloc, io, elf_path);

    const disp: i16 = @intCast(@as(i32, @intCast(start_vma)) + 0x1C - 2);
    if (disp < -128 or disp > 127) return error.DisplacementTooLarge;

    var header: [28]u8 = [_]u8{0} ** 28;
    header[0] = 0x60;
    header[1] = @intCast(disp);
    std.mem.writeInt(u32, header[2..6], sizes.text, .big);
    std.mem.writeInt(u32, header[6..10], sizes.data, .big);
    std.mem.writeInt(u32, header[10..14], sizes.bss, .big);

    const expected_len = sizes.text + sizes.data;
    if (bin.len < expected_len) return error.BinaryTooSmall;

    const file = try Dir.createFile(cwd, io, prg_path, .{});
    defer File.close(file, io);
    try File.writeStreamingAll(file, io, &header);
    try File.writeStreamingAll(file, io, bin[0..expected_len]);

    std.debug.print("-> {s} ({d} bytes)\n", .{ prg_path, 28 + expected_len });
}

const SectionSizes = struct { text: u32, data: u32, bss: u32 };

fn getStartVma(alloc: Allocator, io: std.Io, elf_path: []const u8) !u32 {
    const out = try runCmd(alloc, io, &.{ "m68k-elf-nm", elf_path });
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        const addr = tok.next() orelse continue;
        const kind = tok.next() orelse continue;
        const name = tok.next() orelse continue;
        if (std.mem.eql(u8, kind, "T") and std.mem.eql(u8, name, "_start"))
            return std.fmt.parseInt(u32, addr, 16);
    }
    return error.StartNotFound;
}

fn getSectionSizes(alloc: Allocator, io: std.Io, elf_path: []const u8) !SectionSizes {
    const out = try runCmd(alloc, io, &.{ "m68k-elf-size", "-A", elf_path });
    var sizes = SectionSizes{ .text = 0, .data = 0, .bss = 0 };
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        const name = tok.next() orelse continue;
        const size_str = tok.next() orelse continue;
        const size = std.fmt.parseInt(u32, size_str, 10) catch continue;
        if (std.mem.eql(u8, name, ".text")) sizes.text = size;
        if (std.mem.eql(u8, name, ".data")) sizes.data = size;
        if (std.mem.eql(u8, name, ".bss")) sizes.bss = size;
    }
    return sizes;
}

fn extractBinary(alloc: Allocator, io: std.Io, elf_path: []const u8) ![]u8 {
    const tmp = "prgify_tmp.bin";
    defer Dir.deleteFile(Dir.cwd(), io, tmp) catch {};
    _ = try runCmd(alloc, io, &.{ "m68k-elf-objcopy", "-O", "binary", elf_path, tmp });
    return Dir.readFileAlloc(Dir.cwd(), io, tmp, alloc, std.Io.Limit.limited(10 * 1024 * 1024));
}

fn runCmd(alloc: Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(1024 * 1024),
    });
    return result.stdout;
}
