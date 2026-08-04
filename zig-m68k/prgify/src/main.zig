const std = @import("std");
const prgify = @import("prgify.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: {s} <input.elf> [output.prg]\n", .{args[0]});
        std.process.exit(1);
    }

    try prgify.convert(arena, init.io, args[1], if (args.len > 2) args[2] else "out.prg");
}
