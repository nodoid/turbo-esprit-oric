#!/usr/bin/env python3
"""Tests for src/snd.s (AY sound engine).

Builds hw.s + snd.s, runs them on a 6502 with the harness's VIA/AY model
and checks the AY register writes frame by frame:
  1. music: for every frame of the three tunes, the note heard on AY
     channels A and B (period, volume > 0) equals the note the original
     player (E441, re-run by tools/gen_snd.py) sounded on that voice;
     music_busy stays set exactly as long as the original tune ran.
  2. effects S3-S11: periods/durations against the R8 catalogue.
  3. engine drone: follows snd_engine, glides, effect channel allocation.
  4. keyboard: key_row/Z_F37A always read the right keys while the 50Hz
     interrupt plays music (AY register 14 is never disturbed).
"""
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU  # noqa: E402
import harness  # noqa: E402
import gen_snd  # noqa: E402
import zxtape  # noqa: E402

STOP = 0x0300


class Oric:
    def __init__(self, name='snd', mods=('src/hw.s', 'src/snd.s')):
        r = subprocess.run([sys.executable, 'tools/buildtest.py', name] + list(mods),
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr)
            raise SystemExit(1)
        self.m = harness.Machine()
        data = open('build/test_%s.bin' % name, 'rb').read()
        self.m.ram[0x600:0x600 + len(data)] = data
        self.sym = {}
        for line in open('build/test_%s.lbl' % name):
            p = line.split()
            self.sym[p[2].lstrip('.')] = int(p[1], 16)
        self.mpu = MPU(memory=harness.Mem(self.m), pc=0)
        self.mpu.sp = 0xFF
        self.m.aylog = []

    def call(self, name, a=0, x=0, y=0, irq=False, maxc=5_000_000):
        mpu, m = self.mpu, self.m
        mpu.sp = 0xFF
        mpu.stPushWord(STOP - 1)
        mpu.pc = self.sym[name] if isinstance(name, str) else name
        mpu.a, mpu.x, mpu.y = a, x, y
        mpu.p = 0x20 | (0 if irq else mpu.INTERRUPT)
        start = mpu.processorCycles
        while mpu.pc != STOP:
            mpu.step()
            m.cycles = mpu.processorCycles
            if irq and (m.ier & 0x40) and m.t1_count() > m.t1_ack and not (mpu.p & mpu.INTERRUPT):
                m.t1_ack = m.t1_count()
                mpu.stPushWord(mpu.pc)
                mpu.stPush(mpu.p & ~mpu.BREAK | mpu.UNUSED)
                mpu.p |= mpu.INTERRUPT
                mpu.pc = m.ram[0xFFFE] | (m.ram[0xFFFF] << 8)
            if mpu.processorCycles - start > maxc:
                raise RuntimeError('no return from %s (pc=%04X)' % (name, mpu.pc))
        return mpu.processorCycles - start

    def tick(self):
        """one 50Hz frame: returns the AY registers after snd_tick"""
        self.m.ram[self.sym['frames']] = (self.m.ram[self.sym['frames']] + 1) & 0xFF
        c = self.call('snd_tick')
        return list(self.m.ay), c

    def zp(self, name):
        return self.m.ram[self.sym[name]]


def chan(ay, k):
    return (ay[2 * k] | (ay[2 * k + 1] & 15) << 8, ay[8 + k] & 15, not (ay[7] >> k) & 1,
            not (ay[7] >> (3 + k)) & 1)


def test_music(o, M, PER):
    bad = 0
    maxcyc = 0
    for tid, (name, a, b) in enumerate(gen_snd.TUNES):
        n, tl = gen_snd.simulate(M, a, b)
        if b is None:
            tl[1] = [None] * n
        o.call('music_start', a=tid)
        heard = [[], []]
        busy = 0
        for f in range(n + 5):
            ay, c = o.tick()
            maxcyc = max(maxcyc, c)
            if o.zp('music_busy'):
                busy += 1
            for k in (0, 1):
                per, vol, ton, _ = chan(ay, k)
                heard[k].append(per if vol and ton else None)
        diffs = []
        for k in (0, 1):
            for f in range(n):
                exp = gen_snd.ay_period(PER, tl[k][f]) if tl[k][f] is not None else None
                if heard[k][f] != exp:
                    diffs.append((f, k, exp, heard[k][f]))
            for f in range(n, n + 5):
                if heard[k][f] is not None:
                    diffs.append((f, k, 'silence', heard[k][f]))
        notes = sum(1 for k in (0, 1) for f in range(n) if tl[k][f] is not None)
        both = sum(1 for f in range(n) if tl[0][f] is not None and tl[1][f] is not None)
        print('  %-7s %4d frames: %4d voice-frames sounding (%d with both voices), busy %d frames, %d diffs %s'
              % (name, n, notes, both, busy, len(diffs), diffs[:5]))
        bad += len(diffs) + (busy != n)
    print('  snd_tick max %d cycles per frame' % maxcyc)
    return bad


def run_fx(o, fid, x=0, frames=20):
    o.call('snd_fx', a=fid, x=x)
    out = []
    for f in range(frames):
        ay, _ = o.tick()
        out.append(ay)
    return out


def test_fx(o):
    bad = 0
    o.call('music_stop')
    o.call('snd_engine', a=0)
    for _ in range(3):
        o.tick()

    def seg(out, k=1):
        r = []
        for ay in out:
            per, vol, ton, nz = chan(ay, k)
            if vol == 0:
                break
            r.append((per if ton else None, vol, ay[6] if nz else None))
        return r
    exp = {
        'BEEP': (1, 0, [17, 33]), 'KEYBLIP': (7, 0, [33, 17, 64]), 'BADKEY': (8, 0, [33]),
        'TAPEERR': (9, 0, [126] * 12), 'CHIRP': (5, 0, [6, 9, 13, 18, 25, 33, 42]),
        'SCREECH': (3, 0, [37, 40]), 'TICK8': (6, 8, [126]), 'TICK16': (6, 16, [250]),
        'REV32': (2, 32, [111]), 'REV5': (2, 5, [19]),
    }
    for nm, (fid, x, pers) in exp.items():
        s = seg(run_fx(o, fid, x))
        got = [p for p, v, nz in s]
        ok = got == pers
        # rev blip formula vs the exact (96C+47)/28: allow +-1
        if nm.startswith('REV') or nm.startswith('TICK'):
            ok = len(got) == 1 and abs(got[0] - pers[0]) <= 1
        print('  %-8s periods %s %s' % (nm, got, 'ok' if ok else 'EXPECTED %s' % pers))
        bad += not ok
    for b in (5, 10, 20):
        s = seg(run_fx(o, 4, b))
        print('  CRASH B=%-2d %2d frames, noise %s, vol %s' % (b, len(s), [z for _, _, z in s], [v for _, v, _ in s]))
        bad += not (len(s) >= 4 and all(z is not None for _, _, z in s))
    # priority: a tick does not cut a crash, a crash cuts a tick
    o.call('snd_fx', a=4, x=10)
    o.tick()
    o.call('snd_fx', a=6, x=8)
    ay, _ = o.tick()
    p1 = chan(ay, 1)
    ok = p1[3] == 1
    o.call('snd_fx', a=6, x=8)
    o.call('snd_fx', a=4, x=5)
    ay, _ = o.tick()
    ok = ok and chan(ay, 1)[3] == 1
    print('  priority (crash not cut by tick; crash replaces tick): %s' % ('ok' if ok else 'FAIL'))
    bad += not ok
    for _ in range(20):
        o.tick()
    return bad


def test_engine(o):
    bad = 0
    o.call('snd_engine', a=1)
    ay, _ = o.tick()
    per, vol, ton, _ = chan(ay, 2)
    ok = per == round(1e6 / 16 / 58) and vol in (4, 5) and ton
    o.call('snd_engine', a=17)
    seq = []
    for _ in range(16):
        ay, _ = o.tick()
        seq.append(chan(ay, 2)[0])
    tgt = round(1e6 / 16 / (50 + 8 * 17))
    ok = ok and seq[-1] == tgt and seq[0] > seq[1] > seq[2]
    print('  engine: revs 1 -> period %d vol %d; revs 17 glide %s -> %d %s' % (per, vol, seq[:6], tgt, 'ok' if ok else 'FAIL'))
    bad += not ok
    # effect while the menu music plays goes to C (B is a music voice), engine yields
    o.call('music_start', a=0)
    o.tick()
    o.call('snd_fx', a=1)
    ay, _ = o.tick()
    c = chan(ay, 2)
    ok2 = c[0] == 17 and c[1] == 13
    # without music: effect on B, engine keeps C
    o.call('music_stop')
    o.tick()
    o.call('snd_fx', a=1)
    ay, _ = o.tick()
    ok2 = ok2 and chan(ay, 1)[0] == 17 and chan(ay, 2)[0] == tgt and chan(ay, 2)[1] > 0
    print('  channel allocation (fx on C under music, on B with engine on C): %s' % ('ok' if ok2 else 'FAIL'))
    bad += not ok2
    o.call('snd_engine', a=0)
    ay, _ = o.tick()
    bad += chan(ay, 2)[1] != 0
    return bad


def test_keys(o):
    """key_row with the real 50Hz IRQ playing music: every read must be right."""
    o.call('hw_init')
    o.call('music_start', a=1)
    m = o.m
    m.pressed = {harness.KEYMAP['J'], harness.KEYMAP['S']}
    wrong = reads = 0
    irqs0 = m.ram[o.sym['frames']]
    for i in range(1500):
        row = i & 7
        o.call('key_row', x=row, irq=True)
        exp = 0
        for r, cc in m.pressed:
            if r == row:
                exp |= 1 << cc
        reads += 1
        wrong += o.mpu.a != exp
    nirq = (m.ram[o.sym['frames']] - irqs0) & 0xFF
    w = sum(1 for _, r, v in m.aylog if r == 7 and not v & 0x40)
    print('  key_row under IRQ music: %d reads, %d wrong, ~%d interrupts, mixer writes with port A input: %d'
          % (reads, wrong, nirq, w))
    return wrong + w + (nirq == 0)


def main():
    M = zxtape.load_image(os.path.join(ROOT, 'orig', 'TurboEsprit.tzx'))
    PER = [M[gen_snd.PER_T + 2 * i] | M[gen_snd.PER_T + 2 * i + 1] << 8 for i in range(12)]
    o = Oric()
    bad = 0
    print('music (AY A/B vs the original player, frame by frame):')
    bad += test_music(o, M, PER)
    print('effects:')
    bad += test_fx(o)
    print('engine:')
    bad += test_engine(o)
    print('keyboard:')
    bad += test_keys(o)
    print('RESULT: %s (%d failures)' % ('PASS' if not bad else 'FAIL', bad))
    return bad


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
