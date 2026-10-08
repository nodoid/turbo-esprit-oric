#!/usr/bin/env python3
"""Differential test of src/traffic.s (Spectrum $AB47-$BA55 + $E833-$E94C)
against the real game.

Captures every call of SAB61 (one computer car, IY = its record) for a few
hundred main-loop passes in each of the 4 cities with random driving, runs
Z_AB61 from the same state on the 6502 and compares the whole identity range
$5B00-$7BBD plus every ZV_ variable (ours, and the side-street tables ZV_FD60
and the RNG seed ZV_9560).  Also checks whole SAB47 passes and the entry
points other modules call (SB412, SB3B3, SB241, SB0AA, SB91B, SB9EE, SB83A).

Routines of other modules that the traffic code calls are replaced by a
test-only helper module generated here (build/test_traffic_h/helpers.s):
  * Z_953B (RNG step, exact) and its seed ZV_9560;
  * ZV_FD60 ($2A0 bytes: the side-street tables);
  * Z_BA5F (sets the message flags in $760E/$760F and skips the inline data);
  * Z_DBFA does its first part (res 7,(iy+1)); for a criminal car (the part
    that touches the city map) the sample is counted as "skipped";
  * Z_DBD7/Z_DDD3 exact, Z_F36A only adds A to the score ($750B).

Rare paths (never reached in play) are tested by mutating real pre-states
(junction rule bits, blocked exits, one-way streets, a stopped criminal car,
odd grid codes...) and running the original Z80 routine from the mutated
state in the emulator as the judge ("forced" lines).

usage: test_traffic.py [passes_per_city] [seed]
"""
import os
import subprocess
import sys
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import random  # noqa: E402
from zxref import Ref, Sample, LD_A_R  # noqa: E402
from sim6502 import Sim, fmt_diffs  # noqa: E402

HELPERS = r'''
        .include "zx.inc"
        .export dbfa_hard, ext_hard
        .segment "DATA"
        ZVAR $9560, 2
        ZVAR $FD60, $2A0
dbfa_hard: .byte 0
ext_hard:  .byte 0
        .zeropage
hp:     .res 2
hn:     .res 1
m0:     .res 1
m1:     .res 1
r0:     .res 1
r1:     .res 1
k0:     .res 1
k1:     .res 1
        .code
; S953B: seed = seed*1509 + $29, HL = seed, A kept
        ZPROC $953B
        pha
        lda ZV_9560
        sta m0
        lda ZV_9560+1
        sta m1
        lda #0
        sta r0
        sta r1
        lda #<1509
        sta k0
        lda #>1509
        sta k1
@l:     lsr k1
        ror k0
        bcc @n
        clc
        lda r0
        adc m0
        sta r0
        lda r1
        adc m1
        sta r1
@n:     asl m0
        rol m1
        lda k0
        ora k1
        bne @l
        clc
        lda r0
        adc #$29
        sta ZV_9560
        sta zl
        lda r1
        adc #0
        sta ZV_9560+1
        sta zh
        pla
        rts
; LDBFA: res 7,(iy+1) ; criminal cars go back to the city map (not modelled)
        ZPROC $DBFA
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        ldy #2
        lda (ziyl),y
        and #6
        cmp #6
        bne :+
        inc dbfa_hard
:       rts
; SDBD7: IX = enemy-car record selected by rec+2 bits 3/4
        ZPROC $DBD7
        lda #$5E
        sta zixl
        lda #$78
        sta zixh
        ldy #2
        lda (ziyl),y
        and #8
        bne :+
        lda #$68
        sta zixl
        lda (ziyl),y
        and #$10
        beq :+
        lda #$72
        sta zixl
:       ldy #2
        lda (ziyl),y
        rts
; SDDD3: set 2 / res 1 of $785E+6, +16, +26
        ZPROC $DDD3
        ldx #0
        jsr @b
        ldx #10
        jsr @b
        ldx #20
@b:     lda $7864,x
        ora #4
        and #$FD
        sta $7864,x
        rts
; SF36A: score += A (the display update that follows is not modelled)
        ZPROC $F36A
        clc
        adc $750B
        sta $750B
        bcc :+
        inc $750C
:       rts
; SBA5F: message flags + skip the inline data (C, N, N items; >=$C0 = 3 bytes)
        ZPROC $BA5F
        lda $760E
        ora #4
        sta $760E
        lda #$28
        sta $760F
        pla
        sta hp
        pla
        sta hp+1
        ldy #2
        lda (hp),y
        sta hn
        iny
        lda hn
        beq @d
@i:     lda (hp),y
        cmp #$C0
        bcc :+
        iny
        iny
:       iny
        dec hn
        bne @i
@d:     tya
        clc
        adc hp
        sta hp
        bcc :+
        inc hp+1
:       jmp (hp)
'''

BIN = os.path.join(ROOT, 'build', 'test_traffic.bin')


def build():
    hdir = os.path.join(ROOT, 'build', 'test_traffic_h')
    os.makedirs(hdir, exist_ok=True)
    with open(os.path.join(hdir, 'helpers.s'), 'w') as f:
        f.write(HELPERS)
    r = subprocess.run([sys.executable, 'tools/buildtest.py', 'traffic', 'src/traffic.s',
                        'build/test_traffic_h/helpers.s'], cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.stderr.write(r.stderr)
        sys.exit(1)


class Stats:
    def __init__(self, name):
        self.name, self.ok, self.bad, self.skip, self.cyc, self.maxc = name, 0, 0, 0, 0, 0
        self.first = []

    def add(self, sim, s, diffs, skipped=False):
        if skipped:
            self.skip += 1
            return
        self.cyc += sim.cycles
        self.maxc = max(self.maxc, sim.cycles)
        if diffs:
            self.bad += 1
            if len(self.first) < 8:
                self.first.append((s, diffs))
        else:
            self.ok += 1

    def report(self):
        n = self.ok + self.bad
        avg = self.cyc // n if n else 0
        print('%-6s %6d ok %4d bad %4d skipped   avg %6d cyc  max %7d cyc' %
              (self.name, self.ok, self.bad, self.skip, avg, self.maxc))
        for s, d in self.first:
            iy = s.pre['iy']
            print('   iy=%04X rec pre %s  diffs: %s' %
                  (iy, bytes(s.pre_mem[iy:iy + 12]).hex(' '), fmt_diffs(d, 12)))


def exits_junction(s):
    iy = s.pre['iy']
    return (s.pre['bc'] & 0x40) and (s.pre['af'] & 1) and s.pre_mem[iy + 8] == 11


def run_one(sim, s, entry, a=None):
    sim.load_state(s.pre_mem, s.pre)
    sim.mem[sim.sym['dbfa_hard']] = 0
    sim.mem[sim.sym['ext_hard']] = 0
    sim.call(entry, rvals=s.rvals, a=a)
    hard = sim.mem[sim.sym['dbfa_hard']] or sim.mem[sim.sym['ext_hard']]
    # bytes below the entry SP are the Z80's own (dead) stack frames
    sp = s.pre['sp']
    return hard, sim.compare(s.post_mem, ignore=[(sp - 64, sp)])


def run_real(r, mem, regs, entry):
    """Run the original routine at `entry` from (mem, regs) in the emulator
    until it returns; None if it does not return within 20 frames."""
    z = r.z
    r.poke(0x4000, mem[0x4000:])
    for k in ('af', 'bc', 'de', 'hl', 'ix', 'iy', 'sp', 'alt_af', 'alt_bc', 'alt_de', 'alt_hl'):
        setattr(z, k, regs[k])
    sp = regs['sp']
    ret = mem[sp] | mem[sp + 1] << 8
    smp = Sample(dict(regs), bytes(mem))
    rpost = set(a + 2 for a in LD_A_R)

    def bp():
        if z.pc == ret and z.sp == sp + 2 and smp.post is None:
            smp.post = r.regs()
            smp.post_mem = r.mem()
            z.set_breakpoint(0x0038)     # park: stop doing anything useful
        elif z.pc in rpost and smp.post is None:
            smp.rvals.append(z.af >> 8)
    z.on_breakpoint = bp
    z.set_breakpoint(ret)
    for a in rpost:
        z.set_breakpoint(a)
    z.pc = entry
    for _ in range(20):
        r.run(1)
        if smp.post is not None:
            break
    z.on_breakpoint = lambda: None
    return smp if smp.post is not None else None


def mutate(rng, mem, iy):
    """Random change of the state that steers SAB61 into its rare paths."""
    m = bytearray(mem)
    k = rng.randrange(13)
    if k == 0:
        m[0x75EC] |= rng.choice((0x01, 0x20, 0x21))           # give-way checks
    elif k == 1:
        m[0x75F2] |= 1                                       # alt. junction rules
        m[0x75FA] = rng.randrange(256)
    elif k == 2:
        m[0x75F1] |= rng.choice((0x02, 0x08, 0x0A))          # ahead/behind blocked
        m[0x7602] = rng.choice((0x00, 0x01, 0x02, 0x03, 0x80, 0x82))
        m[iy + 10] = rng.choice((0x80, 0xC0, 0xD0, m[iy + 10])) | (m[iy + 10] & 3)
    elif k == 3:                                             # stopped criminal
        m[iy + 10] |= 0x20
        m[iy + 11] = 0
        m[iy + 2] = rng.choice((0x01, 0x03, 0x07, 0x0F, 0x17, 0x0B))
        m[0x75E1 + 6] = rng.randrange(256)
    elif k == 4:
        m[0x7601] ^= 0x80                                    # one-way main road
        m[0x75FD] ^= 1
    elif k == 5:
        m[iy + 10] = rng.choice((0x00, 0x80, 0xC0, 0xD0, 0x20, 0x90)) | (m[iy + 10] & 3)
        m[0x75FD] = rng.randrange(2)
    elif k == 6:
        m[0x75E7] = rng.randrange(256)                       # red lights
        m[0x75DF] = rng.randrange(1, 4)
    elif k == 7:                                             # odd grid code ahead
        if not (m[iy + 1] & 0x40):
            h, l = m[iy + 7], m[iy + 6]
            d = 1 if m[iy + 5] & 2 else -1
            a = (h << 8) | ((l + d * rng.randrange(1, 12)) & 0xFF)
            if 0x5B00 <= a < 0x6500 and m[a] == 0:
                # (lone $C0+/$FD/$FE codes would make SB98D read the Spectrum ROM)
                m[a] = rng.choice((0x85, 0x9A, 0xBF))
    elif k == 8:
        m[0x75FB] |= 0x80                                    # red stop lines
        m[0x75FC] |= 0x80
        m[iy + 11] = rng.randrange(0, 9)
    elif k == 9:
        m[iy + 0] = rng.randrange(8)                         # lane-change state
        m[iy + 1] ^= rng.choice((0x04, 0x08, 0x0C))
    elif k == 10:
        m[0x7600] = rng.randrange(12)
        m[iy + 11] = rng.randrange(12)
        m[iy + 2] |= rng.choice((0, 2, 6))
    elif k == 11:                                            # turn in progress
        # (only near the junction: elsewhere E833 would compute table
        # addresses that wrap into the Spectrum ROM)
        if not (m[iy + 1] & 0x40) and 0x64 <= m[iy + 6] < 0x64 + m[0x75F5]:
            m[iy + 10] |= 1 | rng.choice((0, 0x40))
            m[iy + 5] = rng.randrange(3) << 2 | (m[iy + 5] & 3)
            m[iy + 0] = rng.randrange(8)
    else:
        m[0x75F8] = rng.randrange(256)
        m[0x7604] = rng.randrange(256)
    return m


def forced(sim, st, seed, n_per_city):
    rng = random.Random(seed)
    for city in '1234':
        r = Ref()
        r.to_game(city=city, option='8')
        r.hold('S')
        kf = Ref.random_driver(seed * 7 + ord(city))
        base = []
        while len(base) < n_per_city:
            for s in r.capture(0xAB61, n=15, frames=60, keyfn=kf):
                if s.pre_mem[s.pre['iy'] + 1] & 0x80 and rng.random() < 0.3:
                    base.append(s)
            for f in range(5):
                kf(r, f)
                r.run(1)
        r.release()
        for s in base[:n_per_city]:
            iy = s.pre['iy']
            m = mutate(rng, s.pre_mem, iy)
            smp = run_real(r, m, s.pre, 0xAB61)
            if smp is None:
                st.skip += 1
                continue
            hard, d = run_one(sim, smp, 'Z_AB61')
            st.add(sim, smp, d, hard)


def direct(sim, st, seed, n):
    """External-only entries, compared register by register with the real
    routine: SB9D2 (DE), SB98D (HL, DE kept), SB49A (A, Z), SB0AA (H)."""
    rng = random.Random(seed)
    r = Ref()
    r.to_game(city='1', option='8')
    r.hold('S')
    kf = Ref.random_driver(seed)
    base = []
    while len(base) < 8:
        base += [s for s in r.capture(0xAB61, n=15, frames=60, keyfn=kf)
                 if s.pre_mem[s.pre['iy'] + 1] & 0x80]
        for f in range(20):
            kf(r, f)
            r.run(1)
    r.release()
    for i in range(n):
        s = base[i % len(base)]
        regs = dict(s.pre)
        which = (0xB9D2, 0xB98D, 0xB49A, 0xB0AA)[i % 4]
        a = rng.randrange(256)
        if which == 0xB49A:
            regs['hl'] = rng.randrange(0x5C00, 0x6400)
            regs['bc'] = rng.choice((0xFFFF, 0xFFF4, 0x0001, 0x000C))
        elif which == 0xB0AA:
            a = rng.choice((1, 2))
            regs['hl'] = (rng.randrange(0x5C, 0x64) << 8) | rng.randrange(256)
        regs['af'] = (a << 8) | (regs['af'] & 0xFF)
        smp = run_real(r, s.pre_mem, regs, which)
        if smp is None:
            st.skip += 1
            continue
        hard, d = run_one(sim, smp, 'Z_%04X' % which, a=a)
        g = sim.get_regs()
        if which == 0xB9D2:
            ok = g['de'] == smp.post['de']
        elif which == 0xB98D:
            ok = g['hl'] == smp.post['hl']
        elif which == 0xB49A:
            ok = g['a'] == smp.post['af'] >> 8 and g['zero'] == (smp.post['af'] >> 6) & 1
        else:
            ok = (g['hl'] >> 8) == (smp.post['hl'] >> 8)
        if not ok:
            d = d + [(which, 0, 0)]
        st.add(sim, smp, d, hard)


def main():
    passes = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    build()
    sim = Sim(BIN)
    covered = set()
    step0 = sim.mpu.step

    def step():
        covered.add(sim.mpu.pc)
        return step0()
    sim.mpu.step = step
    st_car = Stats('SAB61')
    st_all = Stats('SAB47')
    units = {a: Stats('S%04X' % a) for a in (0xB412, 0xB3B3, 0xB241, 0xB0AA, 0xB91B, 0xB9EE, 0xB83A,
                                         0xB905, 0xB913, 0xB9DD, 0xB1BC)}
    t0 = time.time()
    for city in '1234':
        r = Ref()
        r.to_game(city=city, option='8')
        r.hold('S')
        kf = Ref.random_driver(seed + ord(city))
        for p in range(passes):
            # one main-loop pass: the 15 car updates
            for s in r.capture(0xAB61, n=15, frames=60, keyfn=kf):
                hard, d = run_one(sim, s, 'Z_AB61')
                st_car.add(sim, s, d, hard)
            if p % 10 == 5:
                for s in r.capture(0xAB47, n=1, frames=60, keyfn=kf):
                    hard, d = run_one(sim, s, 'Z_AB47')
                    st_all.add(sim, s, d, hard)
            if p % 5 == 2:
                for a, stt in units.items():
                    for s in r.capture(a, n=2, frames=15, keyfn=kf):
                        if a == 0xB83A and exits_junction(s):
                            stt.skip += 1       # pops its return address: no
                            continue            # bracketed Z80 sample
                        hard, d = run_one(sim, s, 'Z_%04X' % a, a=s.pre['af'] >> 8)
                        stt.add(sim, s, d, hard)
            for f in range(7):
                kf(r, f)
                r.run(1)
        print('city %s done (frame %d, %.0fs)' % (city, r.frame, time.time() - t0))
    st_forced = Stats('forced')
    forced(sim, st_forced, seed, max(50, passes * 2))
    print('forced done (%.0fs)' % (time.time() - t0))
    st_direct = Stats('direct')
    direct(sim, st_direct, seed, 400)
    print()
    st_car.report()
    st_all.report()
    st_forced.report()
    st_direct.report()
    for stt in units.values():
        stt.report()
    # labels of the translation that no sample executed (rare paths)
    lo, hi = sim.sym['Z_AB47'], sim.sym['e8clr']
    never = sorted((a, n) for n, a in sim.sym.items()
                   if lo <= a <= hi and a not in covered and not n.startswith(('ZV', '@')))
    print('labels never executed:', ' '.join(n for a, n in never))
    bad = st_car.bad + st_all.bad + st_forced.bad + st_direct.bad + sum(u.bad for u in units.values())
    if os.environ.get('TRAFFIC_DUMP'):
        import pickle
        allst = [st_car, st_all, st_forced, st_direct] + list(units.values())
        with open(os.environ['TRAFFIC_DUMP'], 'wb') as f:
            pickle.dump([(st.name, s, d) for st in allst for s, d in st.first], f)
    print('\nRESULT:', 'PASS' if bad == 0 else 'FAIL (%d samples differ)' % bad)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
