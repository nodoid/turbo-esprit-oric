#!/usr/bin/env python3
"""Build the Oric tape: an autorunning BASIC loader followed by binary files.

usage: mktap.py out.tap CALLADDR NAME:ADDR:file.bin [NAME:ADDR:file.bin ...]

The loader is the one-line program
    10 HIRES:CLOAD"":CLOAD"": ... :CALL#<CALLADDR>
with one CLOAD per binary file.  It lives at $0501, so the binaries must
load above it (the game starts at $0600).
"""
import sys

TOK_HIRES, TOK_CLOAD, TOK_CALL = 0xA2, 0xB6, 0xBF


def header(typ, auto, start, end, name):
    return (bytes([0x16] * 3 + [0x24, 0x00, 0x00, typ, auto,
                                end >> 8, end & 0xFF, start >> 8, start & 0xFF, 0x00])
            + name.encode('ascii')[:15] + b'\x00')


def loader(nfiles, call):
    body = bytes([TOK_HIRES])
    for _ in range(nfiles):
        body += b':' + bytes([TOK_CLOAD]) + b'""'
    body += b':' + bytes([TOK_CALL]) + ('#%X' % call).encode('ascii')
    start = 0x0501
    nxt = start + 4 + len(body) + 1
    prog = bytes([nxt & 0xFF, nxt >> 8, 10, 0]) + body + b'\x00' + b'\x00\x00'
    assert start + len(prog) <= 0x0600
    return header(0x00, 0xC7, start, start + len(prog) - 1, 'TURBO') + prog


def main():
    out = sys.argv[1]
    call = int(sys.argv[2], 0)
    files = []
    for spec in sys.argv[3:]:
        name, addr, path = spec.split(':')
        files.append((name, int(addr, 0), open(path, 'rb').read()))
    tape = bytearray(loader(len(files), call))
    for name, addr, data in files:
        tape += header(0x80, 0x00, addr, addr + len(data) - 1, name) + data
    open(out, 'wb').write(tape)


if __name__ == '__main__':
    main()
