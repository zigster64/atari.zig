//! GEMZ "DAF" — a Deutsch Amerikanische Freundschaft themed demo.
//!
//! A window with a black background (a filled object-tree box), the white DAF
//! banner (bitmap from `logo_daf.zig`), and a vertical list of DAF track
//! buttons. The last button ("Close") closes the app. Track buttons are the
//! hooks for the YM2149 bassline experiments.

const gemz = @import("gemz");
const logo_daf = @import("logo_daf.zig");

// Statically allocate the app with max views / max objects per view.
const MyApp = gemz.App(1, 16);

// White "DAF" banner, 96 pixels high (176x96). Drawn as a G_IMAGE object, so
// no VDI involvement.
const DAF_LOGO = gemz.BitBlk.from(&logo_daf.DAF96, .white);

// Full "Der Mussolini" arrangement: bassline (tone, A) from rep 1; kick (noise,
// B) and snare + hi-hat (noise, C) enter at rep 3; all stop after rep 12.
// TODO tech debt - sounds ok at 100bpm, terrible below that, with notes running into each other
const mussolini_notes = "e1 b0 d2 b0, b1 b0 b0 b1, b0 b1 b0 b1, a1 b0 b1 b0";
const mussoliniSong = [_]gemz.Part{
    // Das bassline, with a pitch shift in the middle (down a major third).
    .{ .channel = .A, .notes = mussolini_notes, .volume = 15, .from_rep = 1, .to_rep = 4 },
    .{ .channel = .A, .notes = gemz.transpose(mussolini_notes, -4), .volume = 15, .from_rep = 5, .to_rep = 6 },
    .{ .channel = .A, .notes = mussolini_notes, .volume = 15, .from_rep = 7, .to_rep = 8 },
    .{ .channel = .A, .notes = gemz.transpose(mussolini_notes, 2), .volume = 15, .from_rep = 9, .to_rep = 10 },
    .{ .channel = .A, .notes = mussolini_notes, .volume = 15, .from_rep = 11, .to_rep = 12 },
    // Den Drum Kick starts on the 3rd rep
    .{ .channel = .B, .notes = "k . . . k . . . k . . . k . . k", .volume = 15, .from_rep = 3, .to_rep = 12 },
    // Und denn das Hat und Snare drum muss gepoken its fingerpicken in den song spielen !
    .{ .channel = .C, .notes = "h h h h s h h h h h h h s h h h", .volume = 8, .from_rep = 5, .to_rep = 12 },
};

fn mussolini(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Der Mussolini|DAF - Alles ist gut (1981)", " Play | Close ")) {
        1 => app.playSong(mussoliniSong, 90), // 80 bpm = 750 ms/step (calibrated: 4000/bpm in armCore)
        else => {},
    }
    return true;
}

fn rauber(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Rauber und der Prinz|DAF - Alles ist gut (1981)", " Play | Close ")) {
        // Note - the leading steps with - suffix are half-notes (double steps - so the tone is played for a double duration of 2 steps)
        // Musical notation sucks .. Each set of 4 "steps" here = "1 note" .. so a "half note" actually means 1 beep at double duration ... mkay ?
        1 => app.loop(.A, "d2- d1- f1- d1- g1- d1- a1 g1 f1 d1", 100, 15),
        else => {},
    }
    return true;
}

fn verschwende(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Verschwende deine Jugend|DAF - Alles ist gut (1981)", " Play | Close ")) {
        1 => app.loop(.A, "bb3- c3 g3 c3- bb3 c3 g3- bb3 eb3 bb3- g3 bb3", 130, 15),
        else => {},
    }
    return true;
}

fn liebe(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Liebe aus dem ersten Blick|DAF - Fur immer (1982)", " Play | Close ")) {
        1 => app.loop(.A, "e1- e2- g1- e2- a1- e2- g1- e1-", 120, 15),
        else => {},
    }
    return true;
}

const satoSong = [_]gemz.Part{
    .{ .channel = .A, .notes = "a1 . a1 c2  a1 . g1 a1  a1 . a1 f1  g1 . e1 g1", .volume = 15, .from_rep = 1, .to_rep = 16 },
    .{ .channel = .B, .notes = "k . . . k . . . k . . . k . . .", .volume = 15, .from_rep = 2, .to_rep = 16 },
    .{ .channel = .C, .notes = ". . h . s . h . . . h . s . h .", .volume = 15, .from_rep = 3, .to_rep = 16 },
};
fn sato(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Sato Sato|DAF - Alles ist gut (1981)", " Play | Close ")) {
        1 => app.playSong(satoSong, 90),
        else => {},
    }
    return true;
}

fn tot(app: *MyApp) bool {
    switch (app.form_choice(.default_button, "Ich bin Tot|DAF - Alles ist gut (1981)", " Play | Close ")) {
        1 => app.loop(.A, "e1 e2 g1 e2 a1 e2 g1 e2 e1 e2 g1 e2 b1 e2 a1 g1", 116, 15),
        else => {},
    }
    return true;
}

fn close(_: *MyApp) bool {
    return false;
}

export fn _start() callconv(.c) noreturn {
    gemz.start();
}

pub fn main() !void {
    var app = try MyApp.init();
    defer app.exit();

    try app.open(.{
        .kind = .{ .name = true, .closer = true, .mover = true },
        .title = "Deutsch Amerikanische Freundschaft",
        .x = 40,
        .y = 20,
        .w = 320,
        .h = 380,
    }, &.{
        .filledBox(320, 380, .black),
        .image(&DAF_LOGO, 72, 8, 176, 96),
        // .image(gemz.eqBitBlk(), 44, 110, 232, 12),
        .button(" Der Mussolini ", 45, 130, 230, 24, .selectable, &.{.{ .click = mussolini }}),
        .button(" Rauber und der Prinz ", 45, 162, 230, 24, .selectable, &.{.{ .click = rauber }}),
        .button(" Verschwende deine Jugend ", 45, 194, 230, 24, .selectable, &.{.{ .click = verschwende }}),
        .button(" Liebe aus dem ersten Blick ", 45, 226, 230, 24, .selectable, &.{.{ .click = liebe }}),
        .button(" Sato Sato ", 45, 258, 230, 24, .selectable, &.{.{ .click = sato }}),
        .button(" Ich bin Tot ", 45, 290, 230, 24, .selectable, &.{.{ .click = tot }}),
        .button(" Close ", 45, 322, 230, 24, .flags(&.{ .selectable, .exit }), &.{.{ .click = close }}),
    });

    app.run();
}
