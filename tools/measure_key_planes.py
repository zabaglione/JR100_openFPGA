#!/usr/bin/env python3
"""Measure the JR-100 key planes by tracking the cursor cell explicitly.

The typed character lands at the old cursor position and the cursor advances;
keys the ROM ignores leave the cursor in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

EMU = Path.home() / "jr100emu"
sys.path.insert(0, str(EMU / "src"))

from jr100emu.jr100.computer import JR100Computer  # noqa: E402

VRAM = 0xC100
CELLS = 32 * 24

KEYS = {
    "Z": (0, 2), "X": (0, 3), "C": (0, 4),
    "A": (1, 0), "S": (1, 1), "D": (1, 2), "F": (1, 3), "G": (1, 4),
    "Q": (2, 0), "W": (2, 1), "E": (2, 2), "R": (2, 3), "T": (2, 4),
    "1": (3, 0), "2": (3, 1), "3": (3, 2), "4": (3, 3), "5": (3, 4),
    "6": (4, 0), "7": (4, 1), "8": (4, 2), "9": (4, 3), "0": (4, 4),
    "Y": (5, 0), "U": (5, 1), "I": (5, 2), "O": (5, 3), "P": (5, 4),
    "H": (6, 0), "J": (6, 1), "K": (6, 2), "L": (6, 3), ";": (6, 4),
    "V": (7, 0), "B": (7, 1), "N": (7, 2), "M": (7, 3), ",": (7, 4),
    ".": (8, 0), "SP": (8, 1), ":": (8, 2), "-": (8, 4),
}
CTL = (0, 0)
SHIFT = (0, 1)
V_KEY = (7, 0)


def snap(mem):
    return [mem.load8(VRAM + i) & 0xFF for i in range(CELLS)]


def find_cursor(computer, mem):
    """The cursor is the one cell that changes while nothing is typed."""
    a = snap(mem)
    computer.tick(400_000)          # long enough to catch a blink transition
    b = snap(mem)
    changed = [i for i in range(CELLS) if a[i] != b[i]]
    if len(changed) == 1:
        return changed[0]
    # keep ticking until exactly one blinking cell shows
    for _ in range(5):
        a = b
        computer.tick(400_000)
        b = snap(mem)
        changed = [i for i in range(CELLS) if a[i] != b[i]]
        if len(changed) == 1:
            return changed[0]
    raise RuntimeError(f"cursor not isolated: {changed}")


def press(computer, keys, hold=60_000, settle=120_000, mods=()):
    """Press modifiers first, let the ROM's scan see them, then the key."""
    kb = computer.hardware.keyboard
    for r, b in mods:
        kb.press(r, b)
    if mods:
        computer.tick(60_000)
    for r, b in keys:
        kb.press(r, b)
    computer.tick(hold)
    for r, b in keys:
        kb.release(r, b)
    computer.tick(30_000)
    for r, b in mods:
        kb.release(r, b)
    computer.tick(settle)


def main():
    rom = EMU / "datas" / "jr100rom.prg"
    computer = JR100Computer(rom_path=str(rom), enable_audio=False)
    computer.tick(3_000_000)
    mem = computer.hardware.memory

    results = {k: [None] * 4 for k in KEYS}
    RETURN = (8, 3)

    def flush_line():
        """RETURN to keep the ROM's input line from overflowing."""
        press(computer, [RETURN], settle=700_000)

    def probe(expect_graph):
        """Canary: A types 0x21 normally, 0x61 in GRAPH mode."""
        cur = find_cursor(computer, mem)
        press(computer, [KEYS["A"]])
        v = mem.load8(VRAM + cur) & 0xFF
        ok = (v == 0x61) if expect_graph else (v == 0x21)
        return ok, v

    def ensure_mode(expect_graph):
        ok, v = probe(expect_graph)
        if not ok:
            print(f"# mode canary failed (A={v:02X}), re-toggling GRAPH")
            press(computer, [V_KEY], mods=[CTL])
            flush_line()
            ok, v = probe(expect_graph)
            if not ok:
                raise RuntimeError(f"cannot reach desired mode, A={v:02X}")

    def measure(plane, with_shift, expect_graph=False):
        for n, (name, rc) in enumerate(KEYS.items()):
            if n % 6 == 0:
                flush_line()
                ensure_mode(expect_graph)
            cur = find_cursor(computer, mem)
            press(computer, [rc], mods=([SHIFT] if with_shift else []))
            new_cur = find_cursor(computer, mem)
            if new_cur == cur:
                results[name][plane] = None      # ROM ignored the key
            else:
                v = mem.load8(VRAM + cur) & 0xFF
                results[name][plane] = v

    def graph_toggle():
        press(computer, [V_KEY], mods=[CTL])

    measure(0, False)
    measure(1, True)

    # --- determine what cancels GRAPH mode ---
    graph_toggle()
    ok, v = probe(True); print(f"# graph on, canary A={v:02X} ok={ok}")
    flush_line()  # RETURN on a line holding junk -> error message
    ok, v = probe(True); print(f"# after RETURN(error line): A={v:02X} graph_still={ok}")
    if not ok:
        press(computer, [KEYS["A"]])   # make normal-mode canary char
        graph_toggle()
        flush_line()                    # error line again
    # empty-line RETURN test
    graph_toggle() if not ok else None
    ok2, v2 = probe(True)
    if ok2:
        flush_line(); flush_line()      # first clears junk, second is empty
        ok3, v3 = probe(True)
        print(f"# after empty-line RETURN: A={v3:02X} graph_still={ok3}")

    # --- burst measurement: re-arm GRAPH before every short batch ---
    def measure_graph(plane, with_shift):
        names = list(KEYS.items())
        i = 0
        while i < len(names):
            batch = names[i:i+5]
            # flush in normal mode, then arm graph
            press(computer, [V_KEY], mods=[CTL])
            okb, vb = probe(True)
            if not okb:
                press(computer, [V_KEY], mods=[CTL])
                okb, vb = probe(True)
                if not okb:
                    raise RuntimeError(f"graph arm failed A={vb:02X}")
            for name, rc in batch:
                cur = find_cursor(computer, mem)
                press(computer, [rc], mods=([SHIFT] if with_shift else []))
                new_cur = find_cursor(computer, mem)
                if new_cur == cur:
                    results[name][plane] = None
                else:
                    results[name][plane] = mem.load8(VRAM + cur) & 0xFF
            # leave graph, flush the junk line while normal
            press(computer, [V_KEY], mods=[CTL])
            flush_line()
            i += 5

    measure_graph(2, False)
    measure_graph(3, True)

    print(f"{'key':4s} {'norm':>5s} {'shift':>5s} {'graph':>5s} {'g+sh':>5s}")
    for name in KEYS:
        cells = [f"{v:02X}" if v is not None else "--" for v in results[name]]
        print(f"{name:4s} {cells[0]:>5s} {cells[1]:>5s} {cells[2]:>5s} {cells[3]:>5s}")


if __name__ == "__main__":
    main()
