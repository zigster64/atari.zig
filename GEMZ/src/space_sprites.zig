//! GEMZ Space Invaders sprites — 1-bit art, packed at comptime by
//! `gemz.bitmap()`. `#` = set pixel, `.` = clear. All rows in a sprite are
//! the same width (the packer uses the first row's width).
//!
//! These are `gemz.Bitmap`s (row-major, MSB-first within each byte) ready to
//! wrap in a `gemz.Sprite`/`BitBlk` and blit into the framebuffer.

const gemz = @import("gemz");

/// Player ship (13x8).
pub const PLAYER = gemz.bitmap(&.{
    "......#......",
    ".....#.#.....",
    ".....#.#.....",
    "....#####....",
    "...#######...",
    "..#########..",
    ".###########.",
    "#############",
});

/// Invader, frame A — arms out (11x8).
pub const INVADER_A = gemz.bitmap(&.{
    "..#.....#..",
    "...#...#...",
    "..#######..",
    ".##.###.##.",
    "###########",
    "#.#######.#",
    "#.#.....#.#",
    "...##.##...",
});

/// Invader, frame B — arms down (11x8).
pub const INVADER_B = gemz.bitmap(&.{
    "..#.....#..",
    "###########",
    ".##.###.##.",
    "###########",
    "#.#######.#",
    "#.#.....#.#",
    "...#...#...",
    "..#.....#..",
});

/// Bullet (3x7).
pub const BULLET = gemz.bitmap(&.{
    "###",
    "###",
    "###",
    "###",
    "###",
    "###",
    "###",
});
