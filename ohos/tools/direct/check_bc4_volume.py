# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Verify VIS-12 readbacks against the captured BC4 words (32^3, six mips).

blocks: tightly packed RGBA16UI texels in mip, Z, block-row, block-column order.
volume: fog_raw R16_UNORM readback, each mip starts on a 16-byte boundary.
"""
import argparse
from pathlib import Path
import struct


def validate(blocks, volume):
    block_offset = volume_offset = 0
    results = []
    for mip in range(6):
        size = 32 >> mip
        pitch = (size + 3) // 4
        volume_offset = (volume_offset + 15) & ~15
        peak = outside = nonzero = 0
        for z in range(size):
            for y in range(size):
                for x in range(size):
                    offset = block_offset + 8 * ((z * pitch + y // 4) * pitch + x // 4)
                    word = struct.unpack_from("<Q", blocks, offset)[0]
                    a, b = word & 255, word >> 8 & 255
                    i = word >> (16 + 3 * ((y % 4) * 4 + x % 4)) & 7
                    if i < 2:
                        value = (a, b)[i] * 257
                    elif a <= b and i >= 6:
                        value = (i - 6) * 65535
                    else:
                        den = 7 if a > b else 5
                        value = round(((den + 1 - i) * a + (i - 1) * b) * 257 / den)
                    pos = volume_offset + 2 * ((z * size + y) * size + x)
                    actual = struct.unpack_from("<H", volume, pos)[0]
                    error = abs(actual - value)
                    peak = max(peak, error)
                    outside += error > 1
                    nonzero += actual != 0
        results.append((mip, size ** 3, nonzero, peak, outside))
        block_offset += 8 * pitch * pitch * size
        volume_offset += 2 * size ** 3
    if (block_offset, volume_offset) != (len(blocks), len(volume)):
        raise ValueError("unexpected buffer lengths")
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("blocks", type=Path)
    parser.add_argument("volume", type=Path)
    args = parser.parse_args()
    rows = validate(args.blocks.read_bytes(), args.volume.read_bytes())
    print("mip texels nonzero max_error_R16 outside_1_LSB")
    for row in rows:
        print(*row)
    raise SystemExit(any(row[-1] for row in rows))
