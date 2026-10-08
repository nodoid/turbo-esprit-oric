#!/usr/bin/env python3
"""Build the bootable Oric disk (Microdisc, Sedoric 3) for the 64K version.

usage: mkdsk.py out.dsk MAIN.bin BOOT.bin OVERLAY.bin MENU.bin DASH.bin

Needs tap2dsk (Fabrice Frances' Euphoric tool, which carries Sedoric 3):
set TAP2DSK to its binary (default: tap2dsk on the PATH).

How the disk boots:
  * Sedoric starts and runs the init string
        HIRES:LOAD"GAME.BIN":LOAD"BOOT.BIN":CALL#500
    loading the main part of the game ($0600..) and a small machine-code
    stub ($0500).
  * The overlay part of the game (16K, for the RAM under the ROM) is not a
    Sedoric file: it is stored as raw sectors on fixed tracks (src/disk.inc).
    The stub (src/boot/boot.s) switches the ROM - and with it Sedoric, which
    lives in that RAM - off, reads those sectors straight into $C000.. with
    the disk controller (WD1793) and jumps to $0600.  Its sector reader stays
    resident; the game uses it for the menu and dashboard blobs, which are
    raw sectors too.
"""
import os
import struct
import subprocess
import sys
import tempfile

SECTORS = 17            # Sedoric / tap2dsk geometry
TRACK_LEN = 6400        # MFM_DISK raw track size


def tape_file(name, addr, data, typ=0x80):
    end = addr + len(data) - 1
    return (bytes([0x16] * 3 + [0x24, 0x00, 0x00, typ, 0x00,
                                end >> 8, end & 0xFF, addr >> 8, addr & 0xFF, 0x00])
            + name.encode('ascii') + b'\x00' + data)


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def mfm_track(track, sectors):
    """Raw MFM_DISK track: IBM System 34 layout with 256-byte sectors."""
    t = bytearray([0x4E] * 40 + [0x00] * 12 + [0xC2] * 3 + [0xFC] + [0x4E] * 40)
    for n, data in enumerate(sectors, 1):
        idf = bytes([0xA1] * 3 + [0xFE, track, 0, n, 1])
        c = crc16(idf)
        t += bytes([0x00] * 12) + idf + bytes([c >> 8, c & 0xFF]) + bytes([0x4E] * 22)
        dat = bytes([0xA1] * 3 + [0xFB]) + data
        c = crc16(dat)
        t += bytes([0x00] * 12) + dat + bytes([c >> 8, c & 0xFF]) + bytes([0x4E] * 40)
    assert len(t) <= TRACK_LEN, len(t)
    return bytes(t + bytes([0x4E] * (TRACK_LEN - len(t))))


def layout():
    vals = {}
    inc = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'disk.inc')
    for line in open(inc):
        p = line.split(';')[0].split('=')
        if len(p) == 2 and p[0].strip().endswith('_TRACK'):
            vals[p[0].strip()] = int(p[1].strip(), 0)
    return vals


def main():
    out, main_p, boot_p, ovl_p, menu_p, dash_p = sys.argv[1:7]
    game, boot, ovl, menu, dash = (open(p, 'rb').read()
                                   for p in (main_p, boot_p, ovl_p, menu_p, dash_p))
    lay = layout()
    tap2dsk = os.environ.get('TAP2DSK', 'tap2dsk')
    with tempfile.TemporaryDirectory() as tmp:
        tap = os.path.join(tmp, 'disk.tap')
        with open(tap, 'wb') as f:
            f.write(tape_file('GAME', 0x0600, game))
            f.write(tape_file('BOOT', 0x0500, boot))
        old = os.path.join(tmp, 'old.dsk')
        subprocess.run([tap2dsk, '-iHIRES:LOAD"GAME.BIN":LOAD"BOOT.BIN":CALL#500',
                        '-nTURBO ESPRIT', tap, old], check=True, capture_output=True)
        img = open(old, 'rb').read()
    assert img[:8] == b'ORICDISK'
    sides, ntracks, nsec = struct.unpack_from('<iii', img, 8)
    assert sides == 1 and nsec == SECTORS
    zxram = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'data',
                              'zxram.bin'), 'rb').read()
    cities = zxram[0x686B - 0x5B00:0x6DB7 - 0x5B00]   # the four city maps
    blobs = [(lay['OVL_TRACK'], ovl, 64), (lay['MENU_TRACK'], menu, None),
             (lay['DASH_TRACK'], dash, None), (lay['CITY_TRACK'], cities, 6)]
    total = max(t + ((len(d) + 255) // 256 + SECTORS - 1) // SECTORS for t, d, _ in blobs)
    secs = [img[256 + i * 256:256 + (i + 1) * 256] for i in range(ntracks * SECTORS)]
    secs += [bytes(256)] * (total * SECTORS - len(secs))
    used = [False] * len(secs)
    for t, d, maxs in blobs:
        assert t >= ntracks, 'Sedoric files reach track %d' % ntracks
        n = (len(d) + 255) // 256
        assert maxs is None or n <= maxs
        d = d + bytes(n * 256 - len(d))
        for i in range(n):
            k = t * SECTORS + i
            assert not used[k], 'raw blobs overlap (src/disk.inc)'
            used[k] = True
            secs[k] = d[i * 256:(i + 1) * 256]
    hdr = b'MFM_DISK' + struct.pack('<iii', 1, total, 1)
    hdr += bytes(256 - len(hdr))
    disk = bytearray(hdr)
    for t in range(total):
        disk += mfm_track(t, secs[t * SECTORS:(t + 1) * SECTORS])
    open(out, 'wb').write(disk)
    print('%s: %d tracks (Sedoric files on %d, raw blobs at %s)'
          % (out, total, ntracks, ', '.join('%d' % t for t, _, _ in blobs)))


if __name__ == '__main__':
    main()
