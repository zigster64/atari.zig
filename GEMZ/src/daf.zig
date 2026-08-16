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
const BANNER = gemz.BitBlk.from(&logo_daf.DAF96, .white);

fn mussolini(app: *MyApp) bool {
    app.form_alert(.default_button, "Der Mussolini|DAF - Alles ist gut (1981)");
    return true;
}

fn rauber(app: *MyApp) bool {
    app.form_alert(.default_button, "Rauber und der Prinz|DAF - Alles ist gut (1981)");
    return true;
}

fn verschwende(app: *MyApp) bool {
    app.form_alert(.default_button, "Verschwende deine Jugend|DAF - Alles ist gut (1981)");
    return true;
}

fn kebab(app: *MyApp) bool {
    app.form_alert(.default_button, "Kebab-Traume|DAF - Die Kleinen und die Bosen (1980)");
    return true;
}

fn sato(app: *MyApp) bool {
    app.form_alert(.default_button, "Sato Sato|DAF - Alles ist gut (1981)");
    return true;
}

fn alles(app: *MyApp) bool {
    app.form_alert(.default_button, "Alles ist gut|DAF - Alles ist gut (1981)");
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
        .y = 40,
        .w = 320,
        .h = 380,
    }, &.{
        .filledBox(320, 380, .black),
        .image(&BANNER, 72, 8, 176, 96),
        .button(" Der Mussolini ", 45, 130, 230, 24, .selectable, &.{.{ .click = mussolini }}),
        .button(" Rauber und der Prinz ", 45, 162, 230, 24, .selectable, &.{.{ .click = rauber }}),
        .button(" Verschwende deine Jugend ", 45, 194, 230, 24, .selectable, &.{.{ .click = verschwende }}),
        .button(" Kebab-Traume ", 45, 226, 230, 24, .selectable, &.{.{ .click = kebab }}),
        .button(" Sato Sato ", 45, 258, 230, 24, .selectable, &.{.{ .click = sato }}),
        .button(" Alles ist gut ", 45, 290, 230, 24, .selectable, &.{.{ .click = alles }}),
        .button(" Close ", 45, 322, 230, 24, .flags(&.{ .selectable, .exit }), &.{.{ .click = close }}),
    });

    app.run();
}
