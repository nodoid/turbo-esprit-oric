#!/usr/bin/env python3
"""Tests for src/render.s (3D road renderer, Spectrum $7BBE-$862D).

  * Z_7BBE (whole frame: render_view incl. block changes) against the real
    game: samples captured with tools/zxref.py from random driving in all
    four cities.  The calls to the world builders 958B/9907/9AA8 (other
    module, stubbed here) are replaced by the Spectrum's own result: when
    the 6502 reaches the stub of 958B, the memory the three routines changed
    on the Spectrum (snapshot at 7CB0) is copied in.
  * Z_7CA1 against one real call (turning into a side road, city 3).
  * Z_7D2D (map step) for all headings / carries.
  * Optional (set R2REF=<directory of r2ref.py>, the verified Python model
    of the notes; skipped otherwise): Z_7C82 (never reached in play) and
    Z_7C8D on synthetic states, and fuzzed road states (random road types,
    segment lists, flags, speeds incl. reverse) through Z_7BF8.
  Ignored in comparisons: D74F9 (81D7's SP save) and the Spectrum stack.
  Samples are cached in build/render_samples.pkl, build/render_7ca1.pkl.

usage: test_render.py [samples_per_city] [--fresh] [--quiet] [--fuzz=N] [--seed=S]
Prints differences and cycle counts (6502 cycles vs Spectrum T-states).
"""
import os
import pickle
import random
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

from sim6502 import Sim, STOP, fmt_diffs  # noqa: E402

FRAME_T = 69888
CACHE = os.path.join(ROOT, 'build', 'render_samples.pkl')
IGNORE = [0x74F9, 0x74FA]           # SP save of 81D7 (scratch)


def build():
    import subprocess
    r = subprocess.run([sys.executable, 'tools/buildtest.py', 'render', 'src/render.s'],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        sys.exit(1)
    return Sim('build/test_render.bin')


# ---------------------------------------------------------------- capture
from types import SimpleNamespace as Smp  # noqa: E402  (picklable)


def capture_city(city, n, seed, frames=6000):
    from zxref import Ref
    ref = Ref()
    ref.to_game(city=city)
    ref.hold('S')
    z = ref.z
    out = []
    st = {'cur': None}
    keyfn = Ref.random_driver(seed, period=12)
    rng = random.Random(seed)
    skip = {'n': rng.randint(0, 3)}

    def now():
        return z.frame_count * FRAME_T + z.ticks_since_int

    def bp():
        pc = z.pc
        cur = st['cur']
        if cur is not None:
            if pc == 0x7CB0:
                cur.mid = ref.mem()
            elif pc == cur.ret and z.sp == cur.sp + 2:
                cur.t = now() - cur.t0
                cur.post_mem = ref.mem()
                out.append(cur)
                st['cur'] = None
            return
        if pc == 0x7BBE and len(out) < n:
            if skip['n']:
                skip['n'] -= 1
                return
            skip['n'] = rng.randint(0, 4)
            s = Smp()
            s.city = city
            s.pre = ref.regs()
            s.pre_mem = ref.mem()
            s.mid = None
            s.sp = z.sp
            s.ret = int.from_bytes(z.read(z.sp, 2), 'little')
            s.t0 = now()
            z.set_breakpoint(s.ret)
            st['cur'] = s
    z.on_breakpoint = bp
    z.set_breakpoint(0x7BBE)
    z.set_breakpoint(0x7CB0)
    for f in range(frames):
        keyfn(ref, f)
        ref.run(1)
        if len(out) >= n:
            break
    z.on_breakpoint = lambda: None
    return out


def capture_7ca1(city='3', seed=13, frames=12000):
    """First real call of 7CA1 (turning into a side road), with the 7CB0 snapshot."""
    from zxref import Ref
    ref = Ref()
    z = ref.z
    st = {'cur': None, 'done': None}

    def bp():
        pc = z.pc
        cur = st['cur']
        if st['done']:
            return
        if cur is not None:
            if pc == 0x7CB0:
                cur.mid = ref.mem()
            elif pc == cur.ret and z.sp == cur.sp + 2:
                cur.post_mem = ref.mem()
                st['done'] = cur
            return
        if pc == 0x7CA1:
            s = Smp()
            s.pre = ref.regs()
            s.pre_mem = ref.mem()
            s.mid = None
            s.sp = z.sp
            s.ret = int.from_bytes(z.read(z.sp, 2), 'little')
            z.set_breakpoint(s.ret)
            z.set_breakpoint(0x7CB0)
            st['cur'] = s
    ref.to_game(city=city)
    ref.hold('S')
    z.on_breakpoint = bp
    z.set_breakpoint(0x7CA1)
    fn = Ref.random_driver(seed, period=6)
    for f in range(frames):
        fn(ref, f)
        ref.run(1)
        if st['done']:
            break
    z.on_breakpoint = lambda: None
    return st['done']


def get_samples(n, fresh=False):
    if not fresh and os.path.exists(CACHE):
        d = pickle.load(open(CACHE, 'rb'))
        if d['n'] >= n:
            return [s for s in d['samples'] if s.idx < n]
    samples = []
    for city in '1234':
        got = capture_city(city, n, seed=int(city) * 7)
        for i, s in enumerate(got):
            s.idx = i
        samples += got
    pickle.dump({'n': n, 'samples': samples}, open(CACHE, 'wb'))
    return samples


def get_7ca1(fresh=False):
    path = os.path.join(ROOT, 'build', 'render_7ca1.pkl')
    if not fresh and os.path.exists(path):
        return pickle.load(open(path, 'rb'))
    s = capture_7ca1()
    pickle.dump(s, open(path, 'wb'))
    return s


# ---------------------------------------------------------------- running
def run(sim, target, hooks=None, a=0, carry=0, max_cycles=5_000_000):
    mpu = sim.mpu
    mpu.sp = 0xFF
    mpu.stPushWord(STOP - 1)
    mpu.pc = sim.addr(target)
    mpu.a = a
    mpu.p = 0x20 | carry
    hooks = hooks or {}
    start = mpu.processorCycles
    while mpu.pc != STOP:
        h = hooks.get(mpu.pc)
        if h:
            h()
        mpu.step()
        if mpu.processorCycles - start > max_cycles:
            raise RuntimeError('no return (pc=%04X)' % mpu.pc)
    return mpu.processorCycles - start


def test_frames(sim, samples, quiet=False):
    stub = sim.sym['Z_958B']
    bad = 0
    stats = []
    for s in samples:
        sim.load_state(s.pre_mem, s.pre)
        lo = s.sp - 64
        ign = set(IGNORE) | set(range(lo, s.sp + 2))

        def world():
            if s.mid is None:
                raise RuntimeError('block change on the 6502 only')
            for a in range(0x5B00, 0x7BBE):
                if s.mid[a] != s.pre_mem[a] and a not in ign and \
                        not (0x7504 <= a < 0x7508) and a != 0x75FE:
                    sim.mem[a] = s.mid[a]
        cyc = run(sim, 'Z_7BBE', {stub: world})
        d = sim.compare(s.post_mem, ignore=list(ign))
        blk = s.mid is not None
        if not (s.pre_mem[0x7610] & 1) and not blk:
            stats.append((cyc, s.t, blk, s.city))
        if d:
            bad += 1
            if not quiet or bad <= 5:
                print('  city %s #%d%s: %d diffs %s' % (s.city, s.idx, ' (block change)' if blk else '',
                                                       len(d), fmt_diffs(d, 12)))
    nblk = sum(1 for s in samples if s.mid is not None)
    print('Z_7BBE: %d frames (%d with block change): %d bad' % (len(samples), nblk, bad))
    if stats:
        cy = sorted(c for c, t, b, ci in stats)
        tt = sorted(t for c, t, b, ci in stats)
        avg = sum(cy) / len(cy)
        tavg = sum(tt) / len(tt)
        print('  frames without block change (Spectrum time includes interrupts):')
        print('  6502 cycles/frame: avg %d  min %d  max %d' % (avg, cy[0], cy[-1]))
        print('  Spectrum T-states: avg %d  min %d  max %d  (avg T/3.5 = %d)' %
              (tavg, tt[0], tt[-1], tavg / 3.5))
        for city in '1234':
            c = [x[0] for x in stats if x[3] == city]
            t = [x[1] for x in stats if x[3] == city]
            if c:
                print('    city %s: %d frames, 6502 avg %d cycles, Spectrum avg %d T' %
                      (city, len(c), sum(c) / len(c), sum(t) / len(t)))
    return bad


def test_7ca1(sim, s):
    """Z_7CA1 against the real game (world builders replaced by their result)."""
    if s is None:
        print('Z_7CA1: no real call captured')
        return 1
    stub = sim.sym['Z_958B']
    sim.load_state(s.pre_mem, s.pre)
    ign = set(IGNORE) | set(range(s.sp - 64, s.sp + 2))

    def world():
        for a in range(0x5B00, 0x7BBE):
            if s.mid[a] != s.pre_mem[a] and a not in ign and not (0x7506 <= a < 0x7508):
                sim.mem[a] = s.mid[a]
        if (sim.mem[sim.sym['zl']] | sim.mem[sim.sym['zh']] << 8) != (s.pre_mem[0x7504] | s.pre_mem[0x7505] << 8):
            raise RuntimeError('7CA1: HL passed to 958B is not D7504')
    run(sim, 'Z_7CA1', {stub: world})
    d = sim.compare(s.post_mem, ignore=list(ign))
    print('Z_7CA1: 1 real call (turn into a side road): %s' % (fmt_diffs(d) if d else 'OK'))
    return 1 if d else 0


def test_7c82(sim, samples):
    """Z_7C82 (backwards block change, never reached in play) and Z_7C8D on
    synthetic states against the notes' formulas (world builders stubbed)."""
    path = os.environ.get('R2REF', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    if not path or not os.path.exists(os.path.join(path, 'r2ref.py')):
        print('Z_7C82: skipped (set R2REF)')
        return 0
    sys.path.insert(0, path)
    from r2ref import block_setup_tail
    rng = random.Random(5)
    bad = 0
    for it in range(40):
        s = rng.choice(samples)
        m = bytearray(s.pre_mem)
        for a in (0x75F0, 0x7504, 0x7505, 0x7793, 0x7798, 0x779B, 0x75F6, 0x75F5):
            m[a] = rng.randint(0, 255)
        m[0x75F0] &= 3
        entry = rng.choice(['Z_7C82', 'Z_7C8D'])
        ref = bytearray(m)
        h, l = ref[0x7505], ref[0x7504]
        ref[0x7506], ref[0x7507] = l, h
        heading = ref[0x75F0] ^ (2 if entry == 'Z_7C82' else 0)
        ref[0x75FE] = 3 if entry == 'Z_7C82' else 2
        if heading & 1:
            l = (l - 1) & 0xFF if heading & 2 else (l + 1) & 0xFF
        else:
            h = (h - 1) & 0xFF if heading & 2 else (h + 1) & 0xFF
        ref[0x7504], ref[0x7505] = l, h
        block_setup_tail(ref)
        sim.load_state(bytes(m), s.pre)
        run(sim, entry)
        d = sim.compare(bytes(ref), ignore=IGNORE)
        if d:
            bad += 1
            if bad <= 3:
                print('  %s: %s' % (entry, fmt_diffs(d)))
    print('Z_7C82/Z_7C8D synthetic: 40 states, %d bad' % bad)
    return bad


def test_7d2d(sim):
    bad = 0
    for heading in range(4):
        for carry in (0, 1):
            for hl in (0x1234, 0x00FF, 0xFF00):
                sim.mem[sim.sym['zl']] = hl & 0xFF
                sim.mem[sim.sym['zh']] = hl >> 8
                run(sim, 'Z_7D2D', a=heading, carry=carry)
                a = heading
                c = carry
                h, l = hl >> 8, hl & 0xFF
                # Z80: rra; jr c; rra; jr c ...
                c, a = a & 1, (a >> 1) | (c << 7)
                if not c:
                    c, a = a & 1, (a >> 1) | (c << 7)
                    h = (h - 1) & 0xFF if c else (h + 1) & 0xFF
                else:
                    c, a = a & 1, (a >> 1) | (c << 7)
                    l = (l - 1) & 0xFF if c else (l + 1) & 0xFF
                got = (sim.mem[sim.sym['zh']], sim.mem[sim.sym['zl']], sim.mpu.a, sim.mpu.p & 1)
                if got != (h, l, a, c):
                    bad += 1
                    print('  7D2D heading %d carry %d hl %04X: got %s want %s' %
                          (heading, carry, hl, got, (h, l, a, c)))
    print('Z_7D2D: 24 cases, %d bad' % bad)
    return bad


# ------------------------------------------------- fuzz against the model
CFGS = {0: bytes.fromhex('5c6392760000ac7681030300'), 1: bytes.fromhex('5d629a767476cc7642020004'),
        2: bytes.fromhex('5e61a2761476ec762401000c')}


def gen_fuzz(rng, base):
    """A random road state (as the fuzzer of the notes): returns (sample, mem, cfg, mode)."""
    cfgs = CFGS
    s = rng.choice(base)
    m = bytearray(s.pre_mem)
    cfg = rng.choice([0, 1, 2])
    m[0x75D6:0x75E2] = cfgs[cfg]
    nseg = rng.randint(6, 17)
    lens = [rng.choice([12, 12, 12, 16, 20, rng.randint(3, 30)]) for _ in range(nseg)]
    mode = rng.choice(['normal', 'normal', 'special', 'special2'])

    def typ():
        t = rng.choice([0, 1, 2, 3, 4, 1, 2, 3, 4])
        r = rng.random()
        if mode == 'special':
            if r < 0.1:
                t |= 0x20
            elif r < 0.13:
                t |= 0x80
        if mode == 'special2':
            if r < 0.15:
                t |= 0x20
            elif r < 0.45:
                t |= 0x80
        return t
    ptrs = {}
    for base_, ptr in ((0x787C, 0x7D15), (0x789F, 0x7D18)):
        p = base_
        for ln in lens:
            m[p] = typ()
            m[p + 1] = ln
            p += 2
        m[p:p + 4] = bytes([0x42, 2, 0x42, 2])
        k = rng.randint(0, 2)
        ptrs[ptr] = (base_ + 2 * k, rng.randint(0, lens[k] - 1))
    for ptr, (pv, ov) in ptrs.items():
        m[ptr] = pv & 0xFF
        m[ptr + 1] = pv >> 8
        m[ptr + 2] = ov
    m[0x75EC] = rng.randint(0, 255)
    m[0x75E7] = rng.randint(0, 255)
    m[0x75FD] = rng.choice([0, 0, 0, 0x80])
    m[0x74FF] = rng.randint(0, 7)
    m[0x81D5] = rng.choice([0x55, 0xAA])
    sp_ = rng.choice([0, 1, 2, 3, 4] + ([0xFF, 0xFE, 0xFD] if mode == 'special2' else []))
    m[0x75F6] = sp_
    m[0x75F7] = 0xFF if sp_ >= 0x80 else 0
    for a in range(0x5E00, 0x7020):
        m[a] = 0xFF if (a & 31) in (0, 1, 30, 31) and a >= 0x6420 else 0
    return s, m, cfg, mode


def test_fuzz(sim, samples, n=300, seed=1):
    path = os.environ.get('R2REF', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
    if not path or not os.path.exists(os.path.join(path, 'r2ref.py')):
        print('fuzz: skipped (set R2REF=<dir of r2ref.py>)')
        return 0
    sys.path.insert(0, path)
    from r2ref import Renderer
    rng = random.Random(seed)
    base = [s for s in samples if s.mid is None and not (s.pre_mem[0x7610] & 1)]
    bad = 0
    cyc = []
    for it in range(n):
        s, m, cfg, mode = gen_fuzz(rng, base)
        ref = bytearray(m)
        R = Renderer(ref)
        R.render_from_7BF8()
        sim.load_state(bytes(m), s.pre)
        cyc.append(run(sim, 'Z_7BF8'))
        d = sim.compare(bytes(ref), ignore=IGNORE)
        if d:
            bad += 1
            if bad <= 5:
                print('  fuzz %d (cfg%d %s): %d diffs %s' % (it, cfg, mode, len(d), fmt_diffs(d, 12)))
    print('fuzz vs r2ref: %d states, %d bad (avg %d cycles)' % (n, bad, sum(cyc) / len(cyc)))
    return bad


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    n = int(args[0]) if args else 40
    sim = build()
    samples = get_samples(n, '--fresh' in sys.argv)
    bad = test_7d2d(sim)
    bad += test_frames(sim, samples, '--quiet' in sys.argv)
    bad += test_7ca1(sim, get_7ca1('--fresh' in sys.argv))
    bad += test_7c82(sim, samples)
    nf = [a for a in sys.argv[1:] if a.startswith('--fuzz=')]
    fs = [a for a in sys.argv[1:] if a.startswith('--seed=')]
    bad += test_fuzz(sim, samples, n=int(nf[0][7:]) if nf else 300, seed=int(fs[0][7:]) if fs else 1)
    print('render: %s' % ('OK' if not bad else 'FAILED'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
