#!/usr/bin/env python3
"""Convert a Quartus .rbf into the bit-reversed .rbf_r the Pocket loads.

Every byte's bit order is reversed; nothing else changes.

Usage: reverse_rbf_bits.py <input.rbf> <output.rbf_r>

SPDX-License-Identifier: GPL-2.0-or-later
"""

from __future__ import annotations

import sys
from pathlib import Path

REVERSED = bytes(int(format(value, "08b")[::-1], 2) for value in range(256))


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    src, dst = Path(argv[1]), Path(argv[2])
    data = src.read_bytes()
    if not data:
        print(f"error: {src} is empty", file=sys.stderr)
        return 1

    dst.write_bytes(data.translate(REVERSED))
    print(f"{src} -> {dst} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
