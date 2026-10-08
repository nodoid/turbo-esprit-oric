#!/usr/bin/env python3
"""Wrap raw binaries into an Oric .tap file.

usage: mktap.py out.tap NAME:ADDR:file.bin[:auto] [NAME:ADDR:file.bin ...]
Each block becomes one tape file; ':auto' marks the block to autorun (machine code).
"""
import sys


def block(name, addr, data, auto):
    """auto: data must be linked at $050D; a BASIC line '800 CALL#50D'
    is put in front and the file is saved as an autorunning BASIC program
    (the form Oric emulators' auto-loaders handle best)."""
    if auto:
        assert addr == 0x050D, "autorun block must start at $050D"
        stub = bytes([0x0B, 0x05, 0x20, 0x03, 0xBF]) + b'#50D' + bytes([0, 0, 0])
        data = stub + data
        addr = 0x0501
    end = addr + len(data) - 1
    hdr = bytes([0x16] * 3 + [0x24, 0x00, 0x00, 0x00 if auto else 0x80,
                 0xC7 if auto else 0x00,
                 end >> 8, end & 0xFF, addr >> 8, addr & 0xFF, 0x00])
    return hdr + name.encode('ascii')[:15] + b'\x00' + data


def main():
    out = bytearray()
    for spec in sys.argv[2:]:
        parts = spec.split(':')
        name, addr, path = parts[0], int(parts[1], 0), parts[2]
        auto = len(parts) > 3 and parts[3] == 'auto'
        out += block(name, addr, open(path, 'rb').read(), auto)
    open(sys.argv[1], 'wb').write(out)


if __name__ == '__main__':
    main()
