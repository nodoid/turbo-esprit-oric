#!/usr/bin/env python3
"""Differential test of src/player.s against the real Spectrum game.

Samples of SEAE2 (PLAYER_STEP), SE96A (gearbox) and SF6E3 (BANG check) are
captured during random driving in all 4 cities (tools/zxref.py).  Calls the
original routine makes to code owned by other modules ("externals": S98F4,
SB412, SA4C9, ...) are recorded with their effect (memory diff + registers);
when the 6502 translation calls the corresponding stub, the test checks that
the 6502 state equals the Spectrum state at that point (memory + input
registers), applies the recorded effect and returns.  Beeper calls are
recorded as sound events and must match the 6502's snd_fx calls.

    python tests/test_player.py [samples_per_run] [frames_per_run]

Captures are cached in build/player_samples_*.pkl (delete to recapture).
"""
import os
import pickle
import random
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

import subprocess  # noqa: E402
from sim6502 import Sim, STOP  # noqa: E402

ZX_LO, ZX_HI = 0x5B00, 0x7BBE
MYVARS = [(0xE965, 5), (0xEADF, 3), (0xEE4E, 3), (0xF30C, 1), (0xF470, 1), (0xF691, 1)]
STUBVARS = {0xA093: 1, 0xB161: 1, 0xB8F9: 12}
# junction tables FD6B/FEB0: the externals return pointers into them, so the
# test mirrors them at the same addresses in the 6502 memory (free there)
JTAB = (0xFD6B, 0xFFF0)
EXT = [0x98F4, 0xF37A, 0xA36F, 0xA496, 0xA487, 0xA0B1, 0x9498, 0x8EAB, 0xB412, 0xB91B,
       0xB905, 0xB913, 0xB83A, 0xB0AA, 0xB9EE, 0xB9DD, 0xB98D, 0xB49A, 0x7CA1, 0x8F0B,
       0xA4C9, 0xA4D6, 0x8C87, 0x927B, 0x9230, 0xDBD7, 0xDDD3, 0xBA56]
INLINE = {0xF35F: 9, 0xF5CD: 9, 0xF713: 8, 0xF725: 21}
# inputs checked at each external call: names of Z80 registers
INPUTS = {0x98F4: ['hl'], 0xF37A: ['hl'], 0xA36F: ['a'], 0xA496: ['iy'], 0xA487: ['iy'],
          0xA0B1: ['d'], 0x9498: ['ix'], 0x8EAB: ['iy'], 0xB412: ['alt_hl', 'alt_a', 'iy'],
          0xB91B: ['hl', 'c'], 0xB905: ['iy'], 0xB913: ['iy'],
          0xB83A: ['a', 'carry', 'c', 'alt_hl', 'iy'], 0xB0AA: ['a', 'hl', 'iy'],
          0xB9EE: ['a', 'iy'], 0xB9DD: ['a', 'iy'], 0xB98D: ['a'], 0xB49A: ['hl', 'bc'],
          0xA4C9: ['hl'], 0x8C87: ['a', 'e'], 0x927B: ['iy'], 0x9230: ['iy'], 0xDBD7: ['iy'],
          0xBA56: ['a']}
SND_REV, SND_SCREECH, SND_CRASH, SND_CHIRP = 2, 3, 4, 5
LD_A_R = [0x9096, 0x9193, 0x93E5, 0xA5E3, 0xAC5D, 0xB170, 0xE990, 0xF62C, 0xF71B, 0xF9FD]
MY_R = {0xE992, 0xF62E, 0xF71D}


STACK = (0x72D0, 0x7300)          # the Spectrum stack: not compared


def var_ranges():
    r = [(ZX_LO, STACK[0]), (STACK[1], ZX_HI), JTAB] + [(a, a + n) for a, n in MYVARS] + [(a, a + n) for a, n in STUBVARS.items()]
    return r


RANGES = var_ranges()


def diff(pre, post):
    out = []
    for lo, hi in RANGES:
        if pre[lo:hi] != post[lo:hi]:
            for a in range(lo, hi):
                if pre[a] != post[a]:
                    out.append((a, post[a]))
    return out


def snap(m):
    return {lo: bytes(m[lo:hi]) for lo, hi in RANGES}


class Sample:
    def __init__(self, regs, mem):
        self.pre, self.pre_mem = regs, mem
        self.post = self.post_mem = None
        self.events = []
        self.rvals = []


# ------------------------------------------------------------------ capture
def capture(ref, entry, n, frames, keyfn, inject=None, every=1):
    z = ref.z
    st = {'cur': None, 'ext': None, 'seen': 0}
    samples = []

    def bp():
        pc = z.pc
        cur = st['cur']
        if cur is None:
            if pc == entry and len(samples) < n:
                st['seen'] += 1
                if st['seen'] % every:
                    return
                if inject:
                    inject(ref)
                cur = Sample(ref.regs(), ref.mem())
                st['cur'] = cur
                st['sp'] = z.sp
                st['ret'] = int.from_bytes(z.read(z.sp, 2), 'little')
                z.set_breakpoint(st['ret'])
            return
        ext = st['ext']
        if ext is not None:
            if pc == ext['ret'] and z.sp == ext['sp'] + 2:
                m = ref.mem()
                cur.events.append(('ext', ext['addr'], ext['regs'], ext['snap'], diff(ext['mem'], m),
                                   ref.regs(), ext['skip']))
                st['ext'] = None
                if pc == st['ret'] and z.sp == st['sp'] + 2:   # tail jump
                    finish(cur)
            return
        if pc == st['ret'] and z.sp == st['sp'] + 2:
            finish(cur)
            return
        if pc in MY_R:
            cur.rvals.append(z.af >> 8)
            return
        if pc in EXTS:
            ret = int.from_bytes(z.read(z.sp, 2), 'little')
            m = ref.mem()
            skip = INLINE.get(ret, 0)
            st['ext'] = {'addr': pc, 'regs': ref.regs(), 'mem': m, 'snap': snap(m),
                         'ret': ret + skip, 'sp': z.sp, 'skip': skip}
            z.set_breakpoint(ret + skip)
            return
        if pc == 0xA977:
            ret = int.from_bytes(z.read(z.sp, 2), 'little')
            if ret == 0xEA18:
                cur.events.append(('snd', SND_REV, z.read(0xEA1A, 1)[0]))
            elif ret == 0xF3BE:
                cur.events.append(('snd', SND_CHIRP, None))
            else:
                cur.events.append(('snd', -1, ret))
        elif pc == 0x8EBF:
            cur.events.append(('snd', SND_CRASH, z.bc >> 8))
        elif pc in (0xE9F4, 0xEFCA):
            cur.events.append(('snd', SND_SCREECH, None))

    def finish(cur):
        cur.post = ref.regs()
        cur.post_mem = ref.mem()
        samples.append(cur)
        st['cur'] = None

    EXTS = set(EXT)
    z.on_breakpoint = bp
    for a in [entry] + EXT + [0xA977, 0x8EBF, 0xE9F4, 0xEFCA] + list(MY_R):
        z.set_breakpoint(a)
    for f in range(frames):
        if keyfn:
            keyfn(ref, f)
        ref.run(1)
        if len(samples) >= n:
            break
    z.on_breakpoint = lambda: None
    return samples


def inject_bang(ref):
    """Put the hazard object 13 on the player's cell so SF6E3 goes past its checks."""
    p = ref.peek
    l, h = p(0x7798)[0], p(0x7799)[0]
    ref.poke(0x779F, [0x80 | (p(0x779F)[0] & 0x7D)])
    ref.poke(0x77A4, [l, (h + 1) & 0xFF])
    ref.poke(0x77A3, [0])
    ref.poke(0x7797, [0])
    ref.poke(0x760E, [p(0x760E)[0] & 0xF7])
    ref.poke(0xE967, [random.choice([0, 3, 5, 6, 9, 15, 0xFD])])


def inject_engine(ref):
    """Random engine-dead / overheating flags for SE96A."""
    p = ref.peek
    v = p(0x760E)[0] & 0xFC
    ref.poke(0x760E, [v | random.choice([0, 1, 2, 3])])
    if random.random() < 0.3:
        ref.poke(0xE967, [0])


def profile_driver(kind, seed):
    """keyfn: scripted driving styles (re-chosen every 10-40 frames)."""
    rng = random.Random(seed)
    st = {'next': 0}

    def fn(ref, f):
        if f < st['next']:
            return
        ref.release()
        x = rng.random()
        if kind == 'fire':          # fast, firing straight ahead, some lane changes
            keys = ['S'] if x < 0.5 else (['K'] if x < 0.85 else ['S', rng.choice('JL')])
            st['next'] = f + rng.randint(15, 60)
        elif kind == 'turns':       # handbrake turns and U-turns at speed
            if x < 0.55:
                keys = ['S']
                st['next'] = f + rng.randint(20, 80)
            elif x < 0.9:
                keys = ['K', rng.choice('JL')]
                st['next'] = f + rng.randint(10, 40)
            else:
                keys = ['A']
                st['next'] = f + rng.randint(10, 30)
        else:                       # 'reverse': stop, reverse, steer while reversing
            if x < 0.4:
                keys = ['A']
                st['next'] = f + rng.randint(30, 120)
            elif x < 0.6:
                keys = []
                st['next'] = f + 10
            elif x < 0.8:
                keys = ['A', rng.choice('JL')] if rng.random() < 0.5 else ['K', rng.choice('JL')]
                st['next'] = f + rng.randint(10, 30)
            else:
                keys = ['S']
                st['next'] = f + rng.randint(10, 60)
        for k in keys:
            ref.hold(k)
    return fn


# ------------------------------------------------------------------ unit tests
# At the start of SEAE2 the Spectrum is redirected to one routine with a
# randomised state (inject), which also reaches code that normal driving
# rarely or never runs.  The routine returns to SEAE2's caller.
def _rec(rng, k):
    return 0x7702 + 12 * k


def _put_object(ref, rng, k, l, h):
    """object k in cell (l, h) with a random record"""
    a = _rec(rng, k)
    rec = [rng.randrange(8), 0x80 | rng.randrange(0x80), rng.choice([0, 1, 3, 7, 0xB, 0x13, 5]),
           rng.randrange(256), rng.choice([8, 4, 2, 8, 0]), rng.randrange(8), l, h,
           rng.randrange(12), rng.randrange(20), rng.randrange(256), rng.randrange(8)]
    ref.poke(a, rec)
    ref.poke(h * 256 + l, [k])
    return a


def _lane_cell(ref, rng):
    p = ref.peek
    return rng.randrange(0x68, 0xC0), rng.randrange(p(0x75D6)[0], p(0x75D7)[0] + 1)


def unit_prep(name, rng):
    def prep(ref):
        z, p, poke = ref.z, ref.peek, ref.poke
        z.iy, z.ix = 0x7792, 0x75E1
        spd = rng.choice([0, 1, 3, 4, 5, 6, 9, 14, 15, 0xFD, 0xFF, 0x86])
        d6, d7 = p(0x75D6)[0], p(0x75D7)[0]
        if name == 'F692':
            k = rng.randrange(14)
            z.iy = _rec(rng, k)
            poke(z.iy, [rng.randrange(8), rng.randrange(256)])
            poke(z.iy + 7, [rng.randrange(0x5C, 0x64), rng.randrange(12)])
        elif name == 'F6CF':
            z.iy = _rec(rng, rng.randrange(1, 12))
            poke(z.iy + 6, [rng.choice([0x2E, (p(0x75F5)[0] + 0x92) & 0xFF, rng.randrange(256)])])
            poke(0x75FB, [rng.randrange(256), rng.randrange(256)])
        elif name in ('EDBA', 'EDE9'):
            poke(0x7792, [rng.randrange(8), rng.randrange(256) & 0x7D | 0x80])
            poke(0x779A, [rng.randrange(3)])
            poke(0x7799, [rng.choice([d6 - 1, d6, d6 + 1, d7 - 1, d7, d7 + 1])])
            if name == 'EDE9':
                poke(0x7793, [p(0x7793)[0] & 0xBF])
        elif name in ('F3D7', 'F3F4', 'F3F6'):
            poke(0xE967, [spd])
            z.af = (rng.randrange(1, 4) << 8) | (z.af & 0xFF)
        elif name == 'F38B':
            k = rng.randrange(1, 12)
            l, h = _lane_cell(ref, rng)
            z.iy = _put_object(ref, rng, k, l, h)
            if rng.random() < 0.5:
                poke(h * 256 + l - 2, [0xFF, 0xFF])
            if rng.random() < 0.2:
                poke(h * 256 + l, [0x80 | (rng.randrange(8) << 3)])
            z.hl = h * 256 + l
        elif name == 'ED87':
            poke(0xE967, [spd])
            poke(0x7792, [rng.randrange(8), p(0x7793)[0] ^ (rng.randrange(2) << 5)])
            poke(0x7797, [rng.randrange(8)])
            z.af = (rng.randrange(8) << 8) | (z.af & 0xFF)
        elif name in ('F4EF', 'F4A7', 'F4BA', 'F2D1'):
            f = p(0x7793)[0] & 0xDF | (rng.randrange(2) << 5)
            poke(0x7793, [f])
            poke(0x7799, [d7 if f & 0x20 else d6])
            poke(0x7798, [(p(0x75F5)[0] + 0x64 + rng.randrange(-1, 5)) & 0xFF])
            z.alt_af = 0x0C00
        elif name == 'F288':
            poke(0x7797, [rng.randrange(8)])
        elif name in ('F319', 'ECAB'):
            l, h = _lane_cell(ref, rng)
            z.hl = h * 256 + l
            z.bc = (rng.randrange(1, 9) << 8) | rng.randrange(256)
            if name == 'F319':
                z.af = (rng.choice([0x2C, 0x2D]) << 8)
            else:
                z.af = rng.choice([0x0040, 0x8080])     # A and the sign flag
                poke(0x7792, [rng.randrange(8)])
            poke(0x7793, [p(0x7793)[0] ^ (rng.randrange(2) << 5)])
            for i in range(rng.randrange(3)):
                k = rng.randrange(1, 12)
                _put_object(ref, rng, k, (l + rng.randrange(-9, 10)) & 0xFF, h + rng.randrange(-1, 2))
        elif name in ('F34B', 'F36A'):
            z.af = rng.randrange(256) << 8
            poke(0x750B, [rng.randrange(256) for _ in range(4)])
        elif name == 'F448':
            poke(0xE967, [spd])
            poke(0x75F8, [rng.randrange(256)])
        elif name == 'F491':
            poke(0xE967, [spd])
            poke(0xF470, [rng.randrange(6)])
        elif name == 'EBEF':
            k = rng.choice([1, 2, 3, 13, 14, 15, 16, 5, 9])
            l, h = _lane_cell(ref, rng)
            a = _put_object(ref, rng, k, l, h)
            poke(a + 2, [rng.choice([1, 3, 7, 0xB, 0x13, 0x0F, 0, 5])])
            poke(a + 11, [rng.randrange(10)])
            poke(0x750F, [rng.randrange(1, 4)])
            poke(0x760C, [rng.randrange(4)])
            z.hl = h * 256 + l
            z.bc = rng.randrange(1, 6)
            z.de = rng.choice([0x0000, 0xFE00, 0xFF00])
        elif name == 'F549':
            poke(0x7797, [0])
            poke(0x7793, [p(0x7793)[0] & 0xBF])
            l, h = p(0x7798)[0], p(0x7799)[0]
            k = rng.choice([1, 2, 3, 13, 14, 15, 16])
            a = _put_object(ref, rng, k, (l - rng.randrange(3, 18)) & 0xFF, h + rng.randrange(-1, 2))
            poke(a + 2, [rng.choice([1, 3, 7, 0xB, 0x0F, 0x13, 1])])
            poke(a + 1, [p(a + 1)[0] & 0xBD])
            if rng.random() < 0.5:
                poke(a + 11, [0])
        elif name in ('EAE2J', 'EAE2E'):
            # junction mode / block-end situations (code the original's own
            # coverage never reached)
            poke(0xE967, [rng.choice([1, 3, 5, 9, 15, 0xFD])])
            poke(0x7797, [rng.choice([0, 0, 1, 2, 3, 4, 5])])
            poke(0x760B, [rng.choice([0, 2, 0x82, 0x42])])
            f5 = p(0x75F5)[0]
            if name == 'EAE2J':
                f = (p(0x7793)[0] & 0x9F) | 0x40 | (rng.randrange(2) << 5)
                row = rng.randrange(f5 if f5 else 1)
                poke(0x7792, [rng.randrange(8), f])
                poke(0x779A, [rng.randrange(4), row])
                base = 0xFEB0 if f & 0x20 else 0xFD6B
                ptr = base + 12 * row + rng.randrange(4)
                poke(0x7798, [ptr & 0xFF, ptr >> 8])
            else:
                poke(0x75F1, [rng.choice([0x0A, 0x02, 0x08, 0x05, 0x00])])
                poke(0x7798, [rng.choice([0x67, 0x68, 0x69, (f5 + 0x62) & 0xFF, (f5 + 0x63) & 0xFF])])
                poke(0x7793, [p(0x7793)[0] & 0xBB])
                poke(0x7797, [0])
                poke(0x760B, [0])
                poke(0x7792, [rng.choice([0, 0, 4])])
        z.pc = int(name[:4], 16)
    return prep


UNITS = ['F692', 'F6CF', 'EDBA', 'EDE9', 'F3D7', 'F3F4', 'F3F6', 'F38B', 'ED87', 'F4EF', 'F4A7',
         'F4BA', 'F2D1', 'F288', 'F319', 'ECAB', 'F34B', 'F36A', 'F448', 'F491', 'EBEF', 'F549',
         'EAE2J', 'EAE2E']


def collect_units(nunit):
    from zxref import Ref
    out = {}
    for ui, name in enumerate(UNITS):
        r = Ref()
        r.to_game(city='1234'[ui % 4], option='8')
        r.hold('S')
        r.run(150)
        r.release()
        rng = random.Random(1000 + ui)
        n = nunit * 4 if name in ('F549', 'EBEF') else nunit
        out[name] = capture(r, 0xEAE2, n, n * 40, None, inject=unit_prep(name, rng))
    return out


def collect(nper, frames):
    from zxref import Ref
    out = {'EAE2': [], 'E96A': [], 'F6E3': []}
    for ci, city in enumerate('1234'):
        for kind in ('random', 'fire', 'turns', 'reverse'):
            r = Ref()
            r.to_game(city=city, option='8')
            if kind == 'random':
                drv = Ref.random_driver(seed=11 + ci, period=12)
            else:
                drv = profile_driver(kind, 100 * ci + len(kind))
            out['EAE2'] += capture(r, 0xEAE2, nper, frames, drv)
            out['E96A'] += capture(r, 0xE96A, nper // 4, frames // 4, drv)
            random.seed(ci * 7 + len(kind))
            out['E96A'] += capture(r, 0xE96A, nper // 8, frames // 4, drv, inject=inject_engine)
            out['F6E3'] += capture(r, 0xF6E3, 4, 300, drv, inject=inject_bang)
        print('city', city, {k: len(v) for k, v in out.items()}, flush=True)
    return out


# ------------------------------------------------------------------ 6502 side
REGS8 = {'b': ('bc', 8), 'c': ('bc', 0), 'd': ('de', 8), 'e': ('de', 0),
         'h': ('hl', 8), 'l': ('hl', 0)}


class Runner:
    def __init__(self):
        r = subprocess.run([sys.executable, 'tools/buildtest.py', 'player', 'src/player.s'],
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr)
            sys.exit(1)
        self.sim = Sim('build/test_player.bin')
        s = self.sim.sym
        self.stubs = {}
        for name, a in s.items():
            if name.startswith('Z_') and name[2:] and int(name[2:], 16) in EXT:
                self.stubs[a] = int(name[2:], 16)
        self.snd = s['snd_fx']
        self.tgear = s['T_EAB5']
        self.stubvar = {a: s['ZV_%04X' % a] for a in STUBVARS}
        # Spectrum address -> oric address for the variables of RANGES
        self.map = {}
        for zxa, (oa, n) in self.sim.zvars.items():
            for i in range(n):
                self.map[zxa + i] = oa + i
        for a, n in STUBVARS.items():
            for i in range(n):
                self.map[a + i] = self.stubvar[a] + i
        self.cycles = []
        self.cov = set()

    # E965 holds an Oric pointer into T_EAB5
    def g2o(self, v):
        return self.tgear + (v - 0xEAB5)

    def load(self, mem, regs):
        sim = self.sim
        sim.load_state(mem, regs)
        sim.mem[JTAB[0]:JTAB[1]] = mem[JTAB[0]:JTAB[1]]
        v = self.g2o(mem[0xE965] | mem[0xE966] << 8)
        a = sim.sym['ZV_E965']
        sim.mem[a], sim.mem[a + 1] = v & 0xFF, v >> 8
        for zxa, n in STUBVARS.items():
            oa = self.stubvar[zxa]
            sim.mem[oa:oa + n] = mem[zxa:zxa + n]

    def zx_view(self):
        """Current 6502 state as Spectrum bytes for the RANGES addresses."""
        m = self.sim.mem
        out = bytearray(0x10000)
        out[ZX_LO:ZX_HI] = m[ZX_LO:ZX_HI]
        out[STACK[0]:STACK[1]] = bytes(STACK[1] - STACK[0])
        out[JTAB[0]:JTAB[1]] = m[JTAB[0]:JTAB[1]]
        for zxa, oa in self.map.items():
            out[zxa] = m[oa]
        a = self.sim.sym['ZV_E965']
        v = (m[a] | m[a + 1] << 8) - self.tgear + 0xEAB5
        out[0xE965], out[0xE966] = v & 0xFF, (v >> 8) & 0xFF
        return out

    def cmp(self, zxmem, ignore=()):
        v = self.zx_view()
        out = []
        for lo, hi in RANGES:
            for a in range(lo, hi):
                if a not in ignore and v[a] != zxmem[a]:
                    out.append((a, zxmem[a], v[a]))
        return out

    def reg(self, name):
        m, s, mpu = self.sim.mem, self.sim.sym, self.sim.mpu
        z = {'b': 'zb', 'c': 'zc', 'd': 'zd', 'e': 'ze', 'h': 'zh', 'l': 'zl'}
        if name == 'a':
            return mpu.a
        if name == 'carry':
            return mpu.p & 1
        if name == 'alt_a':
            return m[s['za2']]
        if name in z:
            return m[s[z[name]]]
        pairs = {'bc': ('zc', 'zb'), 'de': ('ze', 'zd'), 'hl': ('zl', 'zh'), 'ix': ('zixl', 'zixh'),
                 'iy': ('ziyl', 'ziyh'), 'alt_hl': ('zl2', 'zh2')}
        lo, hi = pairs[name]
        return m[s[lo]] | m[s[hi]] << 8

    @staticmethod
    def zreg(regs, name):
        if name == 'a':
            return regs['af'] >> 8
        if name == 'carry':
            return regs['af'] & 1
        if name == 'alt_a':
            return regs['alt_af'] >> 8
        if name in REGS8:
            p, sh = REGS8[name]
            return (regs[p] >> sh) & 0xFF
        return regs[name]

    def run(self, target, smp, a=None):
        sim = self.sim
        mpu = sim.mpu
        self.load(smp.pre_mem, smp.pre)
        mpu.sp = 0x7F
        mpu.stPushWord(STOP - 1)
        mpu.pc = sim.sym[target]
        mpu.a = smp.pre['af'] >> 8
        mpu.p = 0x20 | (smp.pre['af'] & 1)
        rnd = sim.sym['rnd_r']
        rv = list(smp.rvals)
        ev = list(smp.events)
        start = mpu.processorCycles
        ext_cycles = 0
        rng = random.Random(1)
        while mpu.pc != STOP:
            pc = mpu.pc
            if pc == rnd or pc == self.snd or pc in self.stubs:
                if pc == rnd:
                    if not rv:
                        return 'R value missing'
                    mpu.a = rv.pop(0)
                    mpu.p = (mpu.p & ~0x82) | (0x02 if mpu.a == 0 else 0) | (mpu.a & 0x80)
                    skip = 0
                elif pc == self.snd:
                    if not ev or ev[0][0] != 'snd':
                        return 'unexpected snd_fx A=%d X=%d (next %s)' % (
                            mpu.a, mpu.x, ev[0][:2] if ev else None)
                    e = ev.pop(0)
                    if e[1] != mpu.a or (e[1] in (SND_REV, SND_CRASH) and e[2] != mpu.x):
                        return 'snd mismatch: spectrum %s, 6502 A=%d X=%d' % (e[1:], mpu.a, mpu.x)
                    skip = 0
                else:
                    zxa = self.stubs[pc]
                    if not ev or ev[0][0] != 'ext' or ev[0][1] != zxa:
                        return 'unexpected call %04X (next %s)' % (
                            zxa, ('%s %04X' % (ev[0][0], ev[0][1] or 0)) if ev else None)
                    _, _, pre, psnap, d, post, skip = ev.pop(0)
                    v = self.zx_view()
                    for lo, data in psnap.items():
                        if v[lo:lo + len(data)] != data:
                            bad = [(lo + i, data[i], v[lo + i]) for i in range(len(data))
                                   if data[i] != v[lo + i]]
                            return 'state before %04X differs: %s' % (
                                zxa, ' '.join('%04X:%02X/%02X' % x for x in bad[:12]))
                    for r in INPUTS.get(zxa, ()):
                        if self.reg(r) != self.zreg(pre, r):
                            return 'input %s of %04X: spectrum %X, 6502 %X' % (
                                r, zxa, self.zreg(pre, r), self.reg(r))
                    for a, val in d:
                        if a == 0xE965 or a == 0xE966:
                            return 'external %04X wrote E965' % zxa
                        sim.mem[self.map.get(a, a)] = val
                    sim.set_regs(post)
                    mpu.a = post['af'] >> 8
                    f = post['af'] & 0xFF
                    mpu.p = (mpu.p & ~0x83) | (f & 1) | (0x02 if f & 0x40 else 0) | (f & 0x80)
                    mpu.x = rng.randrange(256)
                    mpu.y = rng.randrange(256)
                    ext_cycles += 6 * 12
                # rts (+ inline data)
                lo = sim.mem[0x100 + ((mpu.sp + 1) & 0xFF)]
                hi = sim.mem[0x100 + ((mpu.sp + 2) & 0xFF)]
                mpu.sp = (mpu.sp + 2) & 0xFF
                mpu.pc = ((hi << 8) | lo) + 1 + skip
                continue
            self.cov.add(pc)
            mpu.step()
            if mpu.processorCycles - start > 3_000_000:
                return 'did not return (pc=%04X)' % mpu.pc
        self.cycles.append(mpu.processorCycles - start)
        if ev:
            return 'events left: %s' % [(e[0], e[1]) for e in ev[:4]]
        if rv:
            return 'R values left'
        d = self.cmp(smp.post_mem)
        if d:
            return 'final state differs: ' + ' '.join('%04X:%02X/%02X' % x for x in d[:16])
        return None


def main():
    nper = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    cache = os.path.join('build', 'player_samples_%d_%d.pkl' % (nper, frames))
    if os.path.exists(cache):
        data = pickle.load(open(cache, 'rb'))
    else:
        data = collect(nper, frames)
        data['units'] = collect_units(max(10, nper // 2))
        pickle.dump(data, open(cache, 'wb'))
    R = Runner()
    # tables against the original image
    import zxtape
    img = zxtape.load_image(os.path.join('orig', 'TurboEsprit.tzx'))
    tbad = 0
    for name, zxa, n in (('T_EAB5', 0xEAB5, 42), ('T_F30D', 0xF30D, 16), ('T_F471', 0xF471, 32),
                         ('T_E94D', 0xE94D, 24)):
        a = R.sim.sym[name]
        if R.sim.mem[a:a + n] != img[zxa:zxa + n]:
            print('table %s differs from the original' % name)
            tbad += 1
    total_bad = tbad
    for key in ('E96A', 'EAE2', 'F6E3'):
        smps = data[key]
        bad = 0
        R.cycles = []
        for i, s in enumerate(smps):
            err = R.run('Z_' + key, s)
            if err:
                bad += 1
                if bad <= 8:
                    print('%s sample %d: %s' % (key, i, err))
        cyc = R.cycles
        avg = sum(cyc) // len(cyc) if cyc else 0
        print('Z_%s: %d samples, %d differ; cycles avg %d max %d (externals stubbed)' % (
            key, len(smps), bad, avg, max(cyc) if cyc else 0))
        total_bad += bad
    for name, smps in data['units'].items():
        bad = 0
        for i, s in enumerate(smps):
            err = R.run('Z_' + name[:4], s)
            if err:
                bad += 1
                if bad <= 4:
                    print('unit %s sample %d: %s' % (name, i, err))
        print('unit %s: %d samples, %d differ' % (name, len(smps), bad))
        total_bad += bad
    # coverage: labels of player.s whose first instruction never ran
    lbl = sorted((a, n) for n, a in R.sim.sym.items()
                 if (n.startswith('L') or n.startswith('Z_') or n.startswith('SEC')) and
                 R.sim.sym['Z_E96A'] - 0x300 <= a < R.sim.sym['Z_F6E3'] + 0x80 and a not in R.stubs)
    miss = [n for a, n in lbl if a not in R.cov]
    print('labels never reached (%d of %d):' % (len(miss), len(lbl)), ' '.join(miss))
    print('RESULT:', 'OK' if total_bad == 0 else '%d failures' % total_bad)


if __name__ == '__main__':
    main()
