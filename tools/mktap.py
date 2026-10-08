#!/usr/bin/env python3
"""Build the Oric tape (64K Atmos with Microdisc-style overlay RAM).

usage: mktap.py out.tap SCREEN.bin OVERLAY.bin MAIN.bin

Tape files:
  1. BASIC loader (autorun) with a small machine-code relocator after it:
       10 HIRES:CLOAD"":CLOAD"":CALL#<reloc>:CLOAD"":CALL#600
  2. the loading screen, loaded at $A000
  3. the overlay part of the game, loaded at $0600 and copied by the
     relocator to $C000.. with the ROM switched off (Microdisc control
     register $0314: bit 1 = 0 maps the RAM under the ROM, bit 7 = 1 keeps
     the disk EPROM out).  If there is no RAM there, the relocator prints a
     message and stops.
  4. the main part of the game at $0600, which starts at $0600.
"""
import sys

TOK_HIRES, TOK_CLOAD, TOK_CALL = 0xA2, 0xB6, 0xBF
OVL_TEMP = 0x0600
OVL_DEST = 0xC000


def header(typ, auto, start, end, name):
    return (bytes([0x16] * 3 + [0x24, 0x00, 0x00, typ, auto,
                                end >> 8, end & 0xFF, start >> 8, start & 0xFF, 0x00])
            + name.encode('ascii')[:15] + b'\x00')


def relocator(org, length):
    """6502 code: copy `length` bytes OVL_TEMP -> OVL_DEST under the ROM."""
    pages = (length + 255) // 256
    msg = b'THIS VERSION NEEDS A 64K ORIC (MICRODISC)'
    c = bytearray()
    c += bytes([0x78])                                  # sei
    c += bytes([0xA9, 0x80, 0x8D, 0x14, 0x03])          # lda #$80 : sta $0314 (ROM off)
    c += bytes([0xA9, 0xA5, 0x8D, 0x00, 0xC0])          # lda #$A5 : sta $C000
    c += bytes([0xCD, 0x00, 0xC0])                      # cmp $C000
    bne_fail = len(c)
    c += bytes([0xD0, 0x00])                            # bne fail (patched)
    c += bytes([0xA0, 0x00])                            # ldy #0
    c += bytes([0xA2, pages])                           # ldx #pages
    loop = len(c)
    src = org + len(c)
    c += bytes([0xB9, OVL_TEMP & 0xFF, OVL_TEMP >> 8])  # lda OVL_TEMP,y   (hi patched)
    dst = org + len(c)
    c += bytes([0x99, OVL_DEST & 0xFF, OVL_DEST >> 8])  # sta OVL_DEST,y   (hi patched)
    c += bytes([0xC8])                                  # iny
    c += bytes([0xD0, (loop - (len(c) + 2)) & 0xFF])    # bne loop
    c += bytes([0xEE, (src + 2) & 0xFF, (src + 2) >> 8])  # inc src hi
    c += bytes([0xEE, (dst + 2) & 0xFF, (dst + 2) >> 8])  # inc dst hi
    c += bytes([0xCA])                                  # dex
    c += bytes([0xD0, (loop - (len(c) + 2)) & 0xFF])    # bne loop
    c += bytes([0xA9, 0x82, 0x8D, 0x14, 0x03])          # lda #$82 : sta $0314 (ROM back)
    c += bytes([0x58, 0x60])                            # cli : rts
    fail = len(c)
    c[bne_fail + 1] = (fail - (bne_fail + 2)) & 0xFF
    c += bytes([0xA9, 0x82, 0x8D, 0x14, 0x03])          # ROM back on
    c += bytes([0xA2, 0x00])                            # ldx #0
    ml = len(c)
    c += bytes([0xBD, 0, 0])                            # lda msg,x (patched)
    c += bytes([0x9D, 0x80 + 40, 0xBF])                 # sta $BFA8,x (text line 1)
    c += bytes([0xE8, 0xE0, len(msg)])                  # inx : cpx #len
    c += bytes([0xD0, (ml - (len(c) + 2)) & 0xFF])      # bne
    c += bytes([0x4C, (org + len(c)) & 0xFF, (org + len(c)) >> 8])  # jmp * (stop)
    m_addr = org + len(c)
    c[ml + 1] = m_addr & 0xFF
    c[ml + 2] = m_addr >> 8
    c += msg
    return bytes(c)


def loader(ovl_len):
    start = 0x0501
    # first pass to find where the relocator goes
    for reloc in (0x0540, 0x0560):
        body = bytes([TOK_HIRES]) + b':' + bytes([TOK_CLOAD]) + b'""'
        body += b':' + bytes([TOK_CLOAD]) + b'""'
        body += b':' + bytes([TOK_CALL]) + ('#%X' % reloc).encode('ascii')
        body += b':' + bytes([TOK_CLOAD]) + b'""'
        body += b':' + bytes([TOK_CALL]) + b'#600'
        nxt = start + 4 + len(body) + 1
        prog = bytes([nxt & 0xFF, nxt >> 8, 10, 0]) + body + b'\x00' + b'\x00\x00'
        if start + len(prog) <= reloc:
            break
    prog += bytes(reloc - (start + len(prog)))
    prog += relocator(reloc, ovl_len)
    assert start + len(prog) <= 0x0600
    return header(0x00, 0xC7, start, start + len(prog) - 1, 'TURBO') + prog


def main():
    out, scr, ovl, game = sys.argv[1:5]
    scr, ovl, game = (open(p, 'rb').read() for p in (scr, ovl, game))
    tape = bytearray(loader(len(ovl)))
    tape += header(0x80, 0x00, 0xA000, 0xA000 + len(scr) - 1, 'SCREEN') + scr
    tape += header(0x80, 0x00, OVL_TEMP, OVL_TEMP + len(ovl) - 1, 'ESPRIT1') + ovl
    tape += header(0x80, 0x00, 0x0600, 0x0600 + len(game) - 1, 'ESPRIT2') + game
    open(out, 'wb').write(tape)


if __name__ == '__main__':
    main()
