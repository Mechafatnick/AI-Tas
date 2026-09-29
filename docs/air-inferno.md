# Air Inferno on the Taito Air core

Air Inferno (Taito, 1990) runs on the same Taito Air System board as Top
Landing. Its 68000 program, tiles and sprites already worked on this core;
what was missing was the 3D world, which the board's TMS320C25 DSP computes
and writes as polygon lists into line RAM for the polygon renderer. This note
records why the 3D did not appear, what was changed, and how the result was
checked against MAME. The changes themselves are tagged `[AI-n]` in the
sources; `docs/air-inferno-changes.md` lists them by tag and file.

## Why the 3D was missing

Air Inferno's DSP program leans on parts of the C25 and of the board's
custom maths block that Top Landing never touches:

* **C25 instructions.** The program uses many instructions the core did not
  implement (they were counted as illegal and skipped): ADRK/SBRK, ZALS,
  LACT, ADDC, ADDS, ADDT, SUBT, SUBB, RPT, LDP, LPH, PSHD, BITT, SQRS, MPYA,
  MPYS, MPYU, MPYK, ADDK/SUBK, SPL/SPH, SFR, PUSH, CALA, RC/SC/RTC/STC,
  ROL/ROR and EINT. ADDH/SUBH now set carry and overflow as MAME's tms32025
  does, and LAR into the current auxiliary register lets the load win over
  the address auto-modification.
* **The (A\*B)/C unit is signed.** 3404-3406 / 3408-340A take A, B and C;
  3407 / 340B read the quotient. The operands are signed 16-bit and the
  result truncates towards zero (C = 0 reads FFFF). The perspective divides
  feed it negative coordinates, e.g. (-200 \* -83) / 523 = 31.
* **There are two independent channels.** Air Inferno starts both before
  reading either, so one shared divider returned the wrong channel's result.

With those fixed the DSP's polygon lists match MAME's exactly, but the old
multi-cycle C25 finished a frame's 3D only every second frame, where MAME
manages every frame.

Air Inferno also uses the TC0080VCO's **FG0 text layer** (64x64 8x8
characters defined in RAM), which Top Landing does not; the core had no FG0
at all, so for instance the text in the cockpit monitor was missing.

## The faster C25

`rtl/cpu/tms320c25/tas_tms320c25.sv` is a new implementation with the same
architectural behaviour and a much shorter instruction time:

* the program address is driven combinationally with the word needed next,
  so sequential instructions need no fetch states;
* the C25's on-chip data RAM (0000-03FF) is an M10K inside the core, read and
  written straight from the decode of the instruction; only 0400 and above
  (line RAM, shared RAM, the custom peripherals) use the `tas_dsp` bus;
* register-only instructions and on-chip writes take 1 clock, on-chip reads
  and two-word instructions 2, board accesses 1 + the bus latency;
* RPT/RPTK re-execute from the instruction register without refetching.

Flat out, this core is roughly twice as fast as MAME's C25 (a 36 MHz part,
9 M machine cycles per second; the board's real DSP clock is unverified). As
the game then renders its 3D more often than MAME in the heavier scenes (in
the first stage every second frame instead of every third), the core paces
the C25 by default: with `throttle` set an instruction starts no earlier
than a 36 MHz C25 would reach it, using MAME's cycle counts. The OSD option
*DSP speed* switches between *Original* (paced, the default) and *Fast*
(flat out, smoother 3D in heavy scenes; the game's timing is not otherwise
affected in the scenes checked, since its motion is per video frame).

The previous (multi-cycle) core is kept as `tests/ref/tas_tms320c25_ref.sv`.
`make test-c25-diff` runs both cores on random C25 programs
(`tests/gen_c25_program.py`: every addressing mode against on-chip and board
RAM, branches, CALL/RET, BACC/CALA, RPT/RPTK, BLKD, BANZ loops, stack use)
with random bus latency and random HOLD, and requires the architectural state
after every instruction, every data write and the final memory to agree.

## FG0 text layer

`tas_fg0` (in `rtl/tas_video.sv`) draws FG0 at scanout from shadow copies of
its three VCO RAM areas, kept up to date from the 68000's writes (the VCO
RAM's video port belongs to the line builder):

* words 0000-07FF: characters, planes 1 (bits 15:8) and 2 (bits 7:0);
* words 0800-0FFF: the 64x64 map, two 8-bit codes per word (even column in
  the upper byte);
* words 8000-87FF: characters, plane 0 (bits 7:0).

Character c row r is word c*8+r, pixel x is bit 7-x of each plane, the pen
is {plane 0, plane 1, plane 2} with 0 transparent, and the colours are
palette 200-207. Map row 0 is the first visible line and there is no scroll.
This layout was checked against MAME's Air Inferno output. The layer order
is MAME's: BG0, the sprites before the pause marker, BG1, FG0, the remaining
sprites; line-buffer entries carry a bit marking the last sprite group so
that it stays above FG0. FG0 is only enabled for Air Inferno (MAME draws it
for Top Landing too, but that could not be checked here).

## Lines in the polygon lists

Air Inferno's lists are not only polygons. Read downwards from 3FFF, an item
whose first word has bit 15 set is a polygon (header, (y, x) pairs, one
delimiter word); an item whose first word has bit 15 clear is a **line**: a
colour word followed by y1, x1, y2, x2. The game draws the horizon, the sea
and runway markings and similar details as lines, often hundreds per frame
(479 in the rescue stage's tanker scene, most of them short runs along the
horizon), and a list may start with them.

MAME's renderer (and the core, which followed it) skips the words after a
polygon's delimiter up to the next header, which drops the lines but keeps
the parse aligned; a list that *starts* with lines, however, is read as one
polygon made of line endpoints. That is the large polygon floating in the
sky of the first rescue stage, in MAME as on the core.

With `line_items` set (Air Inferno), `tas_polygon` parses lines and draws
them one pixel wide with a Bresenham walk along the major axis, emitting a
span per scanline into the same span lists as the polygons, so they keep
their place in the painter's order and take terrain colours the same way.
For Top Landing the parser is unchanged. `make test-polygon-lines` checks a
list that starts with lines and mixes them with polygons (both walking
directions, both major axes, clipping at the right and bottom edges) against
a model, pixel for pixel; the same testbench run on the line RAM MAME's
tanker scene produced matches a reference (MAME's `fill_poly` for the
polygons, the same Bresenham walk for the lines) exactly. The lines add
about 12% of a frame to the time the renderer spends on that list (24% in
all), well inside the painter's per-line budget.

Reading a list takes the renderer a while (a copy also waits for vertical
blank), and the C25 must not overwrite the list meanwhile. For Top Landing
the C25 is held until the renderer is done, as before. Air Inferno's C25
needs about 93% of three frames for a list in the rescue stage (MAME spends
the remaining 7% in its wait loop), so holding it for the 24% of a frame the
tanker scene's list takes to read made it every fourth frame instead of
every third. For Air Inferno the renderer therefore publishes how far it
has read (`line_guard`: nothing while a list waits to be read, then its read
pointer, which runs downwards from 3FFF as the C25 writes the next list),
and only a C25 access to line RAM the renderer still has to read, or to the
list flags while it is busy, waits (and all of line RAM for the two clocks
between a list flag and the renderer taking the list). In the tanker scene
the C25 then never waits, renders every third frame as MAME does, and
spends the same time in its wait loop as in MAME: 130,565 clocks per list on
average over frames 1050-1150, against 130,579 for MAME's (its loop
iterations, at three cycles each, counted with a read tap).
`tb_polygon_lines` checks the guard with a producer that writes the next
list as fast as the guard allows while the renderer reads.

## Cockpit windows

The cockpit (BG1) draws the attitude indicator, the wind gauge and the
landing monitor's screen in colour 24 pen 15, which is black. The DSP draws
their contents as polygons behind the cockpit: the blue and brown attitude
ball, the gauge face, and, when Start switches the landing monitor on
during a stage, the view of a second camera looking down from the aircraft.
The arcade shows the polygons through those pixels; MAME draws them black,
so its instruments are empty and its landing monitor stays blank. The core
shows the polygon layer wherever the tile layers have colour 24 pen 15 and a
polygon is drawn (FG0 text stays in front). No other tile or sprite uses
that pen in the scenes checked (attract mode, stage select, the briefings,
the practice and rescue stages).

## Checking against MAME

MAME 0.264 was the reference. Lua scripts dumped the polygon lists at each
DSP flag write (3001/3002), injected coin and start presses and saved a
screenshot of every frame; `tests/tb_system.sv` runs the whole board (68000,
C25, video) on Air Inferno with the same inputs and writes the same polygon
lists (`+POLY_DUMP`), the polygon layer's pens (`+PEN_DUMP`) and frames.
Over 680 frames, from the attract mode's 3D flyover through the title,
stage select and briefing into the first seconds of stage 1 (DSP speed
Original):

* all 133 polygon lists MAME produced are identical in the core, at the
  same cadence (every frame in the attract mode, every third frame in the
  stage);
* the polygon pens are identical to a direct port of MAME's `fill_poly` /
  `fill_slope`;
* 672 frames are pixel-identical to MAME's screenshots. The other 9 are
  transitions: a palette flash and a scene cut where the core shows the
  board's live state part-way through a frame and MAME the state at the end
  of it, a couple of frames where text or the search-light beam appear one
  frame apart, and six frames at the start of the stage where MAME draws the
  ground grey: MAME decides whether a polygon takes terrain (gradient)
  colours when it fills the polygon, with the palette of that moment, while
  the core decides at display time, so it shows the new terrain palette as
  soon as the game writes it.

(That was before the lines and the cockpit windows, which now make the
stage frames differ from MAME's where MAME is wrong.) A second round covered
the first rescue stage (RESCUE on the stage select, chosen by holding the
yoke left: a read tap in MAME, `+STICK_X` in `tb_system`) and the practice
stage with the landing monitor switched on (`+START3_AT`):

* the 3D runs at MAME's cadence, list for list: every third frame in the
  tanker scene, every fourth with the landing monitor on;
* per list, the C25 spends as long in its wait loop as MAME's (see above);
  `tb_system +LIST_TIMING` reports this;
* the landing monitor shows the downward camera's view, the instruments
  their faces, and the tanker scene has no polygon in the sky.

## Game selection and controls

The MRAs carry a one-byte ROM entry at index 2: 0 for Top Landing, 1 for Air
Inferno. MRAs without it are recognised by the C25 program they stream at
index 1 (a Fletcher checksum of its 8 KB; the three Air Inferno sets share
the program), so older Air Inferno MRAs select Air Inferno too. It selects:

* the inputs: Air Inferno's IN1 carries cabinet buttons instead of the yoke
  end switches (bit order as MAME: lever, handle X, handle Y, fire, pedal R,
  pedal L);
* the yoke and throttle calibration. Air Inferno reads the same counters but
  adds half again to the yoke values (unless the service switch is on), has
  a +/-16 dead band and reaches full deflection at +/-40 of those values
  (raw +/-27); its throttle is clamped to +/-56, where -56 is full power and
  anything above +53 is idle;
* the polygon list grammar (lines) and the cockpit windows above;
* the Top Landing-only video adjustments (the cloud-sprite window, the
  left-edge fill and the pen $00d left-edge mask), which are off for Air
  Inferno, and the FG0 layer, which is on.

The buttons are Start, Coin, Throttle Up/Down, Fire, Lever, Pedal L/R and
Handle X/Y. The second start and the service coin are not wired. Test mode
(DIP SWA:3 in both games) is the OSD option *Service mode*, which restarts
the board when switched since the games read it at boot. The rudder pedals
only act with the DIP switch *Rudder Pedal* set to *With (Cockpit/DX)*
(the game then shows the pedals on screen); the Air Inferno MRAs default to
it, where MAME defaults to *Without*.

## ROMs

`releases/Air Inferno (World|US|Japan).mra` build the image from MAME's
`ainferno`, `ainfernou` and `ainfernoj` sets. `tools/build_rom.py --game
ainferno` builds the same image for the simulations, and `make test-mra`
checks the MRAs against it when the sets are unzipped under `roms/`.
