#!/usr/bin/env python3
"""Differential tests of src/objects.s against the original game.

Captures S876F, S881F (which draws every object through S893C), S893C,
S8EE2 and S8C87 calls from real play in the 4 cities (random driving) and runs
the translations from the same pre-state.  Everything in $5B00-$7BBD and every
ZV_ variable must match the Spectrum after the call, except:
  * $71D0-$72FF  the original's temporary sprite buffers and its stack
                  (not used by the port: rows are built in zero page),
  * $74F7-$74FA  the original's saved stack pointers.
Frames where an explosion ends call B3B3 (traffic module, a stub here); those
881F/893C samples are detected with the verified model and skipped.

usage: test_objects.py [samples_per_city] [quick]
"""
import os
import random
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)

from sim6502 import Sim, fmt_diffs  # noqa: E402
from zxref import Ref  # noqa: E402

SP = '/private/tmp/claude-501/-Users-pauljohnson-RiderProjects-durell-turbo/a65fa3af-adea-44f5-8cea-a95a5e33ecf6/scratchpad'
MODEL = os.path.join(SP, 'work_R3')
IGNORE = [(0x71D0, 0x7300), (0x74F7, 0x74FB)]


def build():
    os.makedirs('build', exist_ok=True)
    with open('build/objects_fd60.s', 'w') as f:
        f.write('; test support: the cross-street grids (owned by another module)\n'
                '        .include "zx.inc"\n        .segment "DATA"\n'
                '        ZLABEL $FD60, $2A0\n        .res $2A0\n')
    r = os.system('python3 tools/buildtest.py objects src/objects.s build/objects_fd60.s >/dev/null')
    if r:
        sys.exit('build failed')
    sim = Sim('build/test_objects.bin')
    # path coverage: record executed PCs
    sim.pcs = set()
    step = sim.mpu.step

    def tracked():
        sim.pcs.add(sim.mpu.pc)
        step()
    sim.mpu.step = tracked
    return sim


# rare branches inside routines (cheap-local labels, found in a listing)
LOCAL = [('gdraw', '@pair'), ('gapsetup', '@left'),
         ('overlay', '@p1')]


def local_addrs(sim):
    """Address of each LOCAL label (all in CODE), from a listing of objects.s."""
    import re
    os.system('ca65 -I src -I data -l build/objects_cov.lst -o build/objects_cov.o src/objects.s')
    out, scope, base = {}, None, None
    for line in open('build/objects_cov.lst'):
        mt = re.match(r'^([0-9A-F]{6})r \d .{12}\s*([A-Za-z_@][A-Za-z0-9_@]*):', line)
        if not mt:
            continue
        off, lab = int(mt.group(1), 16), mt.group(2)
        if lab == 'hit':
            base = sim.sym[lab] - off
        if not lab.startswith('@'):
            scope = lab
        elif (scope, lab) in LOCAL and base is not None:
            out[(scope, lab)] = base + off
    return out


COVER = ['explode', 'call_b3b3', 'group', 'colour', 'overlay', 'gapsetup', 'gapop', 'maska', 'maskam',
         'maskb', 'mbrun', 'fetchn0', 'fetchm0', 'rchain', 'lchain', 'mnone']


def check_data(sim):
    """The assembled sprite bank equals the tape's bytes, with every pointer
    relocated to the new address of its target.  Returns the error count."""
    import gen_objects
    import zxtape
    tape = zxtape.load_image(os.path.join(ROOT, 'orig', 'TurboEsprit.tzx'))
    bank = gen_objects.Bank(tape)
    bank.walk()
    new = {1: sim.sym['SPR1'], 2: sim.sym['SPR2']}
    old = {1: gen_objects.P1[0], 2: gen_objects.P2[0]}

    def reloc(a):
        n = gen_objects.piece(a)
        return a - old[n] + new[n]
    ptrbytes = {}
    for a, t in bank.ptrs.items():
        if gen_objects.FRAMES <= a < gen_objects.FRAMES + 8:
            continue
        ptrbytes[a] = reloc(t) & 0xFF
        ptrbytes[a + 1] = reloc(t) >> 8
    bad = 0
    for lo, hi in (gen_objects.P1, gen_objects.P2):
        for a in range(lo, hi):
            want = ptrbytes.get(a, tape[a])
            if sim.mem[reloc(a)] != want:
                bad += 1
    for k in range(4):
        t = bank.w(gen_objects.FRAMES + 2 * k)
        got = sim.mem[sim.sym['T_BF9C'] + 2 * k] | sim.mem[sim.sym['T_BF9C'] + 2 * k + 1] << 8
        bad += got != reloc(t)
    print('sprite bank: %d bytes, %d pointers relocated, %d wrong' % (
        sum(h - l for l, h in (gen_objects.P1, gen_objects.P2)), len(ptrbytes) // 2, bad))
    return bad


def model_ok(pre_mem, fn):
    """False when the model hits the (unmodelled) B3B3 call."""
    if not os.path.isdir(MODEL):
        return True
    sys.path.insert(0, MODEL)
    import model
    m = bytearray(pre_mem)
    try:
        getattr(model, fn)(m)
    except NotImplementedError:
        return False
    return True


def b3b3_in_draw(s):
    """893C sample that ends an explosion (obj[2] >= $C0 with flags bit1)."""
    K = s.pre['af'] >> 8
    k = K * 4 & 0xFF
    objp = (0x7702 + ((k * 2 & 0xFF) + k)) & 0xFFFF
    m = s.pre_mem
    return m[objp + 1] & 2 and m[objp + 2] >= 0xC0


def fire_driver(seed):
    """keyfn: accelerate, fire half the time, some steering."""
    rng = random.Random(seed)

    def fn(ref, f):
        if f % 8 == 0:
            ref.release()
            ref.hold('S')
            if rng.random() < 0.5:
                ref.hold('K')
            x = rng.random()
            if x < 0.15:
                ref.hold('J')
            elif x < 0.3:
                ref.hold('L')
    return fn


def explosion_ref():
    """City 4, driving and firing until an object explodes (frame ~135)."""
    ref = Ref()
    ref.to_game(city='4', option='8')
    drv = fire_driver(4)
    for f in range(3000):
        drv(ref, f)
        ref.run(1)
        m = ref.peek(0x7702, 12 * 29)
        if any(m[12 * k + 1] & 2 for k in range(1, 29)):
            return ref, drv
    return None, None


def check_b3b3(sim, s):
    """Explosion-end frame: B3B3 (stub here) must be called once with
    zl2/zh2 = obj[6..7], zc = obj[1] (bit7 cleared), ziy = the record, and the
    record's flags/counter must match the original.  Returns 1 on failure."""
    m = s.pre_mem
    exp = []
    for K in range(1, 32):
        k = K * 4 & 0xFF
        objp = (0x7702 + ((k * 2 & 0xFF) + k)) & 0xFFFF
        if m[objp + 1] & 2 and m[objp + 2] >= 0xC0:
            exp.append(objp)
    calls = []
    stub = sim.sym['Z_B3B3']
    step = sim.mpu.step

    def hook():
        if sim.mpu.pc == stub:
            g = sim.mem
            sy = sim.sym
            calls.append((g[sy['zl2']] | g[sy['zh2']] << 8, g[sy['zc']], g[sy['ziyl']] | g[sy['ziyh']] << 8))
        step()
    sim.mpu.step = hook
    sim.load_state(s.pre_mem, s.pre)
    sim.call('Z_881F')
    sim.mpu.step = step
    ok = len(calls) >= 1
    for hl, c, iy in calls:
        ok = ok and iy in exp and hl == (m[iy + 6] | m[iy + 7] << 8) and c == m[iy + 1] & 0x7F
        ok = ok and sim.mem[iy + 1] == s.post_mem[iy + 1] and sim.mem[iy + 2] == s.post_mem[iy + 2]
    print('B3B3 frame: calls %s expected records %s -> %s' % (
        ['HL=%04X C=%02X IY=%04X' % c for c in calls], ['%04X' % e for e in exp], 'ok' if ok else 'FAIL'))
    return 0 if ok else 1


def run(sim, s, entry, regs=True):
    sim.load_state(s.pre_mem, s.pre if regs else None)
    cyc = sim.call(entry, rvals=s.rvals)
    return sim.compare(s.post_mem, ignore=IGNORE), cyc


def main():
    per = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    quick = 'quick' in sys.argv
    sim = build()
    stats = {}
    fails = check_data(sim)
    cities = '1234' if not quick else '1'
    runs = [(c, None) for c in cities] + [(c, 'seed2') for c in cities] + [('4 (explosion)', 'expl')]
    for ci, (city, kind) in enumerate(runs):
        if kind == 'expl':
            ref, drv = explosion_ref()
            if ref is None:
                print('no explosion found')
                continue
            groups = [(0x881F, 'Z_881F', 8), (0x893C, 'Z_893C', 60)]
        else:
            ref = Ref()
            ref.to_game(city=city, option='8')
            drv = Ref.random_driver(seed=ci + 1 + (10 if kind == 'seed2' else 0))
            groups = [(0x876F, 'Z_876F', per), (0x881F, 'Z_881F', per), (0x893C, 'Z_893C', per * 6)]
        for zx, name, n in groups:
            samples = ref.capture(zx, n=n, frames=900, keyfn=drv, skip=random.Random(ci).randint(0, 3))
            for s in samples:
                if zx == 0x881F and not model_ok(s.pre_mem, 's881F'):
                    stats.setdefault(name + ' B3B3 frames', 0)
                    stats[name + ' B3B3 frames'] += 1
                    fails += check_b3b3(sim, s)
                    continue
                if zx == 0x893C and b3b3_in_draw(s):
                    stats.setdefault(name + ' skipped (B3B3)', 0)
                    stats[name + ' skipped (B3B3)'] += 1
                    continue
                d, cyc = run(sim, s, name)
                st = stats.setdefault(name, [0, 0, [], 0])
                st[0] += 1
                st[2].append(cyc)
                if d:
                    st[1] += 1
                    fails += 1
                    if st[1] <= 3:
                        print('%s city %s: %d diffs %s' % (name, city, len(d), fmt_diffs(d)))
        # traffic-light sequencer: rarely called, capture a few
        for s in ref.capture(0x8EE2, n=3, frames=400, keyfn=drv):
            d, cyc = run(sim, s, 'Z_8EE2')
            st = stats.setdefault('Z_8EE2', [0, 0, [], 0])
            st[0] += 1
            st[2].append(cyc)
            if d:
                st[1] += 1
                fails += 1
                print('Z_8EE2 city %s: %s' % (city, fmt_diffs(d)))
        print('city %s done' % city, flush=True)
    # 8C87 interface: A, E in -> A, C, Z, HL
    rng = random.Random(5)
    bad = 0
    for _ in range(300):
        a, e = rng.randrange(256), rng.randrange(256)
        sim.mem[sim.sym['ze']] = e
        sim.call('Z_8C87', a=a)
        p = (a & 0x7F) * e
        r = sim.get_regs()
        if (sim.mpu.a != (p >> 3) & 0xFF or r['carry'] != (p >> 11) & 1 or r['zero'] != (p < 0x1000)
                or r['hl'] != (p & 0xFF) | (p >> 12) << 8):
            bad += 1
    print('Z_8C87: 300 random inputs, %d wrong' % bad)
    fails += bad
    for name, st in stats.items():
        if isinstance(st, int):
            print('%-28s %d' % (name, st))
            continue
        c = sorted(st[2])
        print('%-8s samples %4d  failing %3d  cycles min %6d  median %6d  max %6d' % (
            name, st[0], st[1], c[0], c[len(c) // 2], c[-1]))
    syms = sorted(v for v in sim.sym.values())

    def hit(n):
        a = sim.sym[n]
        b = min([v for v in syms if v > a] + [0x10000])
        return any(a <= pc < b for pc in sim.pcs)
    loc = local_addrs(sim)
    missing = [n for n in COVER if not hit(n)] + ['%s/%s' % k for k in LOCAL if loc.get(k) not in sim.pcs]
    print('paths not executed:', ' '.join(missing) or 'none')
    print('RESULT:', 'OK' if not fails else '%d FAILING' % fails)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
