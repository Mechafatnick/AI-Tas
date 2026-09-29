# AI-TAS

This is a Mister implementation of the Taito Air System, based on the excellent work of Retro Garage at https://github.com/retrogarage/tas-mister

The Original Core Had a Mame-beating version of seminal 1987 partial Flight Sim Top Landing, and I have used tools to add support for the Air System's other title, 1990's helicopter-based Rescue'em'up Air Inferno. This is not a perfect core verified against original PCBs or schematics, but offers imporvements over the MAME core such as a functioning landing camera. 


# The Inevitable AI decleration

Yes, chat, This core is indeed an AI-assisted slop core. I'm sorry! Though I do have some programming Skillz I don't have the bandwidth
to learn enough about the verilog side of things so I've relied on Claude for the implementation. I had access to a Claude account (long story) so I thought I'd make use of it. Partly because i want to make Taito's classic line up of curiosities available to as many people as possible and partly because (having successfully created a 2d, 68k-based core) I wanted to see if it could handle one that pushed polygons.

# How I sleep at night

It's pretty obvious that the powers that be aren't interested in little people - they want big business buy in military buy in, so everyday people bycotting is unlikely to be an effective strategy (that's not to say lose hope and accept it - lobbying your local politician against the building of the data centers is likely to be a more effective result.)

The way I see it, its useful to have people who can argue against things based on experience rather than the theoretical. "I needed to tell it three times before it would acknowledge the schematic it needed to use to solve the problem" is a stronger argument than "it just can't do, X, OK!?". If i'm going to talk about the limits of AI i'd much rather do so from the perspective of having used it in good faith, with this core being evidence I've done just that.

On top of that, would AI execs actually want us to use their products? I was loath to start a new session, so many of my prompts used  5 hours worth of usage in a single go. I'd hate to think how much Pit-Fighter and Hydra must have cost Anthropic, and how commercially useful is it to have extra examples of code targeted at the 68k?

If you aren't swayed by these arguments that's fine. These were dumb games in 1990 and they are dumb games now. I'm sure someone will get round to creating a more authentic core based on hands-on experience with the original board eventually :)

## Hardware target

- MiSTer / Terasic DE10-Nano
- Cyclone V 5CSEBA6U23I7
- Quartus Prime Lite 24.1
- Core top-level: `sys_top`

## Build locally

For RTL tests on a Linux workstation:

```sh
python3 tools/check_self_contained.py
make -j2 test
```

`make test-c25-diff` (part of `make test`) runs the C25 core against the
earlier multi-cycle core on random programs. The whole-board simulation
`tests/tb_system.sv` (68000, C25 and video; `make
obj_dir/tests/system/Vtb_system`, run from `rtl/cpu/fx68k`) needs a ROM image
from `tools/build_rom.py` and writes frames, polygon lists and polygon pens
for comparison with MAME.

For FPGA synthesis with Quartus Prime Lite 24.1:

```sh
./ci/check-quartus.sh
quartus_sh --flow compile TaitoAir
```

The generated bitstream is `output_files/TaitoAir.rbf`.

## GitHub Actions

`/.github/workflows/ci.yml` runs the Verilator test suite on GitHub-hosted
Ubuntu runners. It intentionally does not need game ROMs.

`/.github/workflows/quartus.yml` builds the FPGA core on a self-hosted Linux
runner labelled:

```text
self-hosted, linux, x64, quartus-24.1
```

Install Quartus Prime Lite 24.1 on that runner and make `quartus_sh` available
on `PATH`. The workflow publishes the generated `.rbf`, Quartus reports and a
MiSTer-ready ZIP as Actions artifacts.

## ROMs

Game ROMs are not stored in this repository. The MRAs in `releases/` describe
the expected **unmodified MAME sets** and their ROM interleaving:

| MRA | MAME set(s) |
| --- | --- |
| `Top Landing (World).mra` | `topland.zip` |
| `Top Landing (Japan).mra` | `toplandj.zip` + `topland.zip` |
| `Air Inferno (World).mra` | `ainferno.zip` |
| `Air Inferno (US).mra` | `ainfernou.zip` + `ainferno.zip` |
| `Air Inferno (Japan).mra` | `ainfernoj.zip` + `ainferno.zip` |

Each MRA also sends a one-byte game-select entry (index 2), which picks the
game's inputs, control calibration and video adjustments (MRAs without it
are recognised by their DSP program).

## Air Inferno

Air Inferno's 3D world is computed by the board's TMS320C25; see
`docs/air-inferno.md` for what it needed (C25 instructions, the signed
two-channel (A*B)/C unit, a faster C25 implementation) and how the result was
checked against MAME. Every change is tagged `[AI-n]` in the sources, and
`docs/air-inferno-changes.md` lists them, with the files each one touches,
for porting them elsewhere.

Controls (named in the MRA; map them in the MiSTer menu): Start, Coin,
Throttle Up/Down, Fire, Lever, Pedal L/R and Handle X/Y. The yoke is the left
stick (or the d-pad) and the throttle the right stick, as for Top Landing;
the *Throttle input* menu option applies to both games. The pedals need the
DIP switch *Rudder Pedal: With* (the MRAs' default). In a stage, Start
switches the cockpit's landing monitor on and off. *DSP speed* chooses
between the original board's pace for the 3D processor (default) and running
it flat out for smoother 3D in heavy scenes. *Service mode* (both games)
switches the test mode DIP and restarts the board.

## Hardware reference

The supplied MAME `taito-taitoair.cpp` driver is preserved at
`docs/mame/taito-taitoair.cpp` as the reference for CPU, memory map, I/O,
video and DSP behaviour.

## Licensing

Third-party source files retain their original licence and copyright notices.
See the individual source directories and the original upstream notices before
redistributing modified binaries or source.
