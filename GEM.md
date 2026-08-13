# GEM — Graphics Environment Manager

> Working notes on the GEM function surface for Atari ST programming.
> This document catalogues what GEM *exports*: the AES and VDI call sets,
> their opcodes, parameter blocks, and calling conventions.
>
> **Canonical in-tree reference:** `libs/toslibc/include/toslibc/tos/`
> (`aes-call.h`, `vdi-call.h`, `xgemdos-call.h`, `trap.S`). The tables below
> are transcribed from those headers.

---

## What GEM is

GEM is the Atari ST's windowing / graphical user environment. It is **not** a
single API — it is two distinct subsystems, both dispatched through the same
`trap #2` (XGEMDOS) vector, distinguished only by an opcode word:

| Subsystem | Meaning | Role |
|-----------|---------|------|
| **AES** | Application Environment Services | Windows, menus, event loop, dialogs/forms, object trees, graphics primitives, file selector, resource loading, shell interaction |
| **VDI** | Virtual Device Interface | Low-level, device-independent drawing: lines, markers, text, filled areas, rasters, attribute queries |

The layering is important: an application talks to the **AES** for its UI
(windows, events, menus) and reaches down to the **VDI** for actual drawing
when the AES's higher-level objects are insufficient.

GEM sits *above* the operating-system traps:

```
Application
   │  trap #2  (XGEMDOS)
   ├── AES  (d0 = $C8)   ── window/event/dialog/menu/shell services
   └── VDI  (d0 = $73)   ── device-independent graphics primitives
        │
        └── GEMDOS (trap #1), BIOS/XBIOS (trap #13/#14)
```

---

## Calling convention

Both AES and VDI are entered with `trap #2`. The dispatcher selects the
subsystem from an opcode word. The XGEMDOS opcodes (from
`tos/xgemdos-call.h`) are:

| Opcode | Name | Purpose |
|--------|------|---------|
| `0x00` | `reset` | Cold reset the machine |
| `0x73` | `vdi` | VDI call (115) |
| `0xC8` | `aes` | AES call (200) |
| `0xFE` | `gdos_version` | Query GDOS version |

### AES entry

```
move.l  pb, d1        ; d1 = address of the AES parameter block
move.w  #$C8, d0      ; d0 = AES opcode (200)
trap    #2
```

This is the convention used by `hello/src/main.zig` and `hello/src/our.zig`
in this repo.

### VDI entry

```
; contrl = 12-word control array, vdipb = 5-pointer parameter block
move.w  #$73, d0      ; d0 = VDI opcode (115)
trap    #2
```

> **Note on pointer-passing registers.** The exact register used to pass the
> parameter-block / control-array pointer varies between bindings and eras of
> documentation. The two conventions observed in this tree:
>
> 1. **Opcode in `d0`, pointer in `d1`** — used by this repo's Zig code for
>    AES (`d1` = `&aes_pb`) and by toslibc's `xgemdos_vdi` wrapper (`d1` =
>    `&vdi_pb`).
> 2. **Opcode pushed on the stack** — used by toslibc's `xgemdos.S`
>    (`move.w #opcode, -(sp); trap #2`).
>
> TOS accepts both; the essential, agreed core is `trap #2` + the opcode word.
> (Confirm the VDI `a0`/`a1` split against the Atari Compendium when we get to
> writing the Zig VDI bindings.)

---

## AES — Application Environment Services

### Parameter block

AES takes one pointer (`d1`) to a parameter block of six pointers:

```
aes_pb:
    control   → 5 words:  opcode, n_int_in, n_int_out, n_addr_in, n_addr_out
    global    → version, app_max, app_id, user, rsc, reserved[4]
    int_in    → input integers  (word array)
    int_out   → output integers (word array)
    addr_in   → input pointers  (long array)
    addr_out  → output pointers (long array)
```

- `control.opcode` is the function number (the "opcode" in the table below).
- `global.app_id` is written by `appl_init` and must persist for the app's
  lifetime (see `GLOBAL` in `hello/src/main.zig`).
- `int_out[0]` is the implicit AES return code; declared output integers begin
  at index 1. Up to 7 output integers are supported per call.

The struct layouts are mirrored in `libs/toslibc/include/toslibc/tos/aes.h`
(`struct aes_control`, `struct aes_global`, `struct aes_pb`) and, in Zig,
in `hello/src/main.zig` / `hello/src/our.zig`.

### Function catalog

Opcode → name → C signature (from `tos/aes-call.h`). Grouped by subsystem.

#### Application management (`appl_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 10 | `appl_init` | `int16 appl_init(void)` |
| 11 | `appl_read` | `int16 appl_read(int16 ap_id, int16 length, void *message)` |
| 12 | `appl_write` | `int16 appl_write(int16 ap_id, int16 length, const void *message)` |
| 13 | `appl_find` | `int16 appl_find(const char *fname)` |
| 19 | `appl_exit` | `int16 appl_exit(void)` |

#### Event handling (`evnt_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 20 | `evnt_keybd` | `int16 evnt_keybd(void)` |
| 21 | `evnt_button` | `int16 evnt_button(int16 clicks, int16 mask, int16 state, int16 *mx, int16 *my, int16 *button, int16 *kstate)` |
| 22 | `evnt_mouse` | `int16 evnt_mouse(int16 flag, int16 x, int16 y, int16 w, int16 h, int16 *mx, int16 *my, int16 *button, int16 *kstate)` |
| 23 | `evnt_mesag` | `int16 evnt_mesag(struct aes_mesag *mesag)` |
| 24 | `evnt_timer` | `int16 evnt_timer(int16 locount, int16 hicount)` |
| 25 | `evnt_multi` | `int16 evnt_multi(int16 events, int16 bclicks, int16 bmask, int16 bstate, int16 m1flag, int16 m1x, int16 m1y, int16 m1w, int16 m1h, int16 m2flag, int16 m2x, int16 m2y, int16 m2w, int16 m2h, int16 *message, int16 locount, int16 hicount, int16 *mx, int16 *my, int16 *mb, int16 *ks, int16 *kc, int16 *mc)` |
| 26 | `evnt_dclick` | `int16 evnt_dclick(int16 new_, int16 flag)` |

#### Menu bar (`menu_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 30 | `menu_bar` | `int16 menu_bar(struct aes_object *tree, int16 mode)` |
| 31 | `menu_icheck` | `int16 menu_icheck(struct aes_object *tree, int16 obj, int16 check)` |
| 32 | `menu_ienable` | `int16 menu_ienable(struct aes_object *tree, int16 obj, int16 flag)` |
| 33 | `menu_tnormal` | `int16 menu_tnormal(struct aes_object *tree, int16 obj, int16 flag)` |
| 34 | `menu_text` | `int16 menu_text(struct aes_object *tree, int16 obj, const char *text)` |
| 35 | `menu_register` | `int16 menu_register(int16 ap_id, const char *title)` |

#### Object trees (`objc_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 42 | `objc_draw` | `int16 objc_draw(struct aes_object *tree, int16 obj, int16 depth, int16 ox, int16 oy, int16 ow, int16 oh)` |
| 43 | `objc_find` | `int16 objc_find(struct aes_object *tree, int16 obj, int16 depth, int16 ox, int16 oy)` |
| 44 | `objc_offset` | `int16 objc_offset(struct aes_object *tree, int16 obj, int16 *ox, int16 *oy)` |
| 45 | `objc_order` | `int16 objc_order(struct aes_object *tree, int16 obj, int16 pos)` |
| 46 | `objc_edit` | `int16 objc_edit(struct aes_object *tree, int16 obj, int16 kc, int16 *idx, int16 mode)` |
| 47 | `objc_change` | `int16 objc_change(struct aes_object *tree, int16 obj, int16 rsvd, int16 ox, int16 oy, int16 ow, int16 oh, int16 newstate, int16 drawflag)` |

#### Forms, dialogs, alerts (`form_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 50 | `form_do` | `int16 form_do(struct aes_object *tree, int16 editobj)` |
| 51 | `form_dial` | `int16 form_dial(int16 mode, int16 x1, int16 y1, int16 w1, int16 h1, int16 x2, int16 y2, int16 w2, int16 h2)` |
| 52 | `form_alert` | `int16 form_alert(int16 exit_button, const char *format)` |
| 53 | `form_error` | `int16 form_error(int16 error)` |
| 54 | `form_center` | `int16 form_center(struct aes_object *tree, int16 *x, int16 *y, int16 *w, int16 *h)` |

##### The five `form_` functions (the "form versions")

| Function | Opcode | Purpose |
|----------|-------:|---------|
| `form_do` | 50 | Run the modal interaction loop over an object tree — the general-purpose dialog engine |
| `form_dial` | 51 | Reserve / draw / free the screen rectangles for a dialog (4 modes) |
| `form_alert` | 52 | Show a simple modal alert from a compact format string |
| `form_error` | 53 | Map an errno value to a canned alert string |
| `form_center` | 54 | Compute the x/y/w/h that centres a dialog on screen |

`form_alert` and `form_error` are the string-driven, quick-and-simple alerts.
`form_do` + `form_dial` + `form_center` are the general path, built on object
trees (the same `struct aes_object` used by `objc_*` and `menu_*`) — these can
express disabled buttons, checkboxes, radio groups, editable text fields, and
custom drawing, which `form_alert` cannot.

##### `form_alert` — icons and buttons

`form_alert(exit_button, format)` is the workhorse for simple dialogs. `format`
is one NUL-terminated string of three `[...]` fields:

```
[icon][text][buttons]
```

- `int_in[0]` (`exit_button`) — the default button, 1-based, or `0` for none.
- returns `int_out[0]` — the 1-based index of the button the user clicked.

**Icon options** (first field, one digit 0–3):

| Value | Icon |
|------:|------|
| 0 | none — text only |
| 1 | exclamation / note |
| 2 | question |
| 3 | stop (hand) |

These map to toslibc's `AES_FORM_ICON_NONE / _EXCLAMATION / _QUESTION / _STOP`
(`libs/toslibc/include/toslibc/tos/aes.h`).

**Button options** (last field):

- **1–3 buttons**, labels separated by `|` (a single button needs no separator).
- The label text *is* the visible caption; pad with spaces to control width:
  `[ OK ]`, `[ Yes ][ No ]`, `[One|Two|Three]`.
- All buttons render at the **same width** (the widest label), left→right.
- Buttons are plain push-buttons — **no disabled / checkbox / radio state**
  (that requires `form_do` with an object tree).
- The **default button** (the `exit_button` arg) is highlighted and triggered
  by Return; clicking any button returns its 1-based index.

**Text field** (middle `[...]`): 1–5 lines, separated by `|`.

| Limit | Value |
|-------|-------|
| Icons | 0–3 |
| Buttons | 1–3 |
| Text lines | 1–5 |
| Default button | 1-based, or 0 for none |
| Return value | 1-based clicked-button index |

Full example — `exit_button = 3` highlights "Cancel"; clicking "Yes"→1, "No"→2,
"Cancel"→3:

```
[2][Save changes before quitting?|(unsaved work will be lost)][ Yes ][ No ][Cancel]
```

##### `form_dial`, `form_do`, `form_center` (object-tree dialogs)

- `form_dial(mode, x1, y1, w1, h1, x2, y2, w2, h2)` — 4 modes:
  `0` start (save screen, grow boxes from rect1→rect2), `1` grow (draw rect2),
  `2` shrink (boxes rect2→rect1), `3` finish (restore saved screen).
- `form_do(tree, editobj)` — enter the modal loop; `editobj` is the object to
  give the text cursor (`0` = none). Returns the object that ended the dialog
  (typically the pressed button's object index).
- `form_center(tree, &x, &y, &w, &h)` — writes the centred rectangle for the
  tree's current size.

#### Graphics primitives / cursor (`graf_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 70 | `graf_rubberbox` | `int16 graf_rubberbox(int16 bx, int16 by, int16 minw, int16 minh, int16 *endw, int16 *endh)` |
| 71 | `graf_dragbox` | `int16 graf_dragbox(int16 w, int16 h, int16 sx, int16 sy, int16 bx, int16 by, int16 bw, int16 bh, int16 *endx, int16 *endy)` |
| 72 | `graf_movebox` | `int16 graf_movebox(int16 bw, int16 bh, int16 sx, int16 sy, int16 ex, int16 ey)` |
| 73 | `graf_growbox` | `int16 graf_growbox(int16 x1, int16 y1, int16 w1, int16 h1, int16 x2, int16 y2, int16 w2, int16 h2)` |
| 74 | `graf_shrinkbox` | `int16 graf_shrinkbox(int16 x1, int16 y1, int16 w1, int16 h1, int16 x2, int16 y2, int16 w2, int16 h2)` |
| 75 | `graf_watchbox` | `int16 graf_watchbox(struct aes_object *tree, int16 obj, int16 instate, int16 outstate)` |
| 76 | `graf_slidebox` | `int16 graf_slidebox(struct aes_object *tree, int16 parent, int16 obj, int16 orient)` |
| 77 | `graf_handle` | `int16 graf_handle(int16 *wcell, int16 *hcell, int16 *wbox, int16 *hbox)` |
| 78 | `graf_mouse` | `int16 graf_mouse(int16 mode, void *form)` |
| 79 | `graf_mkstate` | `int16 graf_mkstate(int16 *mx, int16 *my, int16 *mb, int16 *ks)` |

#### File selector (`fsel_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 90 | `fsel_input` | `int16 fsel_input(const char *path, const char *file, int16 *button)` |

#### Window management (`wind_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 100 | `wind_create` | `int16 wind_create(int16 kind, int16 x, int16 y, int16 w, int16 h)` |
| 101 | `wind_open` | `int16 wind_open(int16 handle, int16 x, int16 y, int16 w, int16 h)` |
| 102 | `wind_close` | `int16 wind_close(int16 handle)` |
| 103 | `wind_delete` | `int16 wind_delete(int16 handle)` |
| 104 | `wind_get` | `int16 wind_get(int16 handle, int16 mode, int16 *parm1, int16 *parm2, int16 *parm3, int16 *parm4)` |
| 105 | `wind_set` | `int16 wind_set(int16 handle, int16 mode, int16 parm1, int16 parm2, int16 parm3, int16 parm4)` |
| 106 | `wind_find` | `int16 wind_find(int16 x, int16 y)` |
| 107 | `wind_update` | `int16 wind_update(int16 mode)` |
| 108 | `wind_calc` | `int16 wind_calc(int16 request, int16 kind, int16 x1, int16 y1, int16 w1, int16 h1, int16 *x2, int16 *y2, int16 *w2, int16 *h2)` |

#### Resource management (`rsrc_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 110 | `rsrc_load` | `int16 rsrc_load(const char *fname)` |
| 111 | `rsrc_free` | `int16 rsrc_free(void)` |
| 112 | `rsrc_gaddr` | `int16 rsrc_gaddr(int16 type, int16 index, void **addr)` |
| 113 | `rsrc_saddr` | `int16 rsrc_saddr(int16 type, int16 index, void *addr)` |

#### Shell / desktop (`shel_`)

| Opcode | Function | Signature |
|-------:|----------|-----------|
| 120 | `shel_read` | `int16 shel_read(const char *name, const char *tail)` |
| 121 | `shel_write` | `int16 shel_write(int16 mode, int16 wisgr, int16 wiscr, const char *cmd, const char *tail)` |
| 124 | `shel_find` | `int16 shel_find(const char *buf)` |
| 125 | `shel_envrn` | `int16 shel_envrn(char **value, const char *name)` |

---

## VDI — Virtual Device Interface

### Parameter block

VDI uses a 12-word **control array** (`contrl`) plus four data arrays:

```
contrl (12 words):
    opc       function opcode
    ptsin     number of input  vertices in ptsin
    ptsout    number of output vertices in ptsout
    intin     number of input  integers in intin
    intout    number of output integers in intout
    sub       sub-opcode (for opc 5 "escape" and 11 "GDP")
    vdi_id    workstation handle
    specific[5]  function-specific words

data arrays:
    intin[128]    input integers
    ptsin[128]    input  points  (x,y pairs)
    intout[128]   output integers
    ptsout[128]   output points  (x,y pairs)
```

`opc`, `ptsin`, `intin`, `sub` and `vdi_id` are filled in by the application;
`ptsout` and `intout` are filled in by the VDI. See `struct vdi_contrl` /
`struct vdi_pb` in `libs/toslibc/include/toslibc/tos/vdi.h`.

The five pointers are bundled into `struct vdi_pb`:
`{ contrl, intin, ptsin, intout, ptsout }` (note the ordering differs from the
AES block).

### Function catalog

Opcode → sub-opcode → name (from `tos/vdi-call.h`). The leading `v_`/`vq_`/
`vs_`/`vst_`… prefixes follow the classic VDI naming: `v_` = action, `vq_` =
inquiry, `vs_` = set attribute.

#### Workstation control

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 1 | 0 | `v_opnwk` | Open virtual workstation |
| 2 | 0 | `v_clswk` | Close workstation |
| 3 | 0 | `v_clrwk` | Clear workstation |
| 4 | 0 | `v_updwk` | Update workstation |
| 100 | 0 | `v_opnvwk` | Open physical workstation |
| 101 | 0 | `v_clsvwk` | Close virtual workstation |

#### Output primitives

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 6 | 0 | `v_pline` | Polyline |
| 7 | 0 | `v_pmarker` | Polymarker |
| 8 | 0 | `v_gtext` | Graphics text |
| 9 | 0 | `v_fillarea` | Filled area (polygon) |
| 10 | 0 | `v_cellarray` | Cell array (raster) |
| 11 | 1 | `v_bar` | Filled rectangle |
| 11 | 2 | `v_arc` | Arc |
| 11 | 3 | `v_pieslice` | Filled pie slice |
| 11 | 4 | `v_circle` | Circle outline |
| 11 | 5 | `v_ellipse` | Ellipse outline |
| 11 | 6 | `v_ellarc` | Elliptical arc |
| 11 | 7 | `v_ellpie` | Filled elliptical pie |
| 11 | 8 | `v_rbox` | Rounded rectangle outline |
| 11 | 9 | `v_rfbox` | Filled rounded rectangle |
| 11 | 10 | `v_justified` | Justified graphics text |

#### Attribute setting

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 12 | 0 | `vst_height` | Set text height |
| 13 | 0 | `vst_rotation` | Set text rotation |
| 14 | 0 | `vs_color` | Set colour index |
| 15 | 0 | `vsl_type` | Set line type |
| 16 | 0 | `vsl_width` | Set line width |
| 17 | 0 | `vsl_color` | Set line colour |
| 18 | 0 | `vsm_type` | Set marker type |
| 19 | 0 | `vsm_height` | Set marker height |
| 20 | 0 | `vsm_color` | Set marker colour |
| 21 | 0 | `vst_font` | Set text face/font |
| 22 | 0 | `vst_color` | Set text colour |
| 23 | 0 | `vsf_interior` | Set fill interior style |
| 24 | 0 | `vsf_style` | Set fill style/pattern |
| 25 | 0 | `vsf_color` | Set fill colour |
| 39 | 0 | `vst_alignment` | Set text alignment |
| 104 | 0 | `vsf_perimeter` | Set fill perimeter visibility |
| 106 | 0 | `vst_effects` | Set text effects |
| 107 | 0 | `vst_point` | Set text point size |
| 108 | 0 | `vsl_ends` | Set line end caps |
| 111 | 0 | `vsc_form` | Set colour transform |
| 112 | 0 | `vsf_udpat` | Set user-defined fill pattern |
| 113 | 0 | `vsl_udsty` | Set user-defined line style |
| 129 | 0 | `vs_clip` | Set clipping rectangle |

#### Inquiry

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 5 | 0–19 | `vq_…` / `v_…` | Escape (misc.): character cells, cursor movement/addressing, text cursor, reverse video, hardcopy, etc. |
| 26 | 0 | `vq_color` | Inquire colour representation |
| 27 | 0 | `vq_cellarray` | Inquire cell-array attributes |
| 35 | 0 | `vql_attributes` | Inquire line attributes |
| 36 | 0 | `vqm_attributes` | Inquire marker attributes |
| 37 | 0 | `vqf_attributes` | Inquire fill attributes |
| 38 | 0 | `vqt_attributes` | Inquire text attributes |
| 102 | 0 | `vq_extnd` | Inquire extended info |
| 115 | 0 | `vqin_mode` | Inquire input mode |
| 116 | 0 | `vqt_extent` | Inquire text extent |
| 117 | 0 | `vqt_width` | Inquire text width |
| 124 | 0 | `vq_mouse` | Inquire mouse state |
| 128 | 0 | `vq_key_s` | Inquire key state |
| 130 | 0 | `vqt_name` | Inquire font name |
| 131 | 0 | `vqt_fontinfo` | Inquire font info |

#### Input (locator/valuator/choice/string)

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 28 | 0 | `v_locator` | Request locator (mouse) input |
| 29 | 0 | `v_valuator` | Request valuator input |
| 30 | 0 | `v_choice` | Request choice input |
| 31 | 0 | `v_string` | Request string input |
| 32 | 0 | `vswr_mode` | Set writing mode |
| 33 | 0 | `vsin_mode` | Set input mode |

#### Raster / transformation / extended

| Opcode | Sub | Function | Purpose |
|-------:|----:|----------|---------|
| 103 | 0 | `v_contourfill` | Contour fill |
| 105 | 0 | `v_get_pixel` | Read pixel |
| 109 | 0 | `vro_cpyfm` | Copy raster (opaque) |
| 110 | 0 | `vr_trnfm` | Transform raster |
| 114 | 0 | `vr_recfl` | Fill rectangle (raster) |
| 118 | 0 | `vex_timv` | Exchange timer vector |
| 119 | 0 | `vst_load_fonts` | Load fonts |
| 120 | 0 | `vst_unload_fonts` | Unload fonts |
| 121 | 0 | `vrt_cpyfm` | Copy raster (transparent) |
| 122 | 0 | `v_show_c` | Show cursor |
| 123 | 0 | `v_hide_c` | Hide cursor |
| 125 | 0 | `vex_butv` | Exchange button-change vector |
| 126 | 0 | `vex_motv` | Exchange mouse-movement vector |
| 127 | 0 | `vex_curv` | Exchange cursor-change vector |

---

## Source cross-reference

| Concern | File |
|---------|------|
| AES function table (opcodes, signatures) | `libs/toslibc/include/toslibc/tos/aes-call.h` |
| AES structs, enums (window modes, message types, mouse shapes) | `libs/toslibc/include/toslibc/tos/aes.h` |
| VDI function table (opcodes, sub-opcodes) | `libs/toslibc/include/toslibc/tos/vdi-call.h` |
| VDI structs (`contrl`, `vdi_pb`, workstation info) | `libs/toslibc/include/toslibc/tos/vdi.h` |
| XGEMDOS opcodes (`$73` VDI, `$C8` AES, `$FE` GDOS) | `libs/toslibc/include/toslibc/tos/xgemdos-call.h` |
| Trap #2 dispatcher macro | `libs/toslibc/include/toslibc/tos/trap.S` |
| AES/VDI trap wrappers in assembly | `libs/toslibc/lib/xgemdos.S` |
| VDI C helper implementations | `libs/toslibc/lib/vdi.c` |
| Zig AES example (trap #2, `d0=$C8`) — build target | `hello/src/main.zig` |
| Zig AES example (wind/evnt wrappers) — **orphaned**, not wired into `build.zig` | `hello/src/our.zig` |

---

## Open questions / next steps

- [ ] Confirm the VDI pointer-passing registers (`a0`/`a1` vs `d1`) against the
      Atari Compendium / toshyp before writing the Zig VDI binding.
- [ ] Decide the idiomatic Zig wrapper shape: opcode enums + a typed
      parameter-block builder, mirroring the `aes_call` helper already in
      `hello/src/our.zig`.
- [ ] Map the AES `struct aes_object` / `struct aes_mesag` layouts (currently a
      `FIXME` in toslibc) for object-tree and message handling.
- [ ] Decide whether the VDI function list should be generated from
      `vdi-call.h` or hand-maintained (risk of drift).
