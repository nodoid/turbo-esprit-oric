#!/usr/bin/env python3
"""Spectrum screen helpers: decode a 6912-byte SCREEN$ into colour indices
(Oric palette numbering) and resample it for the Oric's 240-pixel lines."""

# Spectrum colour number -> Oric colour number
# Spectrum: 0 black 1 blue 2 red 3 magenta 4 green 5 cyan 6 yellow 7 white
# Oric:     0 black 1 red  2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white
ZX2ORIC = [0, 4, 1, 5, 2, 6, 3, 7]


def decode(scr):
    """-> list of 192 rows of 256 Oric colour indices."""
    rows = []
    for y in range(192):
        base = ((y & 0xC0) << 5) + ((y & 7) << 8) + ((y & 0x38) << 2)
        row = []
        for cx in range(32):
            b = scr[base + cx]
            a = scr[6144 + (y >> 3) * 32 + cx]
            ink, paper = ZX2ORIC[a & 7], ZX2ORIC[(a >> 3) & 7]
            for bit in range(8):
                row.append(ink if b & (0x80 >> bit) else paper)
        rows.append(row)
    return rows


def squeeze(row, width=240):
    """Resample a pixel row to `width` pixels (nearest, keeps thin lines)."""
    n = len(row)
    return [row[(x * n) // width] for x in range(width)]
