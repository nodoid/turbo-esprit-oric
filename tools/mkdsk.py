#!/usr/bin/env python3
"""Build the bootable Oric disk (Microdisc, Sedoric 3) for the 64K version.

usage: mkdsk.py out.dsk SCREEN.bin MAIN.bin OVERLAY.bin

Needs tap2dsk (Fabrice Frances' Euphoric tool, which carries Sedoric 3):
set TAP2DSK to its binary (default: tap2dsk on the PATH).

How the disk boots:
  * Sedoric starts and runs the init string
        HIRES:LOAD"SCR.BIN":LOAD"GAME.BIN":LOAD"BOOT.BIN":CALL#500
    loading the loading screen ($A000), the main part of the game ($0600..)
    and a small machine-code stub ($0500).
  * The overlay part of the game (16K, for the RAM under the ROM) is not a
    Sedoric file: it is stored as raw sectors on the tracks after the Sedoric
    ones.  The stub switches the ROM - and with it Sedoric, which lives in
    that RAM - off, reads those sectors straight into $C000.. with the disk
    controller (WD1793) and jumps to $0600.
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


def boot_stub(track0, nsect):
    """6502 code at $0500: read nsect sectors from track0/sector 1 on into
    $C000.., then JMP $0600."""
    ZP_PTR, ZP_TRK, ZP_SEC, ZP_CNT = 0xF0, 0xF2, 0xF3, 0xF4
    c = bytearray()

    def here():
        return 0x0500 + len(c)
    c += bytes([0x78])                                      # sei
    c += bytes([0xA9, 0x84, 0x8D, 0x14, 0x03])              # lda #$84 : sta $0314 (ROM, EPROM off)
    c += bytes([0xA9, 0x00, 0x85, ZP_PTR, 0xA9, 0xC0, 0x85, ZP_PTR + 1])
    c += bytes([0xA9, track0, 0x85, ZP_TRK])
    c += bytes([0xA9, 0x01, 0x85, ZP_SEC])
    c += bytes([0xA9, nsect, 0x85, ZP_CNT])
    seek = here()
    c += bytes([0xA5, ZP_TRK, 0x8D, 0x13, 0x03])            # lda trk : sta data
    c += bytes([0xA9, 0x18, 0x8D, 0x10, 0x03])              # seek, head load, no verify
    wait_calls = [len(c)]
    c += bytes([0x20, 0x00, 0x00])                          # jsr wait (patched)
    rd = here()
    c += bytes([0xA5, ZP_SEC, 0x8D, 0x12, 0x03])            # lda sec : sta sector
    c += bytes([0xA9, 0x80, 0x8D, 0x10, 0x03])              # read sector
    c += bytes([0xA0, 0x00])                                # ldy #0
    drq = here()
    c += bytes([0xAD, 0x18, 0x03])                          # lda $0318
    c += bytes([0x30, (drq - (here() + 2)) & 0xFF])         # bmi drq (DRQ active low)
    c += bytes([0xAD, 0x13, 0x03, 0x91, ZP_PTR, 0xC8])      # lda data : sta (ptr),y : iny
    c += bytes([0xD0, (drq - (here() + 2)) & 0xFF])         # bne drq
    wait_calls.append(len(c))
    c += bytes([0x20, 0x00, 0x00])                          # jsr wait
    c += bytes([0xE6, ZP_PTR + 1])                          # inc ptr hi
    c += bytes([0xC6, ZP_CNT])                              # dec cnt
    beq_done = len(c)
    c += bytes([0xF0, 0x00])                                # beq done (patched)
    c += bytes([0xE6, ZP_SEC, 0xA5, ZP_SEC, 0xC9, SECTORS + 1])  # inc sec : lda sec : cmp #18
    c += bytes([0xD0, (rd - (here() + 2)) & 0xFF])          # bne rd
    c += bytes([0xA9, 0x01, 0x85, ZP_SEC, 0xE6, ZP_TRK])    # sec = 1 : inc trk
    c += bytes([0x4C, seek & 0xFF, seek >> 8])              # jmp seek
    done = here()
    c[beq_done + 1] = (done - (0x0500 + beq_done + 2)) & 0xFF
    c += bytes([0x4C, 0x00, 0x06])                          # jmp $0600
    wait = here()
    c += bytes([0xA2, 0x10, 0xCA, 0xD0, 0xFD])              # short delay (busy settles)
    wl = here()
    c += bytes([0xAD, 0x10, 0x03, 0x29, 0x01])              # lda status : and #1
    c += bytes([0xD0, (wl - (here() + 2)) & 0xFF])          # bne (busy)
    c += bytes([0x60])                                      # rts
    for pos in wait_calls:
        c[pos + 1] = wait & 0xFF
        c[pos + 2] = wait >> 8
    return bytes(c)


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


def main():
    out, scr_p, main_p, ovl_p = sys.argv[1:5]
    scr, game, ovl = (open(p, 'rb').read() for p in (scr_p, main_p, ovl_p))
    nsect = (len(ovl) + 255) // 256
    tap2dsk = os.environ.get('TAP2DSK', 'tap2dsk')
    with tempfile.TemporaryDirectory() as tmp:
        # first pass: how many tracks do the Sedoric files need?
        for attempt in range(2):
            track0 = 0 if attempt == 0 else ntracks
            stub = boot_stub(track0, nsect)
            tap = os.path.join(tmp, 'disk.tap')
            with open(tap, 'wb') as f:
                f.write(tape_file('SCR', 0xA000, scr))
                f.write(tape_file('GAME', 0x0600, game))
                f.write(tape_file('BOOT', 0x0500, stub))
            old = os.path.join(tmp, 'old.dsk')
            subprocess.run([tap2dsk, '-iHIRES:LOAD"SCR.BIN":LOAD"GAME.BIN":LOAD"BOOT.BIN":CALL#500',
                            '-nTURBO ESPRIT', tap, old], check=True, capture_output=True)
            img = open(old, 'rb').read()
            assert img[:8] == b'ORICDISK'
            sides, ntracks, nsec = struct.unpack_from('<iii', img, 8)
            assert sides == 1 and nsec == SECTORS
        secs = [img[256 + i * 256:256 + (i + 1) * 256] for i in range(ntracks * SECTORS)]
        # the overlay, raw, from track `ntracks` sector 1 on
        ovl = ovl + bytes(nsect * 256 - len(ovl))
        secs += [ovl[i * 256:(i + 1) * 256] for i in range(nsect)]
        total = (len(secs) + SECTORS - 1) // SECTORS
        secs += [bytes(256)] * (total * SECTORS - len(secs))
    hdr = b'MFM_DISK' + struct.pack('<iii', 1, total, 1)
    hdr += bytes(256 - len(hdr))
    disk = bytearray(hdr)
    for t in range(total):
        disk += mfm_track(t, secs[t * SECTORS:(t + 1) * SECTORS])
    open(out, 'wb').write(disk)
    print('%s: %d tracks (Sedoric %d, overlay %d sectors from track %d)'
          % (out, total, ntracks, nsect, ntracks))


if __name__ == '__main__':
    main()
