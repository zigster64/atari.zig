//! GEMZ "SPACE" — Space Invaders, finished: low-res 320x200, double buffered.
//!
//! Left/Right arrows move the player, Space fires, Esc quits back to the
//! desktop. Invaders march side to side and drop a row on each edge hit;
//! hitting the player's row ends the game. The whole frame is re-drawn into
//! the back buffer each frame (the fillRect-based erase miscompiles —
//! M68K_NOTES #19), then `vsync; flip` presents it.

const gemz = @import("gemz");
const screen = @import("screen");
const sprites = @import("space_sprites");

// ---------------------------------------------------------------------------
// Game colours (raw hardware indices into the installed palette)
// ---------------------------------------------------------------------------

const BG: u8 = 1; // black (this palette maps 1 -> black)
const INV_COLOR: u8 = 0; // white
const PLAYER_COLOR: u8 = 5; // cyan
const BULLET_COLOR: u8 = 2; // red

const PALETTE = [_]u16{
    0x777, // 0 white
    0x000, // 1 black
    0x700, // 2 red
    0x070, // 3 green
    0x007, // 4 blue
    0x077, // 5 cyan
    0x770, // 6 yellow
    0x707, // 7 magenta
    0x555, // 8 gray
    0x333, // 9 dark gray
    0x666, // 10 light gray
    0x777, // 11
    0x777, // 12
    0x777, // 13
    0x777, // 14
    0x777, // 15
};

// Sprite scale: draw each sprite pixel as a 2x2 block (twice the on-screen
// width and height). The ascii art in `space_sprites` stays at 1x; all layout
// constants below derive from `w_px * SPRITE_SCALE` so collisions and grid
// spacing scale automatically.
const SPRITE_SCALE: u8 = 2;

// Sprite sizes drive the layout and the collision boxes.
const PLAYER_W: u16 = sprites.PLAYER.w_px * SPRITE_SCALE; // 26
const PLAYER_H: u16 = sprites.PLAYER.h_px * SPRITE_SCALE; // 16
// Bottom-anchored: the old fixed 190 left the bottom rows of the doubled
// sprite past the 200-row framebuffer (verified — the player's lower half
// simply didn't render).
const PLAYER_Y: u16 = 200 - PLAYER_H; // 184

const BULLET_W: u16 = sprites.BULLET.w_px * SPRITE_SCALE; // 6
const BULLET_H: u16 = sprites.BULLET.h_px * SPRITE_SCALE; // 14

const INV_W: u16 = sprites.INVADER_A.w_px * SPRITE_SCALE; // 22
const INV_H: u16 = sprites.INVADER_A.h_px * SPRITE_SCALE; // 16
const INV_COLS: u16 = 4;
const INV_ROWS: u16 = 3;
const INV_COUNT: u16 = INV_COLS * INV_ROWS;
const INV_STEP_X: u16 = INV_W + 9; // column spacing
const INV_STEP_Y: u16 = INV_H + 6; // row spacing
const GRID_W: u16 = INV_COLS * INV_STEP_X - 9;

const INV_STEP: u16 = 1; // move every frame
const INV_SPEED: u16 = 3; // 3 px per frame -> ~150 px/s (~4.5x the old pace)
const INV_DROP: u16 = 12; // pixels down on an edge hit (proportional to the new speed)

// ---------------------------------------------------------------------------
// Game state
// ---------------------------------------------------------------------------

const Game = struct {
    player_x: u16,
    inv_x: u16,
    inv_y: u16,
    inv_right: bool,
    dead: u16, // bit i = invader i dead (0..11)
    bullet_x: u16,
    bullet_y: u16,
    bullet_active: bool,
    step_timer: u16,
    frame: u16, // even = INVADER_A, odd = INVADER_B
};

noinline fn update(g: *Game) void {
    // March the invader grid every INV_STEP frames (countdown, no modulo).
    // The A/B animation frame flips exactly once per move, so the pose change
    // is synchronized with the step — flipping every frame while the grid
    // stands still looks like flickering in place ("4 animations then a
    // jump").
    if (g.step_timer == 0) {
        g.step_timer = INV_STEP - 1;
        g.frame += 1;
        if (g.inv_right) {
            g.inv_x += INV_SPEED;
            if (g.inv_x + GRID_W > screen.width - 8) {
                g.inv_right = false;
                g.inv_y += INV_DROP;
            }
        } else {
            g.inv_x -= INV_SPEED;
            if (g.inv_x < 8) {
                g.inv_right = true;
                g.inv_y += INV_DROP;
            }
        }
    } else {
        g.step_timer -= 1;
    }

    if (g.bullet_active) {
        if (g.bullet_y > BULLET_H) {
            g.bullet_y -= 6;
        } else {
            g.bullet_active = false;
        }

        // Collision: kill the first invader the bullet overlaps.
        if (g.bullet_active) {
            var i: u16 = 0;
            while (i < INV_COUNT) : (i += 1) {
                const bit: u16 = @as(u16, 1) << @intCast(i);
                // NEGATED for the btst branch inversion (M68K_NOTES #19): the
                // emitted skip fires when the bit is SET, so this skips dead
                // invaders and only alive ones are collision-tested below.
                if ((g.dead & bit) == 0) continue;
                const col = i & (INV_COLS - 1); // i % 4
                const row = i >> 2; // i / 4
                const ix = g.inv_x + col * INV_STEP_X;
                const iy = g.inv_y + row * INV_STEP_Y;
                if (g.bullet_x < ix + INV_W and
                    g.bullet_x + BULLET_W > ix and
                    g.bullet_y < iy + INV_H and
                    g.bullet_y + BULLET_H > iy)
                {
                    g.dead |= bit;
                    g.bullet_active = false;
                    break;
                }
            }
        }
    }
}

/// Game over when any invader reaches the player's row.
fn gameOver(g: *const Game) bool {
    return g.inv_y + (INV_ROWS - 1) * INV_STEP_Y + INV_H >= PLAYER_Y;
}

noinline fn draw(gfx: *screen.gfx.Gfx, g: *const Game) void {
    gfx.clear(@enumFromInt(@as(u16, BG))); // black field
    const base = @intFromPtr(gfx.ptr());

    var i: u16 = 0;
    while (i < INV_COUNT) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        // NEGATED for the btst branch inversion (M68K_NOTES #19): the emitted
        // skip fires when the bit is SET, so this skips dead invaders and only
        // alive ones are drawn below.
        if ((g.dead & bit) == 0) continue;
        const col = i & (INV_COLS - 1); // i % 4
        const row = i >> 2; // i / 4
        const ix = g.inv_x + col * INV_STEP_X;
        const iy = g.inv_y + row * INV_STEP_Y;
        // Flip the A/B pose every 4th move: the grid now moves every frame,
        // so a per-move flip would strobe at 25 Hz.
        if ((g.frame & 4) == 0) {
            screen.drawSprite(sprites.INVADER_A, .low, base, ix, iy, SPRITE_SCALE, INV_COLOR);
        } else {
            screen.drawSprite(sprites.INVADER_B, .low, base, ix, iy, SPRITE_SCALE, INV_COLOR);
        }
    }

    screen.drawSprite(sprites.PLAYER, .low, base, g.player_x, PLAYER_Y, SPRITE_SCALE, PLAYER_COLOR);

    if (g.bullet_active) {
        screen.drawSprite(sprites.BULLET, .low, base, g.bullet_x, g.bullet_y, SPRITE_SCALE, BULLET_COLOR);
    }
}

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var gfx = screen.gfx.lowRes();
    defer {
        gfx.restore();
        gemz.applExit();
    }
    screen.setPalette(&PALETTE);

    var game = Game{
        .player_x = screen.width / 2 - PLAYER_W / 2,
        .inv_x = 60,
        .inv_y = 24,
        .inv_right = true,
        .dead = 0,
        .bullet_x = 0,
        .bullet_y = 0,
        .bullet_active = false,
        .step_timer = 0,
        .frame = 0,
    };

    // The quit flag is accessed through a volatile pointer so it lives in
    // memory, not a register: the m68k backend keeps a plain local `quit` in
    // d4 across the whole frame and an interrupt (VBL etc.) can clobber d4
    // between the ESC handler and the loop check, silently losing the quit
    // (observed). Volatile access re-reads the flag from the stack every
    // iteration, so it cannot be lost.
    var quit: bool = false;
    const q: *volatile bool = &quit;
    while (!q.*) {
        // Drain queued keyboard events. `readKey` returns the scancode in the
        // low byte (normalized for both EmuTOS and TOS 1.x/2.x). Normalize
        // again defensively so the game behaves identically whichever build
        // produced the binary (an older copy can hand back the raw
        // `(scancode << 8)` value — observed: raw `0x4D00` with `k & 0xFF`
        // extracting 0x00 and ignoring every key).
        while (gemz.keyPressed()) {
            const k = gemz.readKey();
            var v = k;
            if (v > 0xFF) v >>= 8;
            const scancode: u8 = @intCast(v & 0xFF);
            if (scancode == 0x4B) { // left arrow
                if (game.player_x > 4) game.player_x -= 6;
            } else if (scancode == 0x4D) { // right arrow
                if (game.player_x < screen.width - PLAYER_W - 4) game.player_x += 6;
            } else if (scancode == 0x39) { // space
                if (!game.bullet_active) {
                    game.bullet_active = true;
                    game.bullet_x = game.player_x + PLAYER_W / 2 - BULLET_W / 2;
                    game.bullet_y = PLAYER_Y - BULLET_H;
                }
            } else if (scancode == 0x01) { // escape
                q.* = true;
            }
        }

        update(&game);
        if (gameOver(&game)) q.* = true;

        draw(&gfx, &game);
        gfx.vsync();
        gfx.flip();
    }

    gemz.dbg("SPACE: done");
}
