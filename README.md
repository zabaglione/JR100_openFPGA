# JR-100 for Analogue Pocket (openFPGA)

*日本語版は [README.ja.md](README.ja.md) を参照してください。*

An openFPGA core for the Analogue Pocket that re-implements the **National
(Matsushita) JR-100** personal computer (Japan, 1981).

The machine itself is ported unmodified from
[JR100_MiSTer](https://github.com/zabaglione/JR100_MiSTer), whose emulation
is verified against the [pyjr100emu](https://github.com/zabaglione/pyjr100emu)
reference emulator by instruction-boundary lockstep.

> **Status: feature-complete.** Everything the MiSTer core does has been
> verified on Pocket hardware: BASIC, keyboard input (virtual and dock USB),
> joystick, BEEP audio, program loading, BASIC save and the virtual cassette
> deck. See [docs/PLAN.md](docs/PLAN.md) for the development log (Japanese).

## Using the core

Menus (data slots appear as "Load ..."):

| Menu item | What it does |
|---|---|
| Load PRG Program | Load a `.prg` instantly (autostart types `RUN` / `A=USR($hhhh)`) |
| Load BASIC Text | Load a `.bas` text listing instantly |
| Load Tape | Put a `.cmt` cassette in the virtual deck |
| Load Save Target | Pick the `.prg` file that `Save BASIC->Target` writes into |
| Tape Play | Press play on the deck (use after typing `LOAD` in BASIC) |
| Save BASIC->Target | Write the BASIC program to the mounted save target |
| Display Color / Autostart / Extended RAM / Reset Machine | Settings |

Cassette workflow, exactly like the real machine at 600 baud:
`SAVE"NAME"` records to the mounted tape automatically; `LOAD"NAME"` then
**Tape Play** plays it back. Mounts survive **Reset Machine**.

The virtual keyboard opens with **Select**: D-pad moves, **A** presses,
**B** space, **X** return, **L1** shift, **R1** ctrl. Pressing **A** on the
SHFT/CTL cells locks the modifier and the key labels switch to the shifted
legends (`@` is SHIFT+U, as on the real keyboard). In GRAPH mode (CTRL+V,
cancelled by RETURN) the labels show the semigraphic set, rendered from the
machine's own character generator. USB keyboards work through the dock with
the JR-100's physical layout.

## Features

Inherited from the MiSTer core:

- MB8861H CPU (MC6800-compatible plus five extra instructions)
- R6522 VIA with per-cycle behaviour
- 32x24 character display with user-defined glyphs (CGRAM / shared-VRAM)
- The machine's own video timing preserved internally: 7.15909 MHz dot
  clock, 62.4 Hz, a sync format deliberately not NTSC
- BEEP audio (band-limited)
- Virtual cassette deck compatible with the real ROM's `LOAD`/`SAVE`
  (600 baud FSK)
- Optional 16 KiB extended RAM

Pocket-specific:

- Scaler output decoupled through a 1bpp framebuffer (the Pocket's scaler
  runs at a proven 320x240@60 Hz while the machine keeps its native raster)
- On-screen virtual keyboard laid out like the real 45-key matrix
  (Select opens it; D-pad moves, A presses, B space, X return,
  L1 shift, R1 ctrl)
- USB keyboards via the Analogue Dock (HID decoded straight into the key
  matrix)

## Building

**GitHub Actions (`build-core` workflow) is the primary build path.** It
compiles with Quartus Prime 18.1.1 Lite in a container and uploads a
`build/package/` artifact laid out exactly like the SD card.

The same script builds locally, but on Apple Silicon it runs under x86
emulation and is too slow for iteration — use it for minimal checks only.

```bash
make build          # compile in a container (scripts/build_core.sh)
make fetch          # pull the staged package from the latest CI run instead
make package        # stage the SD layout into build/package/
make dist           # zip a distributable into dist/
```

Installing onto the Pocket's SD card:

```bash
make install POCKET_SD="/Volumes/YOUR_SD"
```

Enabling `Tools > Developer > USB SD Access` on the Pocket mounts the
microSD over USB-C without removing the card.

## ROM

The BASIC ROM is **not** included. Dump it from your own hardware and place
it at `Assets/jr100/common/boot.rom` — an 8 KiB image, character ROM in
`0x0000-0x03FF` followed by the BASIC ROM in `0x0400-0x1FFF` (the same
`boot.rom` the MiSTer core uses).

## License

GPL-2.0-or-later. See [LICENSE](LICENSE); third-party attributions:

- `src/fpga/apf/` and the Quartus project derive from Analogue's
  [core-template](https://github.com/open-fpga/core-template)
- `src/fpga/core/data_loader.sv` is from agg23's
  [analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) (MIT)
- The port's structure references
  [PocketCPC](https://github.com/stilvoid/PocketCPC) throughout
