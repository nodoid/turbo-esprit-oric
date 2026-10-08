#!/usr/bin/env python3
"""Differential test of src/world.s against the real Spectrum game.

Samples of the world routines (S8F23 traffic, S958B road description, S9907
lane grids, S9AA8 node-transition remap, L93D5 engine/fuel, L9498 refuel,
S94E5, S953B, S9564, S952F) are captured in all 4 cities with random
driving (tools/zxref.py), both from natural play and with injected states
that reach the paths normal play never takes (petrol station, turns,
backward steps, engine faults, sideways traffic...).  Calls the original
makes to code owned by other modules ("externals": SB412, SB241, SBA5F,
LA41E...) are recorded with their effect; when the 6502 translation calls the
corresponding stub, the test checks that the 6502 state equals the Spectrum
state at that point (memory + input registers), applies the recorded effect
and returns.  S98F4 is checked against its definition with the Z_F37A hook.

Cell pointers into the cross-street grids keep their Spectrum values
($FD60-$FFFF) in the records and in HL, so no translation is needed.

    python tests/test_world.py [samples_per_city=60] [frames=5000]

Samples are cached in build/world_samples_<n>_<frames>.pkl (delete to recapture).
"""
import os
import pickle
import random
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

from sim6502 import Sim, STOP  # noqa: E402

ZX_LO, ZX_HI = 0x5B00, 0x7BBE
STACK = (0x72D0, 0x7300)            # the Spectrum stack: not compared
MYVARS = [(0x9282, 0x153), (0x9494, 4), (0x9560, 4), (0xFD60, 0x2A0)]
STUBVARS = {0xB8F9: 12, 0xA093: 1, 0xE968: 1}
EXT = [0xB241, 0xB1BC, 0xB412, 0xDC4C, 0xBB18, 0xF4A7, 0xF2D1, 0xDE15, 0xBA5F, 0xA41E]
INLINE = {0x9400: 9, 0x9429: 15, 0x9441: 9, 0x947C: 7, 0x948D: 5, 0x94B5: 11}
INPUTS = {0xB241: ['iy', 'hl'], 0xB1BC: ['iy'], 0xB412: ['alt_hl', 'alt_a', 'iy'],
          0xDC4C: ['iy'], 0xF4A7: ['iy'], 0xF2D1: ['iy']}
MY_R = {0x9098, 0x9195, 0x93E7}
IGNORE = {0x74F9, 0x74FA}           # S958B saves SP there


def ranges():
    return ([(ZX_LO, STACK[0]), (STACK[1], ZX_HI)] + [(a, a + n) for a, n in MYVARS] +
            [(a, a + n) for a, n in STUBVARS.items()])


RANGES = ranges()


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
def capture(ref, entry, n, frames, keyfn, inject=None, trigger=None, every=1):
    """Samples of `entry`.  inject(ref) runs at a natural entry before the
    snapshot; trigger(ref) runs at every S8F23 (once per pass) and may
    redirect the Z80 into `entry` (returns True), as a call returning to
    the interrupted pass."""
    z = ref.z
    st = {'cur': None, 'ext': None, 'seen': 0}
    samples = []

    def start():
        cur = Sample(ref.regs(), ref.mem())
        st['cur'] = cur
        st['sp'] = z.sp
        st['ret'] = int.from_bytes(z.read(z.sp, 2), 'little')
        z.set_breakpoint(st['ret'])

    def bp():
        pc = z.pc
        cur = st['cur']
        if cur is None:
            if len(samples) >= n:
                return
            if trigger and pc == 0x8F23:
                saved = (ref.regs(), ref.mem())
                if trigger(ref):
                    st['saved'] = saved
                    start()
                return
            if pc == entry and not trigger:
                st['seen'] += 1
                if st['seen'] % every:
                    return
                if inject:
                    inject(ref)
                start()
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
            skip = INLINE.get(ret, 0) if pc == 0xBA5F else 0
            st['ext'] = {'addr': pc, 'regs': ref.regs(), 'mem': m, 'snap': snap(m),
                         'ret': ret + skip, 'sp': z.sp, 'skip': skip}
            z.set_breakpoint(ret + skip)
            return

    def finish(cur):
        cur.post = ref.regs()
        cur.post_mem = ref.mem()
        samples.append(cur)
        st['cur'] = None
        if st.get('saved'):              # undo the injected call: the game goes on
            regs, mem = st.pop('saved')
            ref.poke(0x4000, mem[0x4000:0x10000])
            for k, v in regs.items():
                setattr(z, k, v)

    EXTS = set(EXT)
    z.on_breakpoint = bp
    for a in [entry, 0x8F23] + EXT + list(MY_R):
        z.set_breakpoint(a)
    for f in range(frames):
        if keyfn and st['cur'] is None:
            keyfn(ref, f)
        ref.run(1)
        if len(samples) >= n:
            break
    z.on_breakpoint = lambda: None
    return samples


def redirect(ref, entry, regs=None):
    """Make the Z80 call `entry` now, returning to the current PC."""
    z = ref.z
    sp = (z.sp - 2) & 0xFFFF
    ref.poke(sp, [z.pc & 0xFF, z.pc >> 8])
    z.sp = sp
    z.ix = 0x75E1                        # the game's invariant (S8F23 sets it itself)
    for k, v in (regs or {}).items():
        setattr(z, k, v)
    z.pc = entry
    return True


def poke_bits(ref, a, andm, orm):
    ref.poke(a, [(ref.peek(a)[0] & andm) | orm])


# --- injections ------------------------------------------------------------
def set_arm_cell(rec, row, col):
    """Consistent cross-grid position: +9 row, +8 col, +6/+7 the cell."""
    rec[9], rec[8] = row, col
    p = (0xFEB0 + 12 * row + col) if rec[1] & 0x20 else (0xFD6B + 12 * row - col)
    rec[6], rec[7] = p & 0xFF, p >> 8


def inj_traffic(ref):
    rng = random.random
    for k in range(3):
        b = 0x770E + 12 * k
        rec = list(ref.peek(b, 12))
        if not rec[1] & 0x80 or rng() < 0.4:
            continue
        if rec[1] & 0x40:
            rec[5] = random.randrange(8)                 # incl. along-the-cross-street
        else:
            rec[5] = random.choice([1, 3, 5, 7, rec[5], 0, 2])
            rec[10] = random.choice([0, 0, 0, 1, 3])
            rec[0] = random.choice([0, 1, 2, 3, 4, 0xFC, 0xFD, 0xFE, 0xFF, 2])
            if rng() < 0.3:
                rec[1] ^= 0x20
        ref.poke(b, rec)
    if rng() < 0.3:
        poke_bits(ref, 0x75FD, 0x7F, random.choice([0, 0x80]))
    if rng() < 0.3:
        ref.poke(0x75F1, [random.randrange(16)])
    sc = random.randrange(6)
    cars = [0x770E + 12 * k for k in range(3)]
    act = [b for b in cars if ref.peek(b + 1)[0] & 0xC0 == 0x80]
    arm = [b for b in cars if ref.peek(b + 1)[0] & 0xC0 == 0xC0]
    f5 = ref.peek(0x75F5)[0]
    if sc == 0 and act:                  # about to reach an entrance / T-junction row
        b = random.choice(act)
        rec = list(ref.peek(b, 12))
        row = random.choice([0x2E, (f5 + 0x92) & 0xFF, 0x64, (f5 + 0x63) & 0xFF])
        rec[5] = random.choice([0, 2])
        rec[6] = (row + (1 if rec[5] == 0 else -1)) & 0xFF
        ref.poke(b, rec)
        ref.poke(0x75FB, [random.choice([1, 1, 0x81, 0])])
        ref.poke(0x75FC, [random.choice([1, 1, 0x81, 0])])
        ref.poke(0x75F1, [random.choice([2, 8, 0, 10])])
        if random.random() < 0.3:        # blocked: back out
            ref.poke(row | rec[7] << 8, [random.choice([0x0B, 0xFF, 8, 9])])
        return
    if sc == 1 and act:                  # about to turn into a side street
        b = random.choice(act)
        rec = list(ref.peek(b, 12))
        i = random.randrange(f5)
        rec[5] = 0
        rec[6] = 0x65 + i
        rec[1] = 0x80 | random.choice([0, 0x20])
        rec[7] = ref.peek(0x75D7 if rec[1] & 0x20 else 0x75D6)[0]
        ref.poke(b, rec)
        ref.poke(0x64 + i | rec[7] << 8, [(0xE0 if rec[1] & 0x20 else 0xC0) + i])
        poke_bits(ref, 0x75FD, 0x7F, random.choice([0, 0x80]))
        return
    if sc == 2 and arm:                  # walking towards the main road
        b = random.choice(arm)
        rec = list(ref.peek(b, 12))
        right = rec[1] & 0x20
        rec[5] = random.choice([3, 7] if right else [1, 5])
        rec[0] = random.choice([1, 4])
        set_arm_cell(rec, random.choice([0, rec[9] % f5]), random.choice([0, 0, 1, 5]))
        ref.poke(b, rec)
        ref.poke(0x75F1, [random.choice([0, 2, 8, 10])])
        return
    if sc == 3 and act:                  # sideways in the main grid
        b = random.choice(act)
        rec = list(ref.peek(b, 12))
        d6, d7 = ref.peek(0x75D6, 2)
        rec[7] = random.choice([0x5F, 0x60, d6, d7, 0x5E, 0x61])
        rec[5] = random.choice([1, 3])
        rec[10] = 0
        rec[0] = random.choice([4, 2, 0xFD, 1])
        rec[1] = 0x80 | random.choice([0, 0x20])
        if random.random() < 0.5:        # at a kerb row
            rec[7] = d7 if rec[1] & 0x20 else d6
            rec[0] = 2
            rec[6] = random.choice([0x64, (f5 + 0x63) & 0xFF, 0x2E, 0x50])
        ref.poke(b, rec)
        if random.random() < 0.3:        # into an opening (they are at rows 0x64..)
            i = random.randrange(f5)
            rec[6] = 0x64 + i
            ref.poke(b, rec)
            pg = (rec[7] + random.choice([1, -1])) & 0xFF
            ref.poke(rec[6] | pg << 8, [random.choice([0xC0, 0xE0]) + i])
        return
    if sc == 5:                          # a car put into a side street
        b = random.choice(cars)
        rec = list(ref.peek(b, 12))
        rec[1] = 0xC0 | random.choice([0, 0x20])
        right = rec[1] & 0x20
        towards = random.random() < 0.7
        rec[5] = random.choice(([3, 7] if right else [1, 5]) if towards else ([1, 5] if right else [3, 7]))
        rec[0] = random.choice([1, 1, 4] if towards else [0xFD])
        set_arm_cell(rec, random.choice([0, 0, random.randrange(f5)]), random.choice([0, 0, 1, 11]))
        ref.poke(b, rec)
        ref.poke(0x75F1, [random.choice([0, 0, 2, 8, 10])])
        return
    if sc == 4 and arm:                  # walking away from the main road
        b = random.choice(arm)
        rec = list(ref.peek(b, 12))
        right = rec[1] & 0x20
        rec[5] = random.choice([1, 5] if right else [3, 7])
        rec[0] = 0xFD
        set_arm_cell(rec, rec[9] % f5, random.choice([rec[8] % 12, 10, 11, 3]))
        ref.poke(b, rec)
        return
    if rng() < 0.4:
        ref.poke(0x75FB, [random.choice([0, 1, 0x81, 2, 3])])
        ref.poke(0x75FC, [random.choice([0, 1, 0x81, 2, 3])])


def conn(ref, h, l):
    m = ref.peek(0x9282, 0x142)

    def lk(h, l):
        h &= 255
        l &= 255
        if (h | l) & 0xE0 == 0:
            return m[(h >> 2) * 32 + l] >> (h & 3)
        if l & 0xE0:
            return 1 if h == m[0x141] else 0xFF
        return 0x10 if l == m[0x140] else 0xFF
    e = 0
    if lk(h, l) & 1:
        e |= 2
    if lk(h, l) & 0x10:
        e |= 1
    if lk(h, l - 1) & 0x10:
        e |= 4
    if lk(h - 1, l) & 1:
        e |= 8
    return e


def inj_road(ref):
    H = random.randrange(32)
    L = random.randrange(32)
    want = random.choice([None, 0, 0, 5, 10, 'ow', 'ow'])
    ns = ref.peek(0x9382, 32)
    ew = ref.peek(0x93A2, 32)
    for _ in range(400):
        if want is None:
            break
        if want == 'ow':
            if ns[L] & 0x80 or ew[H] & 0x80:
                break
        elif conn(ref, H, L) == want:
            break
        H = random.randrange(32)
        L = random.randrange(32)
    if random.random() < 0.15:
        H = random.choice([0, 31, 0xFF, 0x20])
    if random.random() < 0.15:
        L = random.choice([0, 31, 0xFF, 0x20])
    ref.poke(0x7504, [L, H])
    ref.poke(0x75F0, [random.randrange(8)])
    if random.random() < 0.5:
        ref.poke(0x75F4, [random.choice([0, 1, 2, 0x83, 0x87, 0x40])])
    ref.poke(0x75FE, [random.choice([2, 2, 3, 4, 0])])
    ref.poke(0x75FC, [random.choice([0, 1, 0x81, 0x80, 3])])


def inj_grid(ref):
    if random.random() < 0.5:                            # petrol station
        ref.poke(0x75F1, [5])
        ref.poke(0x75DF, [2])
        ref.poke(0x75B5, [1])
    elif random.random() < 0.5:
        ref.poke(0x75F1, [random.randrange(16)])
        ref.poke(0x75DF, [random.choice([1, 2, 3])])
    ref.poke(0x7504, [random.randrange(32), random.randrange(32)])
    ref.poke(0x75F0, [random.randrange(8)])
    ref.poke(0x75FB, [random.randrange(4)])
    ref.poke(0x75FC, [random.randrange(4)])
    ref.poke(0x75F2, [random.randrange(2)])
    if random.random() < 0.3:
        ref.poke(0x75B5, [random.choice([1, 2, 3])])


def inj_remap(ref):
    fe = random.choice([0, 1, 0, 1, 3, 4, 2, 4])
    ref.poke(0x75FE, [fe])
    f5 = ref.peek(0x75F5)[0]
    for b in [0x770E + 12 * k for k in range(3)] + [0x7792 + 12 * k for k in range(1, 16)]:
        rec = list(ref.peek(b, 12))
        if rec[1] & 0xC0 != 0x80 or random.random() < 0.5:
            continue
        r = random.random()
        if r < 0.2:
            rec[6] = random.choice([0x2E, (f5 + 0x92) & 0xFF, 0x30, 0x70, 0x90, 0xC0])
        elif r < 0.5:
            rec[7] = random.choice([0x5F, 0x60, 0x5E, 0x61, 0x5C, 0x63])
            rec[1] = 0x80 | (0x20 if rec[7] >= 0x60 else 0) ^ random.choice([0, 0, 0x20])
            rec[0] = random.choice([0, 1, 4, 5, 0xFC])
            rec[5] = random.randrange(16)
            rec[10] = random.choice([0, 1])
        ref.poke(b, rec)
    if random.random() < 0.3:
        ref.poke(0x75FF, [random.choice([0x0C, 0x14, 0x1C])])
    if random.random() < 0.3:
        ref.poke(0x7609, [random.choice([1, 2, 3])])


def trig_traffic(ref):
    if random.random() > 0.5:
        return False
    inj_traffic(ref)
    return redirect(ref, 0x8F23)


def trig_remap(ref):
    if random.random() > 0.3:
        return False
    inj_remap(ref)
    return redirect(ref, 0x9AA8)


def trig_road(ref):
    if random.random() > 0.5:
        return False
    inj_road(ref)
    return redirect(ref, 0x958B)


def trig_grid(ref):
    if random.random() > 0.5:
        return False
    inj_grid(ref)
    return redirect(ref, 0x9907)


def trig_engine(ref):
    if random.random() > 0.5:
        return False
    ref.poke(0x75F8, [random.choice([0x40, 0x80, 0, 0xC0, 0x40, 0x41])])
    ref.poke(0xA093, [0])
    poke_bits(ref, 0x760E, 0xFC, random.choice([0, 0, 1, 2]))
    ref.poke(0x9494, [random.choice([0, 3, 6, 7, 7, 8, 9, 10, 11, 0x7F, 0xFF])])
    ref.poke(0x9495, [random.choice([1, 2, 3, 11])])
    ref.poke(0x9496, [random.randrange(0x30), 0])
    ref.poke(0xE968, [random.randrange(40)])
    if random.random() < 0.2:
        ref.poke(0x9560, [0x68])
    return redirect(ref, 0x93D5)


def trig_refuel(ref):
    if random.random() > 0.5:
        return False
    ref.poke(0xA093, [random.choice([0, 0, 0, 0, 1])])
    poke_bits(ref, 0x75FD, 0xFF, random.choice([0x80, 0x80, 0]))
    poke_bits(ref, 0x7793, 0xFF, random.choice([0x40, 0x40, 0]))
    poke_bits(ref, 0x760E, 0xFE, random.choice([0, 1]))
    ref.poke(0x9496, [random.randrange(0x20, 0x30), 0])
    ref.poke(0x9495, [random.choice([3, 10, 11])])
    return redirect(ref, 0x9498)


def trig_init(ref):
    if random.random() > 0.2:
        return False
    return redirect(ref, 0x94E5)


def trig_rng(ref):
    if random.random() > 0.3:
        return False
    ref.poke(0x9560, [random.randrange(256), random.randrange(256)])
    return redirect(ref, 0x953B)


def trig_conn(ref):
    if random.random() > 0.3:
        return False
    H = random.choice([random.randrange(32), random.randrange(256), ref.peek(0x93C3)[0]])
    L = random.choice([random.randrange(32), random.randrange(256), ref.peek(0x93C2)[0], 0xFF, 0x20])
    return redirect(ref, 0x9564, {'hl': H << 8 | L})


def trig_type(ref):
    if random.random() > 0.3:
        return False
    return redirect(ref, 0x952F, {'hl': random.choice([0x9382, 0x93A2]),
                                  'af': (random.choice([random.randrange(0x20), random.randrange(256)]) << 8)})


def driver(seed, ref_force=True):
    base = __import__('zxref').Ref.random_driver(seed=seed, period=12)

    def fn(ref, f):
        base(ref, f)
        if ref_force and f % 40 == 0:
            ref.poke(0x7508, [0xA8])     # force node transitions
    return fn


def collect(nper, frames):
    from zxref import Ref
    out = {}

    def add(k, v):
        out.setdefault(k, []).extend(v)
    for ci, city in enumerate('1234'):
        random.seed(100 + ci)
        r = Ref()
        r.to_game(city=city, option='8')
        drv = driver(21 + ci)
        add('8F23', capture(r, 0x8F23, nper, frames, drv, every=3))
        add('958B', capture(r, 0x958B, nper // 3, frames, drv))
        add('9907', capture(r, 0x9907, nper // 3, frames, drv))
        add('9AA8', capture(r, 0x9AA8, nper // 3, frames, drv))
        add('93D5', capture(r, 0x93D5, 2, frames, drv))
        # fresh games for the injected states (they can end or wedge the game)
        for key, entry, cnt, inj, fr in (('8F23', 0x8F23, 3 * nper, inj_traffic, frames),
                                         ('9AA8', 0x9AA8, 2 * nper, inj_remap, 2 * frames)):
            r = Ref()
            r.to_game(city=city, option='8')
            add(key, capture(r, entry, cnt, fr, driver(51 + ci), inject=inj,
                             every=2 if entry == 0x8F23 else 1))
        # fresh games for the routines called by injection (they can end the game)
        for key, entry, cnt, trig in (('8F23', 0x8F23, 6 * nper, trig_traffic),
                                      ('9AA8', 0x9AA8, 3 * nper, trig_remap),
                                      ('958B', 0x958B, 3 * nper, trig_road),
                                      ('9907', 0x9907, nper, trig_grid),
                                      ('93D5', 0x93D5, nper, trig_engine),
                                      ('9498', 0x9498, nper // 2, trig_refuel),
                                      ('94E5', 0x94E5, 3, trig_init),
                                      ('953B', 0x953B, 8, trig_rng),
                                      ('9564', 0x9564, nper // 3, trig_conn),
                                      ('952F', 0x952F, nper // 4, trig_type)):
            r = Ref()
            r.to_game(city=city, option='8')
            add(key, capture(r, entry, cnt, frames, driver(71 + ci), trigger=trig))
        print('city', city, {k: len(v) for k, v in out.items()}, flush=True)
    return out


# ------------------------------------------------------------------ 6502 side
REGS8 = {'b': ('bc', 8), 'c': ('bc', 0), 'd': ('de', 8), 'e': ('de', 0),
         'h': ('hl', 8), 'l': ('hl', 0)}


class Runner:
    def __init__(self):
        vs = os.path.join('build', 'test_world_vars.s')
        os.makedirs('build', exist_ok=True)
        with open(vs, 'w') as f:
            f.write('        .include "zx.inc"\n        .segment "DATA"\n')
            for a, n in STUBVARS.items():
                f.write('        ZVAR $%04X, %d\n' % (a, n))
        r = subprocess.run([sys.executable, 'tools/buildtest.py', 'world', 'src/world.s', vs],
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr)
            sys.exit(1)
        self.sim = Sim('build/test_world.bin')
        s = self.sim.sym
        self.stubs = {}
        for name, a in s.items():
            if name.startswith('Z_') and len(name) == 6 and int(name[2:], 16) in EXT:
                self.stubs[a] = int(name[2:], 16)
        self.map = {}
        for zxa, (oa, n) in self.sim.zvars.items():
            for i in range(n):
                self.map[zxa + i] = oa + i
        self.cycles = []
        self.cov = set()

    def load(self, mem, regs):
        self.sim.load_state(mem, regs)

    def zx_view(self):
        m = self.sim.mem
        out = bytearray(0x10000)
        out[ZX_LO:ZX_HI] = m[ZX_LO:ZX_HI]
        out[STACK[0]:STACK[1]] = bytes(STACK[1] - STACK[0])
        for zxa, oa in self.map.items():
            out[zxa] = m[oa]
        return out

    def cmp(self, zxmem, ignore=IGNORE):
        v = self.zx_view()
        out = []
        for lo, hi in RANGES:
            if v[lo:hi] == zxmem[lo:hi]:
                continue
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

    def o2z(self, v):
        """Oric address -> Spectrum address for a pointer register."""
        for zxa, (oa, n) in self.sim.zvars.items():
            if oa <= v < oa + n and n > 1:
                return zxa + v - oa
        return v

    def z2o(self, v):
        for zxa, (oa, n) in self.sim.zvars.items():
            if zxa <= v < zxa + n and n > 1:
                return oa + v - zxa
        return v

    def run(self, target, smp, outregs=(), ptr_in=False):
        sim = self.sim
        mpu = sim.mpu
        self.load(smp.pre_mem, smp.pre)
        if ptr_in:          # HL is a pointer into relocated memory
            v = self.z2o(smp.pre['hl'])
            sim.mem[sim.sym['zl']], sim.mem[sim.sym['zh']] = v & 0xFF, v >> 8
        mpu.sp = 0xFF
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
            if pc == rnd or pc in self.stubs or pc in sim.hooks:
                skip = 0
                if pc == rnd:
                    if not rv:
                        return 'R value missing'
                    mpu.a = rv.pop(0)
                    mpu.p = (mpu.p & ~0x82) | (0x02 if mpu.a == 0 else 0) | (mpu.a & 0x80)
                elif pc in sim.hooks and pc not in self.stubs:
                    sim.hooks[pc](sim)
                else:
                    zxa = self.stubs[pc]
                    if not ev or ev[0][1] != zxa:
                        return 'unexpected call %04X (next %s)' % (
                            zxa, ('%04X' % ev[0][1]) if ev else None)
                    _, _, pre, psnap, d, post, skip = ev.pop(0)
                    v = self.zx_view()

                    ign = IGNORE
                    for lo, data in psnap.items():
                        if v[lo:lo + len(data)] != data:
                            bad = [(lo + i, data[i], v[lo + i]) for i in range(len(data))
                                   if data[i] != v[lo + i] and lo + i not in ign]
                            if bad:
                                return 'state before %04X differs: %s' % (
                                    zxa, ' '.join('%04X:%02X/%02X' % x for x in bad[:12]))
                    for r in INPUTS.get(zxa, ()):
                        mine = self.reg(r)
                        if mine != self.zreg(pre, r):
                            return 'input %s of %04X: spectrum %X, 6502 %X' % (
                                r, zxa, self.zreg(pre, r), self.reg(r))
                    for a, val in d:
                        sim.mem[self.map.get(a, a)] = val
                    sim.set_regs(post)
                    mpu.a = post['af'] >> 8
                    f = post['af'] & 0xFF
                    mpu.p = (mpu.p & ~0x83) | (f & 1) | (0x02 if f & 0x40 else 0) | (f & 0x80)
                    mpu.x = rng.randrange(256)
                    mpu.y = rng.randrange(256)
                    ext_cycles += 6 * 12
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
            return 'events left: %s' % ['%04X' % e[1] for e in ev[:4]]
        if rv:
            return 'R values left'
        d = self.cmp(smp.post_mem)
        if d:
            return 'final state differs: ' + ' '.join('%04X:%02X/%02X' % x for x in d[:16])
        for r in outregs:
            mine = self.reg(r)
            if r == 'hl' and ptr_in:
                mine = self.o2z(mine)
            if mine != self.zreg(smp.post, r):
                return 'output %s: spectrum %X, 6502 %X' % (r, self.zreg(smp.post, r), mine)
        return None


def uncovered_lines(cov, dbg='build/test_world.dbg', src='src/world.s'):
    """Source lines of src (CODE segment) whose code never ran."""
    segs, spans, lines, fid = {}, {}, [], None
    for ln in open(dbg):
        kind, _, rest = ln.partition('\t')
        f = dict(x.split('=', 1) for x in rest.strip().split(','))
        if kind == 'file' and f['name'] == '"%s"' % src:
            fid = f['id']
        elif kind == 'seg':
            segs[f['id']] = (f['name'].strip('"'), int(f['start'], 16))
        elif kind == 'span':
            spans[f['id']] = (f['seg'], int(f['start']), int(f['size']))
        elif kind == 'line' and 'span' in f:
            lines.append((f['file'], int(f['line']), f['span'].split('+')))
    out = set()
    for fl, no, sps in lines:
        if fl != fid:
            continue
        for sp in sps:
            sg, st, sz = spans[sp]
            name, base = segs[sg]
            if name != 'CODE':
                continue
            a = base + st
            if not any(x in cov for x in range(a, a + sz)):
                out.add(no)
    return sorted(out)


def test_98f4(R):
    """S98F4 against its definition (keys via the Z_F37A hook)."""
    sim = R.sim
    bad = 0
    for keys in ['', 'J', 'L', 'JL', 'K', 'A', 'KA', 'S']:
        for base, k1, k2 in ((0x7524, 'J', 'L'), (0x752D, 'A', 'S')):
            sim.keys_down = set(keys)
            sim.mem[sim.sym['zl']], sim.mem[sim.sym['zh']] = base & 0xFF, base >> 8
            sim.mem[sim.sym['zd']] = 0x55
            sim.call('Z_98F4')
            d = sim.mem[sim.sym['zd']]
            hl = sim.mem[sim.sym['zl']] | sim.mem[sim.sym['zh']] << 8
            exp = {(0, 0): 0, (1, 0): 3, (0, 1): 1, (1, 1): 2}[(k1 in keys, k2 in keys)]
            if d != exp or hl != base + 5:
                bad += 1
                print('S98F4 keys %r base %04X: D=%d (want %d) HL=%04X' % (keys, base, d, exp, hl))
    print('Z_98F4: 16 cases, %d differ' % bad)
    return bad


def main():
    nper = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    cache = os.path.join('build', 'world_samples_%d_%d.pkl' % (nper, frames))
    if os.path.exists(cache):
        data = pickle.load(open(cache, 'rb'))
    else:
        data = collect(nper, frames)
        pickle.dump(data, open(cache, 'wb'))
    R = Runner()
    import zxtape
    img = zxtape.load_image(os.path.join('orig', 'TurboEsprit.tzx'))
    total_bad = 0
    for name, zxa, n in (('T_980E', 0x980E, 8), ('T_9816', 0x9816, 62), ('T_9854', 0x9854, 128),
                         ('T_98D4', 0x98D4, 32)):
        a = R.sim.sym[name]
        if R.sim.mem[a:a + n] != img[zxa:zxa + n]:
            print('table %s differs from the original' % name)
            total_bad += 1
    total_bad += test_98f4(R)
    spec = {'9564': (['e'], False), '953B': (['hl', 'a', 'bc', 'de'], False),
            '952F': (['a', 'hl', 'bc'], True)}
    for key in ('8F23', '958B', '9907', '9AA8', '93D5', '9498', '94E5', '953B', '9564', '952F'):
        smps = data.get(key, [])
        bad = 0
        R.cycles = []
        outregs, ptr_in = spec.get(key, ((), False))
        for i, s in enumerate(smps):
            err = R.run('Z_' + key, s, outregs, ptr_in)
            if err:
                bad += 1
                if bad <= 6:
                    print('%s sample %d: %s' % (key, i, err))
        cyc = R.cycles
        avg = sum(cyc) // len(cyc) if cyc else 0
        print('Z_%s: %d samples, %d differ; cycles avg %d max %d (externals stubbed)' % (
            key, len(smps), bad, avg, max(cyc) if cyc else 0))
        total_bad += bad
    lo, hi = R.sim.sym['Z_8F23'], R.sim.sym['Z_9D62'] + 0x40
    lbl = sorted((a, n) for n, a in R.sim.sym.items()
                 if lo <= a < hi and not n.startswith('@') and not n.startswith('ZV') and
                 a not in R.stubs and not n.startswith('T_'))
    miss = [n for a, n in lbl if a not in R.cov and n not in ('Z_98F4',)]
    print('labels never reached (%d of %d):' % (len(miss), len(lbl)), ' '.join(miss))
    unc = uncovered_lines(R.cov)
    rs = []
    for n in unc:
        if rs and rs[-1][1] == n - 1:
            rs[-1][1] = n
        else:
            rs.append([n, n])
    print('world.s lines never executed (%d):' % len(unc),
          ' '.join('%d' % a if a == b else '%d-%d' % (a, b) for a, b in rs))
    print('RESULT:', 'OK' if total_bad == 0 else '%d failures' % total_bad)


if __name__ == '__main__':
    main()
