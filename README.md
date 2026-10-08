# Turbo Esprit for the Oric Atmos

A conversion of Durell's *Turbo Esprit* (ZX Spectrum, 1986) to the Oric
Atmos. The game logic is translated routine by routine from the Spectrum
original into 6502, and each translated routine was tested against the Z80
code. The 3D view is converted to the Oric's HIRES screen each frame.

Needs a **64K Oric Atmos with a Microdisc drive** (Sedoric). The game uses
the RAM under the ROM, so it does not fit a tape-only machine.

## Differences from the Spectrum version

- The game starts at the main menu. The city is chosen after PLAY or
  PRACTICE. There is no loading screen and no copyright page.
- The Oric character set is used throughout.
- The player's car is red, so it stands out from the traffic.
- The sound uses the AY chip: the original tunes and effects, plus an
  engine drone.
- The score and penalty lines use the text rows at the bottom of the screen.
- Saving and loading the score tables is not implemented (it shows ERROR).

Default keys, which can be changed from the menu:

| Key | Action |
|---|---|
| J | Left |
| L | Right |
| K | Fire |
| A | Slow |
| S | Fast |
| M | Map |
| T | Quit |

## Building

Needs:

- [cc65](https://cc65.github.io/) (`ca65`, `ld65`) and Python 3.
- `tap2dsk` from Fabrice Frances' Euphoric tools. It contains Sedoric 3 and
  makes the bootable disk. Point `TAP2DSK` at it if it is not on the `PATH`.

```sh
make TAP2DSK=/path/to/tap2dsk     # -> build/turbo.dsk
```

`data/` holds the graphics, maps, tables and tunes, extracted from the
original tape. It is committed, so a normal build does not need the tape.
To regenerate it, put the original tape at `orig/TurboEsprit.tzx` (not in the
repository) and run `make extract`. The dashboard encoder needs `ORICROM`,
see below.

## Running

Boot `build/turbo.dsk` in an Atmos emulator with a Microdisc drive. For
Oricutron:

```sh
oricutron -m atmos -k microdisc -d build/turbo.dsk
```

You can also run `OCDIR=/path/to/oricutron make run`.

## Tests

The tests compare the translated routines with the original Z80 code. They
need:

- the original tape in `orig/`;
- the Python packages `zx`, `z80`, `py65` and `Pillow`;
- the Atmos ROM, for its font.

```sh
export ORICROM=/path/to/basic11b.rom
for t in tests/test_*.py; do python3 $t; done
```

`tools/harness.py` runs the whole game headless (disk mode, key presses,
screenshots). `docs/PORTING.md` describes the memory map, the screen
mapping and how the code is organised.
