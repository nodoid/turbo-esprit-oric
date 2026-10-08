#!/usr/bin/env python3
"""Tests for src/menu.s (entry, city select, menus, score tables, key input).

The menu code runs on a 6502 (py65 + the harness VIA/AY/keyboard model, with
the 50Hz interrupt driving snd.s).  The graphics engine calls (Z_A4C9 inline
streams, Z_A526, Z_A695, Z_A8EB, gfx_attr) are executed by a Python model of
the engine that records the printed text, so the logic can be tested before
and independently of gfx.s.  The real Spectrum game (tools/zxref.py) runs the
original routines from the same state for comparison:

  1. inline text streams: byte-identical to the original
  2. SF7F9 insert: random tables/values, both tables, vs the Z80 routine
  3. FACA result recording after PLAY (random score/penalty) vs the Z80 code
  4. FD11 city select: city block D9282 and title DBACC for all 4 cities
  5. ALTER PLAYING KEYS: typing Q W E R T Y U; names vs the Spectrum, the
     Oric key table entries (row, mask, 0)
  6. ALTER SKILL: invalid digit (beep) then a valid one, vs the Spectrum
  7. name entry in the score table (typing, DELETE, ENTER) vs the Spectrum
  8. screens (text layout) of the menu, tables and key screen
usage: test_menu.py [-v]
"""
import os
import random
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU  # noqa: E402
import harness  # noqa: E402
import zxtape  # noqa: E402

VERBOSE = '-v' in sys.argv
STOP = 0x0300
M = zxtape.load_image(os.path.join(ROOT, 'orig', 'TurboEsprit.tzx'))

VARS_S = """; test-only definitions of other modules' variables
        .include "zx.inc"
        .data
        ZVAR $9282, $153
        ZVAR $BACC, 16
        ZVAR $9560, 2
"""

TOKENS = []
p = 0xA98F
for _ in range(32):
    s = ''
    while True:
        b = M[p]
        p += 1
        if b & 0x7F:
            s += chr(b & 0x7F)
        if b & 0x80:
            break
    TOKENS.append(s)


class Gfx:
    """Python model of the text side of the A4C9 engine (R5 1.2-1.8)."""

    def __init__(self, o):
        self.o = o
        self.text = {}
        self.x = self.y = 0
        self.cls = None
        self.attrs = []
        self.log = []

    def put(self, c):
        if c < 0x20:            # custom-font glyphs (the cursor blocks)
            self.x = (self.x + 8) & 0xFF
            return
        if c >= 0x80:
            for ch in TOKENS[c & 0x7F]:
                self.put(ord(ch))
            return
        self.text[(self.x, self.y)] = chr(c)
        self.x = (self.x + 8) & 0xFF

    def number(self, k, e, v):
        for d in (10000, 1000, 100, 10, 1)[k // 6:]:
            q, v = divmod(v, d)
            if q == 0:
                if not e & 0x80:
                    self.put(0x30)
                elif not e & 0x40:
                    self.put(e & 0x3F)
            else:
                e = 0
                self.put(0x30 + q)

    def stream(self, a, hl):
        mem = self.o.m.ram
        while True:
            b = mem[a]
            a += 1
            if b == 0:
                return a
            if b >= 0x80:
                if b == 0x8F:
                    self.text = {}
                    self.cls = mem[a]
                    self.log.append(('cls', mem[a]))
                    a += 1
                elif b in (0x85, 0x87, 0x88):
                    a += 2
                elif b in (0x80, 0x90):
                    a += 1
                continue
            n = b
            while n:
                c = mem[a]
                a += 1
                if c == 0xFF:
                    self.x, self.y = mem[a], mem[a + 1]
                    a += 2
                elif c == 0xFE:
                    self.x = (self.x + mem[a]) & 0xFF
                    a += 1
                elif c == 0xFD:
                    self.y = (self.y + mem[a]) & 0xFF
                    a += 1
                elif c == 0xFC:
                    self.number(mem[a], mem[a + 1], hl)
                    a += 2
                else:
                    self.put(c)
                    n -= 1

    def screen(self):
        rows = {}
        for (x, y), c in self.text.items():
            rows.setdefault(y, {})[x] = c
        out = []
        for y in sorted(rows):
            line = [' '] * 32
            for x, c in rows[y].items():
                line[x // 8] = c
            out.append('%3d |%s|' % (y, ''.join(line).rstrip()))
        return '\n'.join(out)


class Oric:
    def __init__(self, real_gfx=False):
        self.real_gfx = real_gfx
        vs = os.path.join('build', 'test_menu_vars.s')
        open(vs, 'w').write(VARS_S)
        # the gfx entry points as hookable labels (the Python engine model)
        open('build/test_menu_gstub.s', 'w').write(
            '        .export gfx_cls, gfx_attr_rows, gfx_recolour, gfx_rc_row, gfx_rc_n\n'
            '        .code\ngfx_cls: rts\ngfx_attr_rows: rts\ngfx_recolour: rts\n'
            '        .data\ngfx_rc_row: .byte 0\ngfx_rc_n: .byte 0\n')
        self.name = 'menug' if real_gfx else 'menu'
        gs = ['src/gfx.s', 'data/gfx_data.s'] if real_gfx else ['build/test_menu_gstub.s']
        r = subprocess.run([sys.executable, 'tools/buildtest.py', self.name, 'src/hw.s', 'src/snd.s',
                            'src/menu.s', vs] + gs, capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr)
            raise SystemExit(1)
        self.stubs = r.stdout.split('stubs:')[1].split('\n')[0].split() if 'stubs:' in r.stdout else []
        self.data = open('build/test_%s.bin' % self.name, 'rb').read()
        self.sym = {}
        for line in open('build/test_%s.lbl' % self.name):
            p = line.split()
            self.sym[p[2].lstrip('.')] = int(p[1], 16)
        self.reset()

    def reset(self):
        self.m = harness.Machine()
        self.m.ram[0x600:0x600 + len(self.data)] = self.data
        self.m.ram[0x5B00:0x5B00 + 8382] = open('data/zxram.bin', 'rb').read()
        self.mpu = MPU(memory=harness.Mem(self.m), pc=0)
        self.g = Gfx(self)
        self.m.aylog = []
        self.game = None
        self.rnd = random.Random(5)
        self.hooks = {}
        s = self.sym
        if not self.real_gfx:
            self.hooks[s['Z_A4C9']] = self.h_a4c9
            self.hooks[s['Z_A526']] = self.h_a526
            self.hooks[s['Z_A695']] = self.h_a695
            self.hooks[s['gfx_cls']] = self.h_a8eb
            self.hooks[s['gfx_attr_rows']] = self.h_rows
            self.hooks[s['gfx_recolour']] = self.h_recol
        self.hooks[s['Z_7347']] = self.h_7347
        self.hooks[s['rnd_r']] = lambda: setattr(self.mpu, 'a', self.rnd.randrange(128))
        self.call('hw_init')
        # the default key table in Oric codes (to be in data/zxram.bin)
        self.m.ram[0x7524:0x7524 + 21] = bytes([1, 1, 0, 7, 2, 0, 3, 1, 0, 6, 0x20, 0, 6, 0x40, 0, 2, 1, 0, 1, 2, 0])
        self.m.ram[0xBFDF] = 0x1E           # HIRES mode for the renderer
        if self.real_gfx:
            self.call('gfx_textinit')       # (main.s does this at start-up)
        self.keys = []          # (from_frame, to_frame, [keys])
        self.frame = 0

    def zp(self, n):
        return self.m.ram[self.sym[n] if isinstance(n, str) else n]

    def h_a4c9(self):
        mpu = self.mpu
        ret = self.pop() + 1
        hl = self.zp('zl') | self.zp('zh') << 8
        mpu.pc = self.g.stream(ret, hl)
        return True

    def h_a526(self):
        self.g.x, self.g.y = self.zp('zc'), self.zp('zb')

    def h_a695(self):
        self.g.put(self.mpu.a)

    def h_a8eb(self):
        self.g.text = {}
        self.g.cls = self.mpu.a
        self.g.log.append(('cls', self.mpu.a))

    def h_rows(self):
        self.g.attrs.append(('rows', self.mpu.a, self.mpu.x, self.mpu.y))

    def h_recol(self):
        self.g.attrs.append(('cols', self.mpu.a, self.mpu.x, self.mpu.y, self.zp('gfx_rc_row'), self.zp('gfx_rc_n')))

    def h_7347(self):
        self.g.log.append(('game', chr(self.mpu.a), chr(self.zp('zc'))))
        if self.game:
            self.game(self)

    def pop(self):
        mpu = self.mpu
        lo = self.m.ram[0x100 + ((mpu.sp + 1) & 0xFF)]
        hi = self.m.ram[0x100 + ((mpu.sp + 2) & 0xFF)]
        mpu.sp = (mpu.sp + 2) & 0xFF
        return lo | hi << 8

    def call(self, name, a=0, x=0, y=0, stops=(), maxframes=3000, irq=True, push=()):
        mpu, m = self.mpu, self.m
        mpu.sp = 0xFF
        mpu.stPushWord(STOP - 1)
        for w in push:
            mpu.stPushWord(w)
        mpu.pc = self.sym[name] if isinstance(name, str) else name
        mpu.a, mpu.x, mpu.y = a, x, y
        mpu.p = 0x20 | (0 if irq else mpu.INTERRUPT)
        stops = set(self.sym[s] if isinstance(s, str) else s for s in stops)
        start = m.cycles
        last_t = -1
        while mpu.pc != STOP and mpu.pc not in stops:
            h = self.hooks.get(mpu.pc)
            if h:
                if not h():
                    mpu.pc = self.pop() + 1
                continue
            mpu.step()
            m.cycles = mpu.processorCycles
            t = m.cycles // harness.T1_PERIOD
            if t != last_t:
                last_t = t
                self.frame = t
                m.pressed = set()
                for a0, b0, ks in getattr(self, 'keys', []):
                    if a0 <= t < b0:
                        m.pressed.update(harness.KEYMAP[k] for k in ks)
            if irq and (m.ier & 0x40) and m.t1_count() > m.t1_ack and not (mpu.p & mpu.INTERRUPT):
                m.t1_ack = m.t1_count()
                mpu.stPushWord(mpu.pc)
                mpu.stPush(mpu.p & ~mpu.BREAK | mpu.UNUSED)
                mpu.p |= mpu.INTERRUPT
                mpu.pc = m.ram[0xFFFE] | (m.ram[0xFFFF] << 8)
            if m.cycles - start > maxframes * harness.T1_PERIOD:
                raise RuntimeError('%s did not finish (pc=%04X)' % (name, mpu.pc))
        return mpu.pc

    def type_keys(self, seq, start=None, hold=4, gap=8):
        """schedule key presses: seq = list of key names (or 'A+B')"""
        t = (self.m.cycles // harness.T1_PERIOD + 3) if start is None else start
        self.keys = []
        for k in seq:
            self.keys.append((t, t + hold, k.split('+')))
            t += hold + gap
        return t


# ---------------------------------------------------------------------------
# Spectrum side
def zpoke(r, a, data):
    """Ref.poke is wrong above 0xC000 (zx's write() drops the offset inside
    the paged bank), so rewrite the whole 16K bank."""
    data = bytes(data)
    if a + len(data) <= 0xC000:
        return r.poke(a, data)
    bank = bytearray(r.peek(0xC000, 0x4000))
    bank[a - 0xC000:a - 0xC000 + len(data)] = data
    r.poke(0xC000, bank)


def zref():
    from zxref import Ref
    r = Ref()
    r.poke = lambda a, d, _r=r, _p=r.poke: zpoke_(_r, _p, a, d)
    return r


def zpoke_(r, raw, a, data):
    data = bytes(data)
    if a + len(data) <= 0xC000:
        return raw(a, data)
    bank = bytearray(r.peek(0xC000, 0x4000))
    bank[a - 0xC000:a - 0xC000 + len(data)] = data
    raw(0xC000, bank)


def zcall(r, pc, regs=None, stops=(), frames=5, keys=(), stack=()):
    """Run the original routine at pc; stops at a stop address or on return.
    keys = list of (frame, key) presses."""
    z = r.z
    r.poke(0x4000, [0x18, 0xFE])
    sp = 0x72F0
    words = [0x4000] + list(stack)
    for w in words:
        sp -= 2
        r.poke(sp, [w & 0xFF, w >> 8])
    z.sp = sp
    z.pc = pc
    for k, v in (regs or {}).items():
        setattr(z, k, v)
    z.iff1 = z.iff2 = 0
    hit = {}

    def bp():
        if 'pc' in hit:
            return
        hit['pc'] = z.pc
        hit['mem'] = r.mem()
        hit['regs'] = r.regs()
        z.pc = 0x4000
        z.iff1 = z.iff2 = 0
    z.on_breakpoint = bp
    for a in list(stops) + [0x4000]:
        z.set_breakpoint(a)
    f = 0
    ks = sorted(keys)
    while f < frames and 'pc' not in hit:
        for (kf, k) in ks:
            if kf == f:
                r.key(k, True)
            if kf + 4 == f:
                r.key(k, False)
        r.run(1)
        f += 1
    r.release()
    z.on_breakpoint = lambda: None
    return hit


ORIG_STREAMS = [(0xFD1D, 0xFD7C), (0xFA21, 0xFA90), (0xF876, 0xF88B), (0xF8D5, 0xF8E7),
                (0xF8F8, 0xF8FF), (0xFB26, 0xFB2C), (0xFB7A, 0xFB84), (0xFBE6, 0xFC4B)]


def t_streams(o):
    bad = 0
    for a, b in ORIG_STREAMS:
        ok = bytes(M[a:b]) in o.data
        bad += not ok
    print('  %d inline streams byte-identical to the original: %s' % (len(ORIG_STREAMS), 'ok' if not bad else '%d differ' % bad))
    return bad


def rand_table(rng):
    vals = sorted(rng.randrange(0, 3000) for _ in range(7))
    t = bytearray()
    t += b' LAST  ' + bytes([0x31 + rng.randrange(4)]) + rng.randrange(2000).to_bytes(2, 'little')
    for v in vals:
        name = bytes(rng.choice(b'ABCDEFGH ') for _ in range(7))
        t += name + bytes([0x31 + rng.randrange(4)]) + v.to_bytes(2, 'little')
    return t


def t_insert(o, r, n=150):
    rng = random.Random(1)
    bad = 0
    tab = o.sym['ZV_F757']
    for i in range(n):
        tables = rand_table(rng) + rand_table(rng)
        which = rng.randrange(2)
        e1 = tables[10 + 80 * which:]
        vals = [e1[k * 10 + 8] | e1[k * 10 + 9] << 8 for k in range(7)]
        hl = rng.choice([rng.randrange(0, 3200), rng.choice(vals), max(0, rng.choice(vals) - 1), 0, 65535])
        skill = 0x31 + rng.randrange(4)
        r.poke(0xF757, tables)
        r.poke(0xFA38, [skill])
        h = zcall(r, 0xF7F9, {'ix': 0xF761 + 80 * which, 'hl': hl})
        zres = h['mem'][0xF757:0xF7F7]
        zc = h['regs']['af'] & 1
        o.m.ram[tab:tab + 160] = tables
        o.m.ram[o.sym['ZV_FA38']] = skill
        ea = tab + 10 + 80 * which
        o.m.ram[o.sym['zixl']] = ea & 0xFF
        o.m.ram[o.sym['zixh']] = ea >> 8
        o.m.ram[o.sym['zl']] = hl & 0xFF
        o.m.ram[o.sym['zh']] = hl >> 8
        o.call('Z_F7F9', irq=False)
        ores = bytes(o.m.ram[tab:tab + 160])
        oc = o.mpu.p & 1
        if ores != zres or oc != zc:
            bad += 1
            if bad < 4:
                print('   diff case %d hl=%d table %d: C %d/%d' % (i, hl, which, zc, oc))
    print('  SF7F9 insert: %d random cases vs the Z80 routine, %d differ' % (n, bad))
    return bad


def t_record(o, r, n=40):
    """FACA after a game: SCORE - PENALTY recorded into the LAST entries and
    inserted; stops when the table display starts (F867) or at the menu."""
    rng = random.Random(2)
    bad = 0
    tab = o.sym['ZV_F757']
    for i in range(n):
        tables = rand_table(rng) + rand_table(rng)
        sc, pe = rng.randrange(0, 2500), rng.randrange(0, 2500)
        if i % 5 == 0:
            pe = 0
        skill = 0x31 + rng.randrange(4)
        r.poke(0xF757, tables)
        r.poke(0xFA38, [skill])
        r.poke(0x750B, list(sc.to_bytes(2, 'little') + pe.to_bytes(2, 'little')))
        h = zcall(r, 0xFACA, stops=(0xF867, 0xFA1B), stack=(0xFA1B,), frames=20)
        # (zx reports the breakpoint on the CALL F867 at F856)
        zpath = {0xF867: 'table', 0xF856: 'table', 0x4000: 'menu', 0xFA1B: 'menu'}.get(h.get('pc'), h.get('pc'))
        if zpath == 'table':
            zpath += '%02X' % (h['regs']['af'] >> 8)
        zres = h['mem'][0xF757:0xF7F7]
        o.m.ram[tab:tab + 160] = tables
        o.m.ram[o.sym['ZV_FA38']] = skill
        o.m.ram[0x750B:0x750F] = sc.to_bytes(2, 'little') + pe.to_bytes(2, 'little')
        pc = o.call('Z_FACA', stops=('Z_F867', 'Z_FA1B'), push=(o.sym['Z_FA1B'] - 1,), maxframes=50)
        opath = 'table%02X' % o.zp('zd2') if pc == o.sym['Z_F867'] else 'menu'
        ores = bytes(o.m.ram[tab:tab + 160])
        if ores != zres or opath != zpath:
            bad += 1
            if bad < 4:
                print('   diff case %d score %d penalty %d: %s/%s' % (i, sc, pe, zpath, opath))
    print('  FACA recording: %d random games vs the Z80 code, %d differ' % (n, bad))
    return bad


def t_city(o):
    from zxref import Ref
    bad = 0
    for k in range(4):
        r = zref()
        r.to_menu(str(k + 1))
        zm = r.mem()
        o.call('Z_FD91', a=k, irq=False)
        a, b = o.sym['ZV_9282'], o.sym['ZV_BACC']
        ok = bytes(o.m.ram[a:a + 0x153]) == zm[0x9282:0x93D5] and bytes(o.m.ram[b:b + 16]) == zm[0xBACC:0xBADC]
        print('  city %d: block D9282 (0x153) + title %r: %s' % (k + 1, bytes(o.m.ram[b:b + 16]).decode(), 'ok' if ok else 'DIFF'))
        bad += not ok
    return bad


def t_keys(o, r):
    seq = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U']
    o.type_keys(seq, start=o.frame + 20, hold=5, gap=10)
    pc = o.call('Z_FBD6', stops=('Z_F90B',), push=(o.sym['Z_FA1B'] - 1,), maxframes=400)
    names = [bytes(o.m.ram[o.sym['ZV_%04X' % (0xFBFB + 12 * i)]:][:2]).decode() for i in range(7)]
    table = list(o.m.ram[0x7524:0x7524 + 21])
    exp_t = []
    for k in seq:
        rr, c = harness.KEYMAP[k]
        exp_t += [rr, 1 << c, 0]
    # Spectrum: menu, option 2, then the same keys
    r2 = zref()
    r2.to_menu('1')
    r2.press('2', 20)
    r2.run(30)
    for k in seq:
        r2.press(k, 10)
        r2.run(10)
    zn = [bytes(r2.peek(0xFBFB + 12 * i, 2)).decode() for i in range(7)]
    ok = names == zn and table == exp_t and pc == o.sym['Z_F90B']
    blips = sum(1 for _, rg, v in o.m.aylog if rg == 9 and v == 13)
    print('  ALTER KEYS: names %s (Spectrum %s), Oric table %s: %s' % (names, zn, 'ok' if table == exp_t else table, 'ok' if ok else 'DIFF'))
    if VERBOSE:
        print(o.g.screen())
    return (not ok)


def t_skill(o, r):
    o.g.text = {}
    o.m.aylog = []
    o.m.ram[o.sym['ZV_FA38']] = 0x31
    o.type_keys(['7', 'RETURN', '3', 'RETURN'], start=o.frame + 5, hold=4, gap=10)
    pc = o.call('Z_FB23', stops=('Z_FA1E',), push=(o.sym['Z_FA1B'] - 1,), maxframes=300)
    sk = o.m.ram[o.sym['ZV_FA38']]
    beep = any(rg in (2, 3, 4, 5) and v == 33 for _, rg, v in o.m.aylog)
    r2 = zref()
    r2.to_menu('1')
    r2.press('1', 20)
    for k in ['7', 'ENTER', '3', 'ENTER']:
        r2.press(k, 10)
        r2.run(5)
    zs = r2.peek(0xFA38)[0]
    ok = sk == zs == 0x33 and beep and pc == o.sym['Z_FA1E'] and o.g.text.get((0xA0, 0xA8)) == '4'
    print('  ALTER SKILL: typed 7 (beep %s), then 3 -> skill %r (Spectrum %r): %s'
          % (beep, chr(sk), chr(zs), 'ok' if ok else 'DIFF'))
    return not ok


def t_name(o, r):
    """PLAY result inserted -> name entry with typing and DELETE."""
    rng = random.Random(3)
    tables = rand_table(rng) + rand_table(rng)
    seq = ['B', 'O', 'X', 'DEL', 'B', 'RETURN']
    zseq = ['B', 'O', 'X', 'CAPS SHIFT+0', 'B', 'ENTER']
    sc = 2900
    tab = o.sym['ZV_F757']
    o.m.ram[tab:tab + 160] = tables
    o.m.ram[o.sym['ZV_FA38']] = 0x32
    o.m.ram[0x750B:0x750F] = sc.to_bytes(2, 'little') + b'\0\0'
    o.type_keys(seq, start=o.frame + 10, hold=4, gap=10)
    o.g.text = {}
    pc = o.call('Z_FACA', stops=('Z_F8F5',), push=(o.sym['Z_FA1B'] - 1,), maxframes=600)
    ores = bytes(o.m.ram[tab:tab + 160])
    # Spectrum
    r.poke(0xF757, tables)
    r.poke(0xFA38, [0x32])
    r.poke(0x750B, list(sc.to_bytes(2, 'little')) + [0, 0])
    keys = []
    f = 15
    for k in zseq:
        keys.append((f, k))
        f += 14
    from zx._device import KeyStroke  # noqa: F401
    h = zcall_keys(r, 0xFACA, keys, stops=(0xF8F5,), stack=(0xFA1B,), frames=f + 40)
    zres = h['mem'][0xF757:0xF7F7] if h else b''
    ok = ores == zres and pc == o.sym['Z_F8F5']
    row = o.g.screen()
    print('  name entry (B O X DEL B ENTER, score %d0): entry %r: %s' % (sc, ores[70:77].decode('latin-1'), 'ok' if ok else 'DIFF'))
    if VERBOSE:
        print(row)
    return not ok


def zcall_keys(r, pc, keys, stops, stack, frames):
    """like zcall but with interrupts allowed (the music player/keyboard)."""
    z = r.z
    r.poke(0x4000, [0x18, 0xFE])
    sp = 0x72F0
    for w in [0x4000] + list(stack):
        sp -= 2
        r.poke(sp, [w & 0xFF, w >> 8])
    z.sp, z.pc = sp, pc
    hit = {}

    def bp():
        if 'pc' not in hit:
            hit['pc'] = z.pc
            hit['mem'] = r.mem()
    z.on_breakpoint = bp
    for a in list(stops):
        z.set_breakpoint(a)
    held = {}
    for f in range(frames):
        for kf, k in keys:
            parts = k.split('+')
            if kf == f:
                for p_ in parts:
                    r.key(p_, True)
            if kf + 4 == f:
                for p_ in parts:
                    r.key(p_, False)
        r.run(1)
        if 'pc' in hit:
            break
    r.release()
    z.on_breakpoint = lambda: None
    return hit


def t_screens(o):
    """menu / table screens as text, checked against the Spectrum layout."""
    bad = 0
    o.g.text = {}
    o.type_keys([], start=0)
    o.call('Z_FA1E', stops=('Z_FA90',), irq=False)
    menu = o.g.screen()
    exp = ['* TURBO ESPRIT MENU *', 'ALTER SKILL (1)', 'ALTER PLAYING KEYS', 'VIEW SCORE TABLE',
           'VIEW PENALTY TABLE', 'SAVE SCORE TABLES', 'LOAD SCORE TABLES', 'PRACTICE', 'PLAY', 'ENTER 1 TO 8']
    miss = [e for e in exp if e.replace(' ', '') not in menu.replace(' ', '')]
    print('  main menu text: %s' % ('ok' if not miss else 'missing %s' % miss))
    bad += len(miss)
    if VERBOSE:
        print(menu)
    o.g.text = {}
    tab = o.sym['ZV_F757']
    o.m.ram[tab:tab + 160] = M[0xF757:0xF7F7]
    o.call('Z_F85D', stops=('Z_F8FF',), push=(o.sym['Z_FA1B'] - 1,), irq=False)
    scr = o.g.screen()
    exp = ['* TURBO ESPRIT  SCORE TABLE *', 'NAME   SKILL  SCORE', 'DURELL    1        10', 'LAST    1        10']
    miss = [e for e in exp if e.replace(' ', '') not in scr.replace(' ', '')]
    attrs = o.g.attrs[-2:]
    ok_at = attrs == [('rows', 7, 4, 14), ('cols', 0x20, 4, 27, 48, 72)] and o.g.cls == 0x0F
    print('  score table text: %s, colours (cls 0F, rows 4-17 07, body 20): %s' % ('ok' if not miss else 'missing %s' % miss, 'ok' if ok_at else attrs))
    bad += len(miss) + (not ok_at)
    if VERBOSE:
        print(scr)
    return bad


def t_flow(o):
    """FD11 -> city 2 -> menu (music) -> 7 PRACTICE -> game start; and
    8 PLAY with the default skill."""
    o.type_keys(['2', '7'], start=o.frame + 10, hold=4, gap=40)
    pc = o.call('Z_FD11', stops=('Z_7347',), maxframes=200)
    st = (pc == o.sym['Z_7347'], chr(o.mpu.a), chr(o.zp('zc')), o.m.ram[0x7611], o.zp('music_busy'),
          bytes(o.m.ram[o.sym['ZV_BACC']:][:16]).decode(), list(o.m.ram[0x7524:0x7524 + 6]))
    tunes = sum(1 for _, rg, v in o.m.aylog if rg == 8 and v > 0)
    ok = st[:5] == (True, '1', '1', 0, 0) and st[5] == 'GAMESBOROUGH MAP' and st[6] == [1, 1, 0, 7, 2, 0] and tunes > 0
    print('  FD11 -> city 2 -> 7 PRACTICE: game(A=%r, C=%r) D7611=%d music stopped=%s title %r keys %s, menu music played: %s -> %s'
          % (st[1], st[2], st[3], st[4] == 0, st[5], st[6], tunes > 0, 'ok' if ok else 'FAIL'))
    return not ok


def t_render():
    """With the real gfx.s: draw the screens on the Oric HIRES screen and save
    PNGs (build/menu_shots/) for comparison with the Spectrum screenshots."""
    if not os.path.exists('src/gfx.s'):
        print('  (src/gfx.s not present: skipped)')
        return 0
    o = Oric(real_gfx=True)
    out = 'build/menu_shots'
    os.makedirs(out, exist_ok=True)

    def shot(name):
        w, h, img = harness.render(o.m.ram)
        harness.write_png(os.path.join(out, name + '.png'), w, h, img)
    o.call('Z_FD11', stops=('Z_FD7C',), maxframes=100)
    shot('city')
    o.type_keys(['3'], start=o.frame + 10)
    o.call('Z_FD7C', stops=('Z_FA90',), maxframes=200)
    shot('menu')
    o.keys = []
    o.call('Z_F85D', stops=('Z_F8FF',), push=(o.sym['Z_FA1B'] - 1,), maxframes=200)
    shot('score')
    o.call('Z_F84E', stops=('Z_F8FF',), push=(o.sym['Z_FA1B'] - 1,), maxframes=200)
    shot('penalty')
    o.type_keys(['Q', 'W', 'E'], start=o.frame + 20, hold=5, gap=10)
    try:
        o.call('Z_FBD6', maxframes=120, push=(o.sym['Z_FA1B'] - 1,))
    except RuntimeError:
        pass
    shot('keys')
    # name entry with the flashing cursor
    tab = o.sym['ZV_F757']
    o.m.ram[tab:tab + 160] = M[0xF757:0xF7F7]
    o.m.ram[0x750B:0x750F] = bytes([0x39, 5, 0, 0])
    o.type_keys(['A', 'B'], start=o.frame + 20, hold=4, gap=8)
    try:
        o.call('Z_FACA', maxframes=60, push=(o.sym['Z_FA1B'] - 1,))
    except RuntimeError:
        pass
    shot('name')
    print('  rendered city, menu, score, penalty, keys, name screens to %s/' % out)
    return 0


def main():
    o = Oric()
    print('stubs (other modules):', ' '.join(o.stubs))
    r = zref()
    bad = 0
    print('streams:')
    bad += t_streams(o)
    print('score tables:')
    bad += t_insert(o, r)
    bad += t_record(o, r)
    print('city select:')
    bad += t_city(o)
    print('keys / input:')
    o.reset()
    bad += t_keys(o, r)
    o.reset()
    bad += t_skill(o, r)
    o.reset()
    bad += t_name(o, zref())
    o.reset()
    bad += t_flow(o)
    print('screens:')
    o.reset()
    bad += t_screens(o)
    print('rendering (real gfx.s):')
    bad += t_render()
    print('RESULT: %s (%d failures)' % ('PASS' if not bad else 'FAIL', bad))
    return bad


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
