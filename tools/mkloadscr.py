#!/usr/bin/env python3
"""Convert the Spectrum loading screen to an Oric HIRES picture (8000 bytes
for $A000).  usage: mkloadscr.py tape.tzx out.bin [preview.png]"""
import sys
import oricenc
import zxscreen
import zxtape


def main():
    mem = zxtape.load_image(sys.argv[1])
    rows = zxscreen.decode(mem[16384:16384 + 6912])
    img = [[0] * 240 for _ in range(4)]
    img += [zxscreen.squeeze(r) for r in rows]
    img += [[0] * 240 for _ in range(4)]
    enc = oricenc.encode_image(img)
    open(sys.argv[2], 'wb').write(bytes(b for r in enc for b in r))
    if len(sys.argv) > 3:
        oricenc.write_png(sys.argv[3], oricenc.decode_rows(enc), 3)


if __name__ == '__main__':
    main()
