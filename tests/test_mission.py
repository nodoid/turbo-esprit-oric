#!/usr/bin/env python3
"""Differential test of mission.s (enemy cars, DA80-E0A9) and mapview.s (map
screen, E0AA-E440) against the original game.

Samples are captured from PLAY games in all 4 cities with random driving
(plus map-mode runs with M held / scrolling).  Each sample's pre-state is
loaded into the 6502 simulator and the translated routine is run.  Calls to
routines of other modules (still stubs in this test build) are executed as
the ORIGINAL Z80 code on a Z80 emulator that shares the memory state (the
identity range and every ZV_ variable are synchronised before and after each
such call).  So the test checks exactly the code of these two modules.

Compared: $5B00-$7BBD (minus the stack area $7280-$72FF: the Z80 return
addresses / the route search's private stack) and every relocated variable,
including the map buffer $6400 and the colour buffer $7040 bit for bit.

usage: test_mission.py [frames_per_city]      (needs zx, z80, py65)
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

import z80                                    # noqa: E402
import zx._keyboard as _kbd                   # noqa: E402
from zxref import Ref, Sample, LD_A_R         # noqa: E402
from sim6502 import Sim, fmt_diffs, STOP      # noqa: E402

IGNORE = [(0x7280, 0x7300)]
FAKE = 'build/test_mission/fakevars.s'

# foreign relocated variables used by these modules (owner, size)
FAKEVARS = {0x9282: 0x153, 0x9560: 2, 0x8699: 1, 0x86D3: 6}
INLINE = {'Z_BA5F'}


def build():
    os.makedirs('build/test_mission', exist_ok=True)
    with open(FAKE, 'w') as f:
        f.write('; test only: foreign variables with their real sizes\n'
                '        .include "zx.inc"\n        .data\n')
        for a, n in FAKEVARS.items():
            f.write('        ZVAR $%04X, %d\n' % (a, n))
        f.write('        .exportzp frames\n        .zeropage\nframes: .res 1\n')
    r = subprocess.run([sys.executable, 'tools/buildtest.py', 'mission',
                        'src/mission.s', 'src/mapview.s', FAKE],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr)
        sys.exit(1)
    stubs = []
    for line in r.stdout.splitlines():
        if line.startswith('stubs:'):
            stubs = line.split()[1:]
    return stubs


# ---------------------------------------------------------------------------
def capture(ref, entries, n, frames, keyfn=None, skip=0):
    """Like Ref.capture, for several entry points, also recording the
    keyboard half-row state.  Returns {entry: [samples]}."""
    z = ref.z
    out = {e: [] for e in entries}
    seen = {e: 0 for e in entries}
    st = {'cur': None}
    rpost = set(a + 2 for a in LD_A_R)

    def bp():
        pc = z.pc
        c = st['cur']
        if c is not None:
            s, e, sp, ret = c
            if pc == ret and z.sp == sp + 2:
                s.post = ref.regs()
                s.post_mem = ref.mem()
                out[e].append(s)
                st['cur'] = None
                return
            if pc in rpost:
                s.rvals.append(z.af >> 8)
            return
        if pc in out and len(out[pc]) < n:
            seen[pc] += 1
            if seen[pc] <= skip:
                return
            s = Sample(ref.regs(), ref.mem())
            s.kbd = list(_kbd.Keyboard._state)
            ret = int.from_bytes(z.read(z.sp, 2), 'little')
            st['cur'] = (s, pc, z.sp, ret)
            z.set_breakpoint(ret)
    z.on_breakpoint = bp
    for e in entries:
        z.set_breakpoint(e)
    for a in rpost:
        z.set_breakpoint(a)
    for f in range(frames):
        if keyfn:
            keyfn(ref, f)
        ref.run(1)
        if all(len(v) >= n for v in out.values()):
            break
    z.on_breakpoint = lambda: None
    return out


# ---------------------------------------------------------------------------
class ZSim(Sim):
    """Sim whose stubbed (foreign) routines run as the original Z80 code."""

    def __init__(self, binpath, stubs):
        super().__init__(binpath)
        self.stubs = {self.sym[s]: s for s in stubs if s.startswith('Z_') and s in self.sym}
        self.z = z80.Z80Machine()
        self.foreign = {}
        # $7300-$73D9 / $7404-$74D2 (the Spectrum main-loop code) hold Oric
        # tables (segments RODATAH1/H2): not part of the shared Spectrum state
        self.holes = []
        for h, a, n in (('HOLE1', 0x7300, 0xDA), ('HOLE2', 0x7404, 0xCF)):
            a = self.sym.get('__%s_START__' % h, a)
            n = self.sym.get('__%s_SIZE__' % h, n)
            self.holes.append((a, a + n))
        self.hole_data = [bytes(self.mem[a:b]) for a, b in self.holes]
        self.frames = self.sym.get('frames')

    def start(self, sample):
        self.world = bytearray(sample.pre_mem)
        self.kbd = getattr(sample, 'kbd', [0xFF] * 8)
        self.zsp = (sample.pre['sp'] - 0x20) & 0xFFFF
        self.foreign = {}
        self.load_state(sample.pre_mem, sample.pre)
        for (a, b), d in zip(self.holes, self.hole_data):
            self.mem[a:b] = d

    def _inport(self, port):
        if port & 1:
            return 0x00 if (port & 0xFF) == 0x1F else 0xFF
        v = 0xFF
        for i in range(8):
            if not (port >> (8 + i)) & 1:
                v &= self.kbd[i]
        return v

    def zcall(self, name):
        addr = int(name[2:], 16)
        m, s, mem, mpu = self.z, self.sym, self.mem, self.mpu
        self.foreign[name] = self.foreign.get(name, 0) + 1
        w = self.world
        keep = [bytes(w[a:b]) for a, b in self.holes]
        w[0x5B00:0x7BBE] = mem[0x5B00:0x7BBE]
        for (a, b), d in zip(self.holes, keep):
            w[a:b] = d
        for zxa, (oa, n) in self.zvars.items():
            w[zxa:zxa + n] = mem[oa:oa + n]
        ret6502 = (mem[0x100 + ((mpu.sp + 1) & 0xFF)] | mem[0x100 + ((mpu.sp + 2) & 0xFF)] << 8) + 1
        retz = 0x3000
        inline = name in INLINE
        if inline:
            w[retz:retz + 64] = mem[ret6502:ret6502 + 64]
        m.set_memory_block(0, bytes(w))

        def g(r):
            return mem[s[r]]
        main = {'bc': g('zc') | g('zb') << 8, 'de': g('ze') | g('zd') << 8, 'hl': g('zl') | g('zh') << 8}
        alt = {'bc': g('zc2') | g('zb2') << 8, 'de': g('ze2') | g('zd2') << 8, 'hl': g('zl2') | g('zh2') << 8}
        # Z_B412: the original is called after "exx" and starts with exx, so
        # the 6502 version takes and returns HL/BC in the alternate set
        # (zl2/zh2...); the Z80 returns with the banks swapped.
        swap = name == 'Z_B412'
        f = (mpu.p & 1) | (0x40 if mpu.p & 2 else 0)
        m.af = mpu.a << 8 | f
        m.bc, m.de, m.hl = main['bc'], main['de'], main['hl']
        m.alt_bc, m.alt_de, m.alt_hl = alt['bc'], alt['de'], alt['hl']
        m.alt_af = g('za2') << 8
        m.ix = g('zixl') | g('zixh') << 8
        m.iy = g('ziyl') | g('ziyh') << 8
        sp = self.zsp
        m.set_memory_block(sp, bytes([retz & 0xFF, retz >> 8]))
        m.sp = sp
        m.pc = addr
        m.iff1 = m.iff2 = 0
        m.set_input_callback(self._inport)
        rng = range(retz, retz + 64) if inline else [retz]
        for a in rng:
            m.set_breakpoint(a)
        for _ in range(500):
            m.ticks_to_stop = 10 ** 7
            m.run()
            if retz <= m.pc < retz + 64 and m.sp == (sp + 2) & 0xFFFF:
                break
        else:
            raise RuntimeError('%s did not return (pc=%04X)' % (name, m.pc))
        for a in rng:
            m.clear_breakpoint(a)
        skip = m.pc - retz
        w[:] = bytes(m.memory)
        keep = [bytes(mem[a:b]) for a, b in self.holes]
        mem[0x5B00:0x7BBE] = w[0x5B00:0x7BBE]
        for (a, b), d in zip(self.holes, keep):
            mem[a:b] = d
        for zxa, (oa, n) in self.zvars.items():
            mem[oa:oa + n] = w[zxa:zxa + n]
        main = {'bc': m.bc, 'de': m.de, 'hl': m.hl}
        alt = {'bc': m.alt_bc, 'de': m.alt_de, 'hl': m.alt_hl}
        if swap:
            main, alt = alt, main
        for (lo, hi), v in (((('zc', 'zb')), main['bc']), (('ze', 'zd'), main['de']),
                            (('zl', 'zh'), main['hl']), (('zc2', 'zb2'), alt['bc']),
                            (('ze2', 'zd2'), alt['de']), (('zl2', 'zh2'), alt['hl']),
                            (('zixl', 'zixh'), m.ix), (('ziyl', 'ziyh'), m.iy)):
            mem[s[lo]] = v & 0xFF
            mem[s[hi]] = v >> 8
        mem[s['za2']] = m.alt_af >> 8
        mpu.a = m.af >> 8
        zf = m.af & 0xFF
        mpu.p = (mpu.p & ~0x83) | (zf & 1) | (2 if zf & 0x40 else 0) | (zf & 0x80)
        mpu.sp = (mpu.sp + 2) & 0xFF
        mpu.pc = ret6502 + skip

    def call(self, target, a=None, max_steps=5_000_000):
        mpu = self.mpu
        mpu.sp = 0x7F
        mpu.stPushWord(STOP - 1)
        mpu.pc = self.addr(target)
        mpu.a = self.a if a is None else a
        mpu.p = 0x20 | (getattr(self, 'carry', 0) & 1) | (2 if getattr(self, 'zero', 0) else 0)
        start = mpu.processorCycles
        steps = 0
        while mpu.pc != STOP:
            if mpu.pc in self.stubs:
                self.zcall(self.stubs[mpu.pc])
                continue
            mpu.step()
            steps += 1
            if self.frames is not None and steps % 4000 == 0:
                mem = self.mem               # the 50Hz interrupt (delay2)
                mem[self.frames] = (mem[self.frames] + 1) & 0xFF
            if steps > max_steps:
                raise RuntimeError('did not return (pc=%04X)' % mpu.pc)
        self.cycles = mpu.processorCycles - start
        return self.cycles


# ---------------------------------------------------------------------------
TESTS = [
    # entry, label, setup of registers handled by load_state
    (0xDDF4, 'Z_DDF4'), (0xDCE8, 'Z_DCE8'), (0xDA97, 'Z_DA97'), (0xDBFA, 'Z_DBFA'),
    (0xDE15, 'Z_DE15'), (0xE01D, 'Z_E01D'), (0xE0FF, 'Z_E0FF'), (0xE0AA, 'Z_E0AA'),
    (0xDC5F, 'Z_DC5F'), (0xE0F2, 'Z_E0F2'), (0xE0C0, 'Z_E0C0'), (0xDA80, 'Z_DA80'),
]


def collect(city, frames):
    got = {}

    def add(d):
        for k, v in d.items():
            got.setdefault(k, []).extend(v)
    r = Ref()
    r.to_menu(city)
    r.key('8', True)
    add(capture(r, [0xE01D, 0xE0F2], n=2, frames=400))
    r.key('8', False)
    r.run(100)
    r.hold('S')
    drv = Ref.random_driver(int(city) * 7)
    # long play: sample every routine, the per-pass update spread out
    for chunk in range(frames // 500):
        add(capture(r, [0xDDF4], n=6, frames=500, keyfn=drv, skip=40 * (chunk % 3)))
        add(capture(r, [0xDCE8, 0xDA97, 0xDBFA, 0xDE15], n=3, frames=1, keyfn=drv))
    add(capture(r, [0xDCE8, 0xDA97, 0xDBFA, 0xDE15], n=8, frames=frames, keyfn=drv))
    # map mode: press M, drive and scroll
    r.release()
    r.hold('S')
    add(capture(r, [0xE0AA], n=2, frames=20))
    add(capture(r, [0xE0C0], n=1, frames=200, keyfn=lambda ref, f: ref.key('M', 5 <= f < 25)))
    r.key('M', False)
    r.release()
    rng = Ref.random_driver(int(city) + 100, period=6)

    def mapkeys(ref, f):
        rng(ref, f)
        ref.key('M', False)
    add(capture(r, [0xE0FF, 0xDC5F, 0xDA80, 0xDDF4], n=10, frames=1500, keyfn=mapkeys, skip=1))
    return got


# ---------------------------------------------------------------------------
# Synthetic states: real samples with mutated car records etc.  The reference
# is the ORIGINAL routine run on the Z80 from the same state.
def zref(mem, regs, entry, kbd=None):
    m = z80.Z80Machine()
    m.set_memory_block(0, bytes(mem))
    for r in ('af', 'bc', 'de', 'hl', 'ix', 'iy', 'alt_af', 'alt_bc', 'alt_de', 'alt_hl'):
        setattr(m, r, regs[r])
    sp = (regs['sp'] - 2) & 0xFFFF
    m.set_memory_block(sp, bytes([0x00, 0x30]))
    m.sp = sp
    m.pc = entry
    m.iff1 = m.iff2 = 0
    kb = kbd or [0xFF] * 8

    def inp(port):
        if port & 1:
            return 0x00 if (port & 0xFF) == 0x1F else 0xFF
        v = 0xFF
        for i in range(8):
            if not (port >> (8 + i)) & 1:
                v &= kb[i]
        return v
    m.set_input_callback(inp)
    m.set_breakpoint(0x3000)
    for _ in range(2000):
        m.ticks_to_stop = 10 ** 7
        m.run()
        if m.pc == 0x3000 and m.sp == (sp + 2) & 0xFFFF:
            break
    else:
        raise RuntimeError('reference did not return')
    return bytes(m.memory)


def mutate_cars(rng, mem, near_player=False):
    px, py = mem[0x7504], mem[0x7505]
    mx, my = mem[0xE088], mem[0xE089]
    for k, base in enumerate((0x785E, 0x7868, 0x7872)):
        d = rng.randrange(4)
        if rng.random() < 0.15:
            mem[base] = 0x80
        else:
            mem[base] = d | (8 if rng.random() < 0.3 else 0)
        choice = rng.random()
        if choice < 0.3:
            tx, ty = mx, my                       # arriving at the meeting point
        elif choice < 0.45:
            tx, ty = mem[base + 8], mem[base + 9]  # at the hiding/escape place
        elif choice < 0.55:
            tx, ty = rng.choice([(0x20, 5), (3, 0xFF), (0xFF, 7)])  # left the map
        elif near_player or choice < 0.7:
            tx, ty = px, py
        else:
            tx, ty = rng.randrange(32), rng.randrange(32)
        fx, fy = tx, ty
        if d == 0: fy -= 1
        elif d == 1: fx -= 1
        elif d == 2: fy += 1
        else: fx += 1
        if near_player and rng.random() < 0.5:
            fx, fy = px, py
        mem[base + 1], mem[base + 2] = fx & 0xFF, fy & 0xFF
        mem[base + 3], mem[base + 4] = tx & 0xFF, ty & 0xFF
        mem[base + 5] = rng.choice([0x5E, 0x5D, 0x30, 0x10, 0x64, 5])
        f6 = rng.choice([0, 2, 4, 6]) if k == 0 else rng.choice([1, 3, 5, 0x0D, 0x09])
        if k == 2:
            f6 |= 0x80
        mem[base + 6] = f6
    mem[0xDDD1] = rng.choice([1, 1, 2, 0x20])
    mem[0xDDD2] = rng.choice([1, 2, 4])
    mem[0x75F8] = rng.randrange(256)


def fuzz(sim, pools, rng, rounds):
    res = {}

    def run(label, entry, s, mem):
        pre = bytes(mem)
        post = zref(pre, s.pre, entry, getattr(s, 'kbd', None))
        fake = Sample(s.pre, pre)
        fake.kbd = getattr(s, 'kbd', None)
        sim.start(fake)
        sim.call(label)
        d = sim.compare(post, ignore=IGNORE + sim.holes)
        if sim.foreign.get('Z_F422', 0) > 1:
            # the never-executed collision path with a junk grid pointer
            # (above $C000, not shared between the 6502 and the Z80 world)
            label += '(collision)'
        st = res.setdefault(label, [0, 0])
        st[0] += 1
        if d:
            st[1] += 1
            print('fuzz %s DIFF %s' % (label, fmt_diffs(d)))
    for i in range(rounds):
        s = rng.choice(pools[0xDDF4])
        mem = bytearray(s.pre_mem)
        mutate_cars(rng, mem)
        run('Z_DDF4', 0xDDF4, s, mem)
        mem = bytearray(s.pre_mem)
        mutate_cars(rng, mem, near_player=True)
        run('Z_DE15', 0xDE15, s, mem)
        if pools.get(0xDCE8):
            s = rng.choice(pools[0xDCE8])
            mem = bytearray(s.pre_mem)
            mem[0xDCE7] = rng.choice([2, 3, 5])
            mem[0xDD6D], mem[0xDD6E] = rng.randrange(32), rng.randrange(32)
            regs = dict(s.pre)
            regs['hl'] = rng.randrange(32) | rng.randrange(32) << 8
            if rng.random() < 0.5:                # player junction on the way
                mem[0x7504] = ((regs['hl'] & 0xFF) + rng.choice([-1, 1, 0])) & 0xFF
                mem[0x7505] = ((regs['hl'] >> 8) + rng.choice([-2, -1, 1, 0])) & 0xFF
            regs['bc'] = (regs['bc'] & 0xFF00) | rng.randrange(4)
            s2 = Sample(regs, bytes(mem))
            run('Z_DCE8', 0xDCE8, s2, mem)
        if pools.get(0xDBFA):
            s = rng.choice(pools[0xDBFA])
            mem = bytearray(s.pre_mem)
            mutate_cars(rng, mem)
            o = s.pre['iy']
            mem[o + 1] = rng.randrange(256)
            mem[o + 2] = rng.choice([0x06, 0x0E, 0x16, 0x1E, 0x02, 0x04])
            mem[o + 5] = rng.randrange(4)
            mem[o + 8] = rng.randrange(16)
            run('Z_DBFA', 0xDBFA, s, mem)
            mem = bytearray(s.pre_mem)
            mutate_cars(rng, mem)
            run('Z_DDD3', 0xDDD3, s, mem)
            regs = dict(s.pre)
            regs['ix'] = 0x71DE
            for k in range(12):
                mem[o + k] = rng.randrange(256)
            s2 = Sample(regs, bytes(mem))
            run('Z_DC5F', 0xDC5F, s2, mem)
        if pools.get(0xE01D) and i % 4 == 0:
            s = rng.choice(pools[0xE01D])
            mem = bytearray(s.pre_mem)
            mem[0x9560], mem[0x9561] = rng.randrange(256), rng.randrange(256)
            mem[0x7611] = rng.choice([0, 0xFF])
            run('Z_E01D', 0xE01D, s, mem)
        if pools.get(0xE0FF) and i % 2 == 0:
            s = rng.choice(pools[0xE0FF])
            mem = bytearray(s.pre_mem)
            mem[0x71D0] = rng.randrange(-2, 22) & 0xFF
            mem[0x71D1] = rng.randrange(-2, 29) & 0xFF
            mem[0x75F8] = rng.randrange(256)
            mutate_cars(rng, mem, near_player=True)
            for b in (0x785E, 0x7868, 0x7872):
                if rng.random() < 0.5:
                    mem[b] &= 0x8B                 # not a 3D object
            kb = [rng.choice([0xFF, 0xFF, 0xFE, 0xFD, 0xFC, 0xF7, 0xF5]) for _ in range(8)]
            s2 = Sample(s.pre, bytes(mem))
            s2.kbd = kb
            run('Z_E0FF', 0xE0FF, s2, mem)
    return res


def main():
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    stubs = build()
    sim = ZSim('build/test_mission.bin', stubs)
    total = bad = 0
    stats = {}
    allpools = {}
    for city in '1234':
        got = collect(city, frames)
        for e, v in got.items():
            allpools.setdefault(e, []).extend(v)
        for entry, label in TESTS:
            for k, s in enumerate(got.get(entry, [])):
                sim.start(s)
                try:
                    cyc = sim.call(label)
                    d = sim.compare(s.post_mem, ignore=IGNORE + sim.holes)
                except Exception as e:      # noqa: BLE001
                    d = [('EXC', str(e))]
                    cyc = 0
                total += 1
                st = stats.setdefault(label, [0, 0, 0, 0])
                st[0] += 1
                st[2] = max(st[2], cyc)
                st[3] += cyc
                if d:
                    bad += 1
                    st[1] += 1
                    msg = fmt_diffs(d) if d[0][0] != 'EXC' else d[0][1]
                    print('city %s %s #%d DIFF %s  (foreign: %s)' % (city, label, k, msg, sim.foreign))
        print('city', city, 'done:', {hex(e): len(v) for e, v in got.items()})
    print()
    print('%-8s %7s %6s %10s %10s' % ('routine', 'samples', 'diffs', 'max cyc', 'avg cyc'))
    for label, (n, b, mx, sm) in sorted(stats.items()):
        print('%-8s %7d %6d %10d %10d' % (label, n, b, mx, sm // max(n, 1)))
    import random
    rng = random.Random(5)
    for k, (n, b) in sorted(fuzz(sim, allpools, rng, 120).items()):
        print('fuzz %-8s %5d samples %3d diffs' % (k, n, b))
        total += n
        bad += b
    print('(cycles exclude the foreign routines, which run as Z80 code)')
    print('%d samples, %d with differences' % (total, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
