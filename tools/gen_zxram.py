#!/usr/bin/env python3
"""Generate data/zxram.bin: the Spectrum game's RAM $5B00-$7BBD from the
original tape, which the Oric keeps at the same addresses.

usage: gen_zxram.py [orig/TurboEsprit.tzx] [data/zxram.bin]
Changes from the tape image: the lane grid $5C00-$63FF is zeroed (cleared at
run time anyway) and the key table at $7524 holds Oric key codes
(matrix row, column mask, 0) for the default keys J L K A S M T, and the
player's car is red (ink colour byte +3 of its record template at $74D3 and of
the record itself at $7792; the original draws it in black like the traffic).
"""
import sys
import zxtape

ORIC_KEYS = bytes([1, 0x01, 0,  7, 0x02, 0,  3, 0x01, 0,  6, 0x20, 0,
                   6, 0x40, 0,  2, 0x01, 0,  1, 0x02, 0])


def main():
    tape = sys.argv[1] if len(sys.argv) > 1 else 'orig/TurboEsprit.tzx'
    out = sys.argv[2] if len(sys.argv) > 2 else 'data/zxram.bin'
    m = zxtape.load_image(tape)
    z = bytearray(m[0x5B00:0x7BBE])
    z[0x5C00 - 0x5B00:0x6400 - 0x5B00] = bytes(0x800)
    z[0x7524 - 0x5B00:0x7524 - 0x5B00 + len(ORIC_KEYS)] = ORIC_KEYS
    for rec in (0x74D3, 0x7792):              # player's car: red ink (Spectrum colour 2)
        z[rec + 3 - 0x5B00] = 0x02
    open(out, 'wb').write(z)


if __name__ == '__main__':
    main()
