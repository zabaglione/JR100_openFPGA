#!/usr/bin/env python3
"""Register-timing model of jr100_media_bridge's two byte sweeps.

Reproduces the RTL's nonblocking-assignment semantics cycle by cycle:
the write path (client's registered din -> shift register -> snapshot ->
BRAM) and the read path (combinational word address -> BRAM -> lane mux).
Both must round-trip a 512-byte sector exactly.

This caught two real bugs before hardware: the BRAM sampling the shift
register one byte late (fixed with the wbuf_hold snapshot), and a
registered read address making the BRAM path two cycles deep so every
word's first byte came from the previous word.

SPDX-License-Identifier: GPL-2.0-or-later
"""

import random
import sys


def write_path(B):
    mem = {}
    sweep = 0
    buff_addr = 0
    wdata = 0
    wr = False
    waddr = 0
    hold = 0
    prev_addr = None
    for _ in range(0, 515):
        if wr:
            mem[waddr] = hold
        din_now = B[prev_addr] if prev_addr is not None and prev_addr < 512 else 0
        s = sweep
        n_wdata = ((wdata << 8) | din_now) & 0xFFFFFFFF if (s != 0 and s <= 512) else wdata
        n_wr = (s & 3) == 1 and s >= 5
        prev_addr = buff_addr
        buff_addr = (s + 1) if s < 511 else 0
        if n_wr:
            waddr = ((s >> 2) - 1) & 0x7F
            hold = wdata          # pre-shift snapshot (nonblocking RHS)
        wr = n_wr
        wdata = n_wdata
        sweep = s + 1
        if s == 513:
            if wr:
                mem[waddr] = hold
            break
    return mem


def read_path(words):
    out = {}
    sweep = 0
    baddr_prev = 0
    for _ in range(0, 514):
        q = words[baddr_prev if baddr_prev < 128 else 0]
        s = sweep
        if s != 0:
            lane = (s - 1) & 3
            out[s - 1] = (q >> (8 * (3 - lane))) & 0xFF
        baddr_prev = (s >> 2) & 0x7F
        sweep = s + 1
        if s == 512:
            break
    return out


def main() -> int:
    random.seed(1)
    B = [random.randrange(256) for _ in range(512)]
    words = [(B[4 * w] << 24) | (B[4 * w + 1] << 16) |
             (B[4 * w + 2] << 8) | B[4 * w + 3] for w in range(128)]

    mem = write_path(B)
    w_ok = all(mem.get(w) == words[w] for w in range(128))
    out = read_path(words)
    r_ok = all(out.get(i) == B[i] for i in range(512))

    print(f"write sweep: {'PASS' if w_ok else 'FAIL'}")
    print(f"read sweep : {'PASS' if r_ok else 'FAIL'}")
    return 0 if (w_ok and r_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
