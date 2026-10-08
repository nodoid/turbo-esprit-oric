#!/usr/bin/env python3
"""Load the original ZX Spectrum Turbo Esprit tape into a 64K memory image.

The game's data (city maps, car graphics, tables, the dashboard picture) is
converted from this image by tools/extract.py.  Side 2 of the original TZX
is a plain (non turbo-loading) copy: a BASIC loader, 'te1' (7168 bytes at
16384: the loading screen plus a 256-byte bit-reversal table at 23296) and
'te2' (38351 bytes at 26731: the game).
"""
import struct
import sys


def tzx_blocks(path):
    """Yield the data of every standard/turbo/pure data block in a TZX file."""
    d = open(path, 'rb').read()
    if d[:7] != b'ZXTape!':
        raise ValueError('%s is not a TZX file' % path)
    p = 10
    while p < len(d):
        t = d[p]
        p += 1
        if t == 0x10:
            _, ln = struct.unpack_from('<HH', d, p)
            yield d[p + 4:p + 4 + ln]
            p += 4 + ln
        elif t == 0x11:
            ln = d[p + 15] | (d[p + 16] << 8) | (d[p + 17] << 16)
            yield d[p + 18:p + 18 + ln]
            p += 18 + ln
        elif t == 0x14:
            ln = d[p + 7] | (d[p + 8] << 8) | (d[p + 9] << 16)
            yield d[p + 10:p + 10 + ln]
            p += 10 + ln
        elif t == 0x12:
            p += 4
        elif t == 0x13:
            p += 1 + 2 * d[p]
        elif t == 0x15:
            ln = d[p + 5] | (d[p + 6] << 8) | (d[p + 7] << 16)
            p += 8 + ln
        elif t == 0x20:
            p += 2
        elif t == 0x21:
            p += 1 + d[p]
        elif t == 0x22:
            pass
        elif t == 0x30:
            p += 1 + d[p]
        elif t == 0x32:
            p += 2 + struct.unpack_from('<H', d, p)[0]
        elif t == 0x35:
            p += 20 + struct.unpack_from('<I', d, p + 16)[0]
        elif t == 0x5A:
            p += 9
        else:
            raise ValueError('unsupported TZX block %02X' % t)


# the BASIC loader overrides the saved address of some files (LOAD "te1" CODE 16384)
LOAD_AT = {'te1': 16384}


def load_image(path):
    """Return a 64K bytearray holding every CODE file of the tape at the
    address the BASIC loader puts it."""
    mem = bytearray(65536)
    pending = None
    for b in tzx_blocks(path):
        if len(b) == 19 and b[0] == 0x00:
            typ = b[1]
            ln, p1 = struct.unpack_from('<HH', b, 12)
            name = b[2:12].decode('latin-1').strip()
            pending = (typ, ln, LOAD_AT.get(name, p1))
        elif pending and b[0] == 0xFF:
            typ, ln, p1 = pending
            if typ == 3:
                mem[p1:p1 + ln] = b[1:1 + ln]
            pending = None
    return mem


if __name__ == '__main__':
    m = load_image(sys.argv[1])
    open(sys.argv[2], 'wb').write(m)
