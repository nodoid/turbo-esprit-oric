#!/usr/bin/env python3
"""Generate data/snd_data.s: the three tunes of Turbo Esprit for the AY.

The original music player (E441, bytecode E6D8-E832, see R8 section 2) is
re-run here frame by frame (the same interpreter as the verified reference
model).  On the Spectrum the two voices of the menu tunes were
time-multiplexed on the beeper (one frame each, alternately); on the AY both
voices sound at the same time, so each voice's notes start on exactly the
frame they started in the original and last until that voice's next event.
Rests, the one-frame gap that articulates a repeated note, the single-voice
section of tune B and the end of each tune are kept frame-exact.

Output per tune and voice: a run list `note, frames` (note = index into the
period table, 0 = silence), terminated by $FF.  Voice A's list ends on the
frame where the original tune ended (music_busy goes to 0 then).

usage: gen_snd.py [orig/TurboEsprit.tzx] [data/snd_data.s]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zxtape  # noqa: E402

DUR_T, PER_T = 0xE6B0, 0xE6C0
TUNES = [('menu_a', 0xE807, 0xE81D), ('menu_b', 0xE80E, 0xE824), ('start', 0xE82B, None)]


class Ch:
    def __init__(s, i, ptr, flags):
        s.i, s.ptr, s.flags = i, ptr, flags
        s.stack, s.count, s.tr, s.tempo, s.dur, s.last, s.loop, s.note = [], 1, 0, 1, 1, 0, 0, None


def simulate(M, p0, p1):
    """Frame-by-frame run of the original player (R8 2.3).  Returns
    (frames, [timeline ch0, timeline ch1]) where timeline[f] is the note
    number sounding on that voice during frame f, or None."""
    DUR = list(M[DUR_T:DUR_T + 16])
    ch = [Ch(0, p0, 0), Ch(1, p1 if p1 is not None else p0, 8)]
    st = {'dual': False, 'ended': 0}

    def nextnote(c):
        c.count -= 1
        if c.count == 0:
            while True:
                b = M[c.ptr]
                if b < 0x80:
                    c.count = b
                    c.ptr += 1
                    break
                cmd = b & 0x7F
                if cmd == 0:
                    if not (c.flags & 2):
                        c.flags |= 2
                        st['ended'] += 1
                        if st['ended'] == 2 or not (c.flags & 8):
                            return 'STOP'
                    c.dur, c.count, c.note = 1, 1, None
                    return 'SIL'
                elif cmd == 1:
                    c.tr = M[c.ptr + 1]; c.ptr += 2
                elif cmd == 2:
                    c.tr = (c.tr + M[c.ptr + 1]) & 0xFF; c.ptr += 2
                elif cmd == 3:
                    c.tempo = M[c.ptr + 1]; c.ptr += 2
                elif cmd == 4:
                    c.tempo = (c.tempo + M[c.ptr + 1]) & 0xFF; c.ptr += 2
                elif cmd == 5:
                    c.ptr = M[c.ptr + 1] | M[c.ptr + 2] << 8
                elif cmd == 6:
                    c.stack.append(c.ptr + 3); c.ptr = M[c.ptr + 1] | M[c.ptr + 2] << 8
                elif cmd == 7:
                    c.ptr = c.stack.pop()
                elif cmd == 8:
                    if c.flags & 8:
                        st['dual'] = False; c.flags &= ~8
                        c.tempo = ((c.tempo << 1) | (c.tempo >> 7)) & 0xFF
                    else:
                        st['dual'] = True; c.flags |= 8
                        c.tempo = ((c.tempo >> 1) | ((c.tempo & 1) << 7)) & 0xFF
                    c.ptr += 1
                elif cmd == 9:
                    e = M[c.ptr + 1] | M[c.ptr + 2] << 8
                    a = (c.loop or M[c.ptr + 3]) - 1
                    c.loop = a; c.ptr += 4
                    if a:
                        c.ptr = e
                else:
                    raise ValueError('bad music command %02X' % b)
        b = M[c.ptr]; c.ptr += 1
        c.dur = (DUR[b >> 4] * c.tempo) & 0xFF
        if b & 15 == 0:
            c.note = None
            return 'REST'
        n = ((b & 15) + c.tr) & 0xFF
        rep = n == c.last
        c.last = c.note = n
        return 'REP' if rep else 'NOTE'

    cur = 0
    gap = None
    c = ch[0]
    c.dur -= 1
    if c.dur == 0:
        nextnote(c)
    tl = [[], []]
    frame = 0
    while frame < 20000:
        for k in (0, 1):
            if k == cur:
                tl[k].append(None if gap == (frame, k) else ch[k].note)
            elif st['dual']:
                tl[k].append(ch[k].note)
            else:
                tl[k].append(None)
        frame += 1
        if st['dual']:
            cur ^= 1
        c = ch[cur]
        c.dur = (c.dur - 1) & 0xFF
        if c.dur == 0:
            r = nextnote(c)
            if r == 'STOP':
                return frame, tl
            if r == 'REP':
                gap = (frame, cur)
    raise RuntimeError('tune did not end')


def halfT(PER, n):
    o, a = divmod(n, 12)
    p = PER[a]
    if o:
        p = (p >> o) + ((p >> (o - 1)) & 1)
    hl = (p - 16) & 0xFFFF
    h, l = hl >> 8, hl & 0xFF
    return 16 * (l >> 2) + 4 * (l & 3) + 1023 * h + 72


def ay_period(PER, n):
    """AY tone period (1 MHz clock) for the original's note n."""
    return round(halfT(PER, n) / 28.0)


def runs(tl):
    """Collapse a timeline into [note, frames, gap] runs.  gap = 1 when the
    run starts with one silent frame (the original's articulation of a
    repeated note, or any single-frame rest before a note)."""
    out = []
    for s in tl:
        if out and out[-1][0] == s and out[-1][1] < 255:
            out[-1][1] += 1
        else:
            out.append([s, 1, 0])
    m = []
    for r in out:
        if m and m[-1][0] is None and m[-1][1] == 1 and r[0] is not None and r[1] < 255:
            m[-1] = [r[0], r[1] + 1, 1]
        else:
            m.append(r)
    return m


# ---------------------------------------------------------------------------
# Sound effects (R8 1.1-1.4).  One step per 50 Hz frame:
#   (volume, tone period or None, noise period or None)
# AY period = beeper half-period T / 28.  The original effects lasted a few
# ms each (they blocked the CPU); here the shortest step is one frame.

ROM0 = [0xF3, 0xAF, 0x11, 0xFF, 0xFF, 0xC3, 0xCB, 0x11, 0x2A, 0x5D, 0x5C, 0x22, 0x5F, 0x5C,
        0x18, 0x43, 0xC3, 0xF2, 0x15, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x2A, 0x5D, 0x5C, 0x7E,
        0xCD, 0x7D, 0x00, 0xD0, 0xCD, 0x74, 0x00, 0x18, 0xF7, 0xFF, 0xFF, 0xFF]   # ROM 0000-0027


def beep(C, N=0x20):
    """AY period of SA964's tone: half-period C*(13N+18)+47 T."""
    return round((C * (13 * N + 18) + 47) / 28.0)


def crash(B, frames, tone):
    """S6 (S8EBF): B cycles through ROM[0..2B-1]; each byte n is a half-period
    of 13n+40 T.  Recreated as a decaying noise burst whose noise/tone pitch
    follows the same ROM bytes (so it has the original's irregular colour)."""
    steps = []
    for f in range(frames):
        i = (f * 2 * B) // frames
        n1, n2 = ROM0[i] or 256, ROM0[i + 1] or 256
        per = round((13 * (n1 + n2) + 79) / 2 / 28.0)
        vol = max(1, 15 - (f * 15) // frames)
        steps.append((vol, per if tone else None, min(31, max(1, (n1 + n2) // 16))))
    return steps


FX = [
    # id 1 S3 message beep: (C=1,B=100) 3638 Hz 14 ms, (C=2,B=60) 1913 Hz 16 ms
    ('fx_beep', 3, [(13, beep(1), None), (13, beep(2), None)]),
    # id 2 S4 rev blip: procedural (snd.s), placeholder
    ('fx_rev', 1, []),
    # id 3 S5 tyre screech: ~1.67 kHz squeal (half-period ~1050 T) for one
    # view copy (~32 ms); the AY version adds a little noise for the scrub
    ('fx_screech', 2, [(11, 37, 1), (10, 40, 2)]),
    # id 4 S6 crash noise: see crash() (B = 5 gunshot / 10 crash / 20 struck)
    ('fx_crash', 4, []),
    # id 5 S7 penalty chirp: the original falls 15 kHz..1.5 kHz in 53 ms
    # (periods 4,7,4,7,12,22,42); here a smooth falling sweep down to 1.5 kHz
    ('fx_chirp', 4, [(12, 6, None), (12, 9, None), (12, 13, None), (11, 18, None),
                     (11, 25, None), (10, 33, None), (9, 42, None)]),
    # id 6 S8 indicator tick: procedural
    ('fx_tick', 1, []),
    # id 7 S9 key prompt: (2,20) 1913 Hz, (1,40) 3638 Hz, (4,20) 982 Hz
    ('fx_keyblip', 3, [(13, beep(2), None), (13, beep(1), None), (13, beep(4), None)]),
    # id 8 S10 invalid skill digit: 1913 Hz, 12.5 ms
    ('fx_badkey', 3, [(13, beep(2), None)]),
    # id 9 S11 tape error: 497 Hz, 0.24 s
    ('fx_tapeerr', 5, [(13, beep(8), None)] * 11 + [(8, beep(8), None)]),
]
# the gunshot (B=5, 22 ms) is a short sharp noise crack rather than the ROM-coloured rumble
CRASH = [('fx_gunshot', [(15, None, 3), (12, None, 6), (8, None, 9), (4, None, 13)]), ('fx_bang', crash(10, 8, True)),
         ('fx_struck', crash(20, 12, True))]


def fx_lines():
    """Script format, one step per 1-4 frames:
       byte 0 = volume (bits 0-3) | extra frames (bits 4-5) | $40 tone off |
                $80 noise on;  $FF = end
       byte 1 = tone period (all effect periods are < 256)
       byte 2 = noise period (only when $80 is set)"""
    L = ['; --- sound-effect scripts ---',
         '; vol | extra frames << 4 | $40 tone off | $80 noise ($FF = end), period [, noise period]']
    tab, prio = [], []
    scripts = [(n, st) for n, _, st in FX if st] + CRASH
    for name, steps in scripts:
        L.append('%s:' % name)
        merged = []
        for st in steps:
            if merged and merged[-1][0] == st and merged[-1][1] < 4:
                merged[-1][1] += 1
            else:
                merged.append([st, 1])
        for (vol, per, nz), k in merged:
            b0 = vol | (k - 1) << 4 | (0x40 if per is None else 0) | (0x80 if nz is not None else 0)
            assert b0 != 0xFF and (per or 0) < 256
            bs = [b0, per or 0] + ([nz] if nz is not None else [])
            L.append('        .byte ' + ', '.join('$%02X' % x for x in bs))
        L.append('        .byte $FF')
    for name, pr, st in FX:
        tab.append(name if st else '0')
        prio.append(str(pr))
    L.append('; script per effect id 1..9 (0 = computed), and its priority')
    L.append('fx_tab: .addr ' + ', '.join(tab))
    L.append('fx_prio: .byte ' + ', '.join(prio))
    L.append('fx_crashtab: .addr ' + ', '.join(n for n, _ in CRASH))
    return L


def compress(lists):
    """Encode run lists with back references.  A run is 2 bytes (note | $80
    gap, frames), or 1 byte (note | $80 gap | $40) for an 8-frame run; $FE lo hi n = play n runs stored at lo hi (literal runs of
    an earlier list or of this one, never another reference); $FF = end."""
    lit = []            # (list no, byte offset, token, region id)
    out = []
    region = 0
    for li, toks in enumerate(lists):
        items, off, i = [], 0, 0
        region += 1
        while i < len(toks):
            best = (0, None)
            for j in range(len(lit)):
                k = 0
                while (i + k < len(toks) and j + k < len(lit) and lit[j + k][2] == toks[i + k]
                       and lit[j + k][3] == lit[j][3] and k < 255):
                    k += 1
                if k > best[0]:
                    best = (k, j)
            if best[0] >= 3:
                k, j = best
                items.append(('ref', lit[j][0], lit[j][1], k))
                off += 4
                i += k
                region += 1
            else:
                items.append(('lit', toks[i]))
                lit.append((li, off, toks[i], region))
                off += 1 if toks[i][1] == 8 else 2
                i += 1
        out.append(items)
    return out


def main():
    tape = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'orig', 'TurboEsprit.tzx')
    outp = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, '..', 'data', 'snd_data.s')
    M = zxtape.load_image(tape)
    PER = [M[PER_T + 2 * i] | M[PER_T + 2 * i + 1] << 8 for i in range(12)]
    tunes = []
    notes = set()
    for name, a, b in TUNES:
        n, tl = simulate(M, a, b)
        ra, rb = runs(tl[0]), runs(tl[1]) if b is not None else []
        # voice B: drop the trailing silence (an idle voice is silent anyway)
        while rb and rb[-1][0] is None:
            rb.pop()
        for r in ra + rb:
            if r[0] is not None:
                notes.add(r[0])
        tunes.append((name, n, ra, rb))
    notes = sorted(notes)
    idx = {n: i + 1 for i, n in enumerate(notes)}
    L = ['; snd_data.s - generated by tools/gen_snd.py from the original tape. Do not edit.',
         '; Tunes of the E441 music player as AY run lists: note index (+$80: the first',
         '; frame is silent; +$40: 8 frames, else a frames byte follows);',
         '; $FE lo hi n = n runs from lo hi; $FF = end.',
         '; Then the sound-effect scripts.',
         '', '        .export snd_ptab, snd_tunes, fx_tab, fx_prio, fx_crashtab', '        .rodata', '']
    per = [ay_period(PER, n) for n in notes]
    assert all(p < 256 for p in per[1:]) and 256 <= per[0] < 512
    L.append('; AY tone periods (1 MHz) of the original notes: half-period T / 28;')
    L.append('; index 1 (the lowest note) has period $100 + its byte')
    L.append('snd_ptab: .byte 0' + ''.join(',$%02X' % (p & 0xFF) for p in per))
    L.append('; note numbers: ' + ' '.join(str(n) for n in notes))
    L.append('')
    L.append('; tune table: voice A list, voice B list')
    L.append('snd_tunes: .addr ' + ', '.join('%s_a, %s_b' % (t[0], t[0]) for t in tunes))
    names, lists = [], []
    for name, n, ra, rb in tunes:
        for v, rl in (('a', ra), ('b', rb)):
            names.append('%s_%s' % (name, v))
            lists.append([((idx[s_] if s_ is not None else 0) | (0x80 if g else 0), k) for s_, k, g in rl])
    total = 0
    for nm, items in zip(names, compress(lists)):
        L.append('%s:' % nm)
        flat = []
        for it in items:
            if it[0] == 'lit' and it[1][1] == 8:
                flat.append('$%02X' % (it[1][0] | 0x40))
                total += 1
            elif it[0] == 'lit':
                flat.append('$%02X,$%02X' % it[1])
                total += 2
            else:
                flat.append('$FE,<(%s+%d),>(%s+%d),%d' % (names[it[1]], it[2], names[it[1]], it[2], it[3]))
                total += 4
        flat.append('$FF')
        total += 1
        for i in range(0, len(flat), 8):
            L.append('        .byte ' + ','.join(flat[i:i + 8]))
    L.append('')
    L += fx_lines()
    open(outp, 'w').write('\n'.join(L) + '\n')
    print('wrote %s: %d notes, %d bytes of tune data; lengths %s' %
          (outp, len(notes), total, ', '.join('%s %d' % (t[0], t[1]) for t in tunes)))


if __name__ == '__main__':
    main()
