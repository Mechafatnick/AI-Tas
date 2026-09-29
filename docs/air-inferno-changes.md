# Air Inferno changes, by tag

Every change made to the Taito Air core for Air Inferno is marked in the
sources with its tag, so a change can be found and ported on its own:

    grep -rn "\[AI-" TaitoAir.sv rtl tests/ref tools releases

Each changed file also lists its tags at the top. `docs/air-inferno.md`
explains the findings behind the changes and how they were checked against
MAME. Everything game-specific is switched by `game_ainferno` ([AI-8]), so
Top Landing behaves as before (apart from [AI-11]).

| Tag | Change | What it fixes in Air Inferno | Files |
| --- | --- | --- | --- |
| AI-1 | C25 instructions Air Inferno uses (ADRK/SBRK, ZALS, LACT, ADDC, ADDS, ADDT, SUBT, SUBB, RPT, LDP, LPH, PSHD, BITT, SQRS, MPYA, MPYS, MPYU, MPYK, ADDK/SUBK, SPL/SPH, SFR, PUSH, CALA, RC/SC/RTC/STC, ROL/ROR, EINT); ADDH/SUBH carry and overflow as MAME; LAR into the current AR wins over its update | **No 3D at all**: the DSP program ran into unimplemented instructions | `rtl/cpu/tms320c25/tas_tms320c25.sv`, `tests/ref/tas_tms320c25_ref.sv` |
| AI-2 | The (A\*B)/C unit takes signed operands and has two independent channels (3404-3407, 3408-340B) | **Wrong or missing 3D**: negative coordinates and the second channel's results | `rtl/tas_dsp.sv` |
| AI-3 | Faster C25: no fetch states, on-chip data RAM inside the core, repeats from the instruction register; paced to MAME's 36 MHz C25 by default (OSD *DSP speed*) | **3D only every second frame** where MAME draws every frame | `rtl/cpu/tms320c25/tas_tms320c25.sv`, `rtl/tas_dsp.sv`, `rtl/tas_main.sv`, `TaitoAir.sv` |
| AI-4 | Polygon lists: LINE items (colour word with bit 15 clear, then y1 x1 y2 x2) parsed and drawn | **Polygons floating in the sky** (a list starting with lines was read as one polygon; MAME has the same fault); horizon and runway lines missing | `rtl/tas_polygon.sv`, `rtl/tas_video.sv` |
| AI-5 | Line RAM guard: the C25 waits only for line RAM the renderer has not read yet, instead of being held while it reads | **3D every fourth frame** in heavy scenes (rescue stages) where MAME draws every third | `rtl/tas_polygon.sv`, `rtl/tas_dsp.sv`, `rtl/tas_main.sv`, `rtl/tas_video.sv`, `TaitoAir.sv` |
| AI-6 | TC0080VCO FG0 text layer (`tas_fg0`), drawn above BG1 and below the last sprite group | **No text in the cockpit monitor** (speed, height, distance, landing monitor state) | `rtl/tas_video.sv`, `rtl/tas_main.sv`, `TaitoAir.sv` |
| AI-7 | Cockpit windows: the polygon layer shows through BG1 colour 24 pen 15 | **Empty instruments and landing monitor**: the attitude ball, wind gauge face and landing camera are polygons behind those pixels (MAME draws them black) | `rtl/tas_video.sv` |
| AI-8 | Game selection: MRA ROM index 2 byte (1 = Air Inferno), else a checksum of the C25 program at index 1 | Lets the rest be switched per game | `rtl/tas_download_control.sv`, `TaitoAir.sv`, `releases/*.mra`, `tools/gen_mra.py`; the flag's ports in `rtl/tas_main.sv`, `rtl/tas_video.sv` |
| AI-9 | Air Inferno inputs: IN1 carries its cabinet buttons; yoke and throttle calibrated to its ranges (also in the control overlay) | Fire, pedals, lever and handles; yoke and throttle travel | `rtl/tas_main.sv`, `rtl/tas_flight_controls.sv`, `rtl/tas_throttle_overlay.sv`, `TaitoAir.sv` |
| AI-10 | Top Landing's video adjustments (cloud-sprite window, left-edge fill, pen $00d left-edge mask) not applied to Air Inferno | Fixes keyed to Top Landing's screens misfire on Air Inferno's (a white column at x=0, for one) | `rtl/tas_video.sv` |
| AI-11 | Service button replaced by the OSD option *Service mode* (test-mode DIP SWA:3, restarts the board); Start 2 and the service coin not wired; buttons renumbered | Controls clean-up (both games) | `TaitoAir.sv`, `rtl/tas_main.sv`, `rtl/tas_flight_controls.sv`, `releases/*.mra` |

## Porting notes

* To get Air Inferno's 3D at all, AI-1 and AI-2 are enough.
  `tests/ref/tas_tms320c25_ref.sv` is the original multi-cycle C25 with only
  the AI-1 changes, so it can replace the original core directly; it renders
  the 3D every second frame. AI-3 (the new core) brings MAME's frame rate.
* AI-4, AI-5, AI-6, AI-7, AI-9 and AI-10 all use the AI-8 `game_ainferno`
  flag. AI-6 also needs the 68000's VCO RAM writes, which `tas_main` passes
  to the video (`video_vco_wr*`).
* AI-5 only matters with AI-4's longer lists, but it is independent of it.
* Tests: AI-1 and AI-3 `make test-c25-ops test-c25-diff`; AI-4 and AI-5
  `make test-polygon-lines`; AI-6 `make test-fg0`; AI-8
  `make test-download-control test-mra`; AI-9 and AI-11
  `make test-flight-controls test-throttle-overlay`.
