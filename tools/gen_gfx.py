#!/usr/bin/env python3
"""Generate the data of the graphics/text engine and the dashboard
(Spectrum 0x9E1E-0xAB46, module gfx/dash) from the original tape.

    python3 tools/gen_gfx.py [orig/TurboEsprit.tzx]

writes
  data/gfx_data.s     fonts (ROM 32-127 + custom AA2F), token table A98E,
                      GOSUB table A0BF + sub-streams A0EB-A36E (relocated,
                      ZLABEL $A23F for the needle parameters patched by
                      SA399/SA457), needle tables A3D6/A47B, the precomputed
                      static dashboard (Oric HIRES lines 100-195, LZ packed)
                      and the indicator-lamp recolour lists.
  data/gfx_streams.inc  macros with the inline command streams of the region
                      (STREAM_9FBF ...), used by src/dash.s after jsr Z_A4D6.

Engine: a Python model of the Spectrum A4C9/A4D6 engine (class Engine), the
same arithmetic as the Z80 code; tests/test_gfx.py uses it as the reference.
Needs the Spectrum 48K ROM (font) from the python `zx` package.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)
import zxtape   # noqa: E402
import oricenc  # noqa: E402

SUBS = 0xA0BF
TOKENS = 0xA98E
CUSTOM_FONT = 0xAA2F
ROM_FONT = 0x3C00
ZX2ORIC = [0, 4, 1, 5, 2, 6, 3, 7]


def load_rom():
    import zx
    return open(os.path.join(os.path.dirname(zx.__file__), 'roms', 'Spectrum48.rom'), 'rb').read()


def load_mem(tape=None):
    m = zxtape.load_image(tape or os.path.join(ROOT, 'orig', 'TurboEsprit.tzx'))
    m[0:0x4000] = load_rom()
    return m


# --------------------------------------------------------------------------
# Python model of the engine (verified against the emulator by R5)
def scr_addr(x, y):
    h = 0x40 | ((y >> 3) & 0x18) | (y & 7)
    l = ((y << 2) & 0xE0) | (x >> 3)
    return (h << 8) | l


def buf_addr(x, y):
    return (0x6400 + y * 32 + (x >> 3)) & 0xFFFF


class Engine:
    """State kept like the Z80 code. mem: 64K bytearray with ROM at 0."""

    def __init__(s, mem, rvals=None):
        s.m = mem
        s.rv = list(rvals) if rvals is not None else None
        s.rng = random.Random(1)
        s.x = s.y = 0
        s.addr = 0
        s.mask = 0x80
        s.taddr = 0
        s.tbit = 0
        s.mx = s.my = 0
        s.op = 'or'
        s.dither = False
        s.text = False
        s.screen = True
        s.font = ROM_FONT
        s.yoff = 0
        s.num = 0
        s.skipsub = ()
        s.nop8e = False     # tests: treat 8E as a no-op (original: call 0)

    def rnd(s):
        if s.rv is not None:
            return s.rv.pop(0) if s.rv else 0
        return s.rng.randrange(128)

    def down(s, a):
        if not s.screen:
            return (a + 32) & 0xFFFF
        h, l = a >> 8, a & 0xFF
        h2 = (h + 1) & 0xFF
        if (h ^ h2) & 8 == 0:
            return (h2 << 8) | l
        h &= 0xF8
        l += 0x20
        if l > 0xFF:
            l &= 0xFF
            h = (h + 8) & 0xFF
        return (h << 8) | l

    def up(s, a):
        if not s.screen:
            return (a - 32) & 0xFFFF
        h, l = a >> 8, a & 0xFF
        h2 = (h - 1) & 0xFF
        if (h ^ h2) & 8 == 0:
            return (h2 << 8) | l
        h |= 7
        l -= 0x20
        if l < 0:
            l &= 0xFF
            h = (h - 8) & 0xFF
        return (h << 8) | l

    def addr_of(s, x, y):
        return scr_addr(x, y) if s.screen else buf_addr(x, y)

    def plotop(s, a, mask):
        v = s.m[a]
        if s.op == 'or':
            v |= mask
        elif s.op == 'xor':
            v ^= mask
        else:
            v &= ~mask & 0xFF
        s.m[a] = v

    def moveto_plot(s, x, y):
        s.x, s.y = x & 0xFF, y & 0xFF
        s.addr = s.addr_of(s.x, s.y)
        s.mask = 0x80 >> (s.x & 7)
        s.plotop(s.addr, s.mask)

    def setpos(s, x, y):
        s.x, s.y = x & 0xFF, y & 0xFF
        s.taddr = s.addr_of(s.x, s.y)
        s.tbit = s.x & 7

    def line(s, dx, dy):
        a, c = s.addr, s.mask
        dxs = dx ^ s.mx
        xneg, adx = dxs & 0x80, dxs & 0x7F
        dys = dy ^ s.my
        yneg, ady = dys & 0x80, dys & 0x7F

        def xstep(a, c):
            if xneg:
                c2 = ((c << 1) | (c >> 7)) & 0xFF
                if c & 0x80:
                    a = (a & 0xFF00) | ((a - 1) & 0xFF)
            else:
                c2 = ((c >> 1) | (c << 7)) & 0xFF
                if c & 1:
                    a = (a & 0xFF00) | ((a + 1) & 0xFF)
            return a, c2

        def ystep(a, c):
            return (s.up(a) if yneg else s.down(a)), c
        if ady < adx:
            major, minor, mstep, nstep = adx, ady, xstep, ystep
        else:
            major, minor, mstep, nstep = ady, adx, ystep, xstep
        err = major >> 1
        for _ in range(major if major else 256):
            t = err + minor
            if t > 0xFF or t >= major:
                t = (t - major) & 0xFF
                a, c = nstep(a, c)
            err = t
            a, c = mstep(a, c)
            if s.dither:
                if (s.rnd() & 5) == 0:
                    s.m[a] |= c
            else:
                s.plotop(a, c)
        s.x = (s.x + (-adx if xneg else adx)) & 0xFF
        s.y = (s.y + (-ady if yneg else ady)) & 0xFF
        s.addr, s.mask = a, c

    def char(s, ch):
        f = (ch * 8 + s.font) & 0xFFFF
        s.x = (s.x + 8) & 0xFF
        a = s.taddr
        s.taddr = (a & 0xFF00) | ((a + 1) & 0xFF)

        def w(addr, v):
            if s.op == 'or':
                s.m[addr] |= v
            elif s.op == 'xor':
                s.m[addr] ^= v
            else:
                s.m[addr] = v
        for r in range(8):
            g = s.m[(f + r) & 0xFFFF]
            if s.tbit == 0:
                w(a, g)
                a = s.down(a) if s.screen else (a + 32) & 0xFFFF
            else:
                sh = (g << (8 - s.tbit)) & 0xFFFF
                w(a, sh >> 8)
                w((a & 0xFF00) | ((a + 1) & 0xFF), sh & 0xFF)
                a = s.down(a)

    def printc(s, ch):
        if ch < 0x80:
            s.char(ch)
            return
        n = ch & 0x7F
        p = TOKENS
        for _ in range(n if n else 256):
            p += 1
            while not s.m[p] & 0x80:
                p += 1
        p += 1
        while True:
            s.char(s.m[p] & 0x7F)
            if s.m[p] & 0x80:
                break
            p += 1

    def number(s, skip, e, hl=None):
        hl = s.num if hl is None else hl
        for i, d in enumerate((10000, 1000, 100, 10, 1)):
            if i * 6 < skip:
                continue
            dig, hl = (hl // d) & 0xFF, hl % d     # 8-bit digit counter (wraps)
            if dig == 0:
                if e & 0x80:
                    if e & 0x40:
                        continue
                    s.printc(e & 0x3F)
                    continue
                s.printc(0x30)
            else:
                e = 0
                s.printc((0x30 + dig) & 0xFF)

    def fill(s, a, c):
        m = s.m
        stack = [None, (a, c)]
        while True:
            it = stack.pop()
            if it is None:
                return
            a, c = it
            while True:
                carry = c & 0x80
                c = ((c << 1) | (c >> 7)) & 0xFF
                if carry:
                    while True:
                        a = (a & 0xFF00) | ((a - 1) & 0xFF)
                        if m[a]:
                            break
                if m[a] & c:
                    break
            la, lc, b = a, c, 0
            while True:
                carry = c & 1
                c = ((c >> 1) | (c << 7)) & 0xFF
                if carry:
                    while True:
                        a = (a & 0xFF00) | ((a + 1) & 0xFF)
                        if m[a]:
                            break
                        b = (b + 8) & 0xFF
                        m[a] = 0xFF
                if m[a] & c:
                    break
                m[a] |= c
                b = (b + 1) & 0xFF
            if b == 0:
                continue
            for step in (s.down, s.up):
                s._scan(step(la), lc, b, stack)

    def _scan(s, a, c, cnt, stack):
        m = s.m
        d, b = 1, cnt
        while True:
            carry = c & 1
            c = ((c >> 1) | (c << 7)) & 0xFF
            if carry:
                while True:
                    a = (a & 0xFF00) | ((a + 1) & 0xFF)
                    if (m[a] + d) & 0xFF:
                        break
                    b -= 8
                    if b <= 0:
                        return
            if m[a] & c:
                d = 1
            elif d & 1:
                stack.append((a, c))
                d = 0
            b = (b - 1) & 0xFF
            if b == 0:
                return

    def run(s, p):
        """Interpret the stream at p; returns the address after the 00."""
        stack = []
        m = s.m
        while True:
            a = m[p]
            p += 1
            if a == 0:
                return p
            if a & 0x80:
                cmd = a & 0x7F
                if cmd == 0x00:
                    n = m[p]
                    if (p - 1, n) in s.skipsub:
                        p += 1
                        continue
                    stack.append(p + 1)
                    p = m[SUBS + 2 * n] | (m[SUBS + 2 * n + 1] << 8)
                elif cmd == 0x01:
                    p = stack.pop()
                elif cmd == 0x02:
                    s.op, s.dither = 'or', False
                elif cmd == 0x03:
                    s.op, s.dither = 'andnot', False
                elif cmd == 0x04:
                    s.op, s.dither = 'xor', False
                elif cmd == 0x05:
                    dx, dy = m[p], m[p + 1]
                    p += 2
                    if s.mx:
                        dx = -dx
                    if s.my:
                        dy = -dy
                    x, y = (s.x + dx) & 0xFF, (s.y + dy) & 0xFF
                    s.mask = 0x80 >> (x & 7)     # SA672 also sets DA684
                    s.fill(s.addr_of(x, y), s.mask)
                elif cmd == 0x06:
                    s.dither = True
                elif cmd == 0x07:
                    x, y = m[p], m[p + 1]
                    p += 2
                    s.moveto_plot(x, (y + s.yoff) & 0xFF)
                elif cmd == 0x08:
                    dx, dy = m[p], m[p + 1]
                    p += 2
                    if s.mx:
                        dx = -dx
                    if s.my:
                        dy = -dy
                    s.moveto_plot((s.x + dx) & 0xFF, (s.y + dy + s.yoff) & 0xFF)
                elif cmd == 0x09:
                    s.mx ^= 0x80
                elif cmd == 0x0A:
                    s.my ^= 0x80
                elif cmd == 0x0B:
                    s.text = not s.text
                elif cmd == 0x0C:
                    s.screen = not s.screen
                elif cmd == 0x0D:
                    s.font = CUSTOM_FONT if s.font == ROM_FONT else ROM_FONT
                elif cmd == 0x0F:
                    attr = m[p]
                    p += 1
                    m[0x4000:0x5800] = bytes(0x1800)
                    m[0x5800:0x5B00] = bytes([attr]) * 0x300
                elif cmd == 0x0E and s.nop8e:
                    pass
                elif cmd == 0x10:
                    s.yoff = m[p]
                    p += 1
                else:
                    raise ValueError('bad cmd %02X at %04X' % (a, p - 1))
                continue
            if not s.text:
                for _ in range(a):
                    s.line(m[p], m[p + 1])
                    p += 2
            else:
                k = a
                while True:
                    ch = m[p]
                    p += 1
                    if ch < 0xFC:
                        s.printc(ch)
                        k -= 1
                        if k == 0:
                            break
                    elif ch == 0xFF:
                        s.setpos(m[p], m[p + 1])
                        p += 2
                    elif ch == 0xFE:
                        s.setpos((s.x + m[p]) & 0xFF, s.y)
                        p += 1
                    elif ch == 0xFD:
                        s.setpos(s.x, (s.y + m[p]) & 0xFF)
                        p += 1
                    else:
                        s.number(m[p], m[p + 1])
                        p += 2

    def entry_A4D6(s):
        s.screen, s.op, s.dither, s.text = False, 'or', False, False
        s.font, s.yoff, s.mx, s.my = ROM_FONT, 0, 0, 0

    def entry_A4C9(s, num):
        s.num = num
        s.screen, s.op, s.dither, s.text = True, 'andnot', False, True
        s.font, s.yoff, s.mx, s.my = ROM_FONT, 0, 0, 0


# needle parameter setters (SA399 / SA457) on the Spectrum memory
def sa399(m, a, b, ix):
    d, e = 0xFF, 0x00
    if 7 <= a < 0x0C:
        d, e = 0x00, 0x01
    t = 0xA3D6 + 4 * a
    m[ix + 4] = m[ix + 10] = m[t]
    m[ix + 5] = m[ix + 11] = m[t + 1]
    x = (m[t + 2] + b) & 0xFF
    m[ix + 1] = x
    m[ix + 7] = (x + e) & 0xFF
    y = (m[t + 3] + 0x60) & 0xFF
    m[ix + 2] = y
    m[ix + 8] = (y + d) & 0xFF


def sa457(m, a, b, ix):
    e = 0
    if a >= 6:
        a, e, b = (11 - a) & 0xFF, 0x80, b + 1
    t = 0xA47B + 2 * a
    m[ix + 1] = b & 0xFF
    m[ix + 4] = m[t] ^ e
    m[ix + 5] = m[t + 1]


def run_inline(m, addr, entry='A4D6', num=0, rvals=None):
    e = Engine(m, rvals)
    if entry == 'A4D6':
        e.entry_A4D6()
    else:
        e.entry_A4C9(num)
    return e, e.run(addr)


def dash_attrs(m):
    """The attribute code at 9F2B."""
    tbl, ix = 0x9F89, 0x59FF
    for cnt, attr in ((0x13, 0x0D), (4, 0x08), (0x0C, 0x50), (8, 0x58), (8, 0x60)):
        for _ in range(cnt):
            o = m[tbl]
            tbl += 1
            o = o - 256 if o > 127 else o
            m[ix + o] = attr
    for r in range(12):
        m[0x581C + 32 * r] = 0x0D
        m[0x581D + 32 * r] = 0x29
    m[0x5AC0:0x5AE0] = bytes([0x46]) * 32
    m[0x5AE0:0x5B00] = bytes([0x44]) * 32


def spec_pixel(m, x, y):
    return (m[scr_addr(x, y)] >> (7 - (x & 7))) & 1


def spec_colour(m, x, y):
    """Oric colour number of Spectrum pixel (x,y) (BRIGHT ignored)."""
    a = m[0x5800 + (y >> 3) * 32 + (x >> 3)]
    return ZX2ORIC[a & 7] if spec_pixel(m, x, y) else ZX2ORIC[(a >> 3) & 7]


# --------------------------------------------------------------------------
# Oric line encoder (DP over (ink, paper), with inverse pixel AND attribute
# bytes).  target: 240 colours or None (don't care).
#   need[c] = (ink, paper, bits): column c must be a pixel byte that shows
#             exactly these display colours with these bits (dynamic areas)
#   force[c] = byte
#   attr0: column 0 must be an attribute
def disp(byte, ink, paper):
    """-> (new ink, new paper, 6 displayed colours)"""
    inv = 7 if byte & 0x80 else 0
    if byte & 0x60 == 0:
        v = byte & 0x1F
        if v < 8:
            ink = v
        elif 16 <= v < 24:
            paper = v - 16
        return ink, paper, [paper ^ inv] * 6
    return ink, paper, [(ink if byte & (0x20 >> k) else paper) ^ inv for k in range(6)]


def encode_line(target, need=None, force=None, attr0=True, colours=None):
    need = need or {}
    force = force or {}
    INF = 1 << 40
    cols = sorted(set(colours or range(8)) | {0, 7})
    cost = {(7, 0): 0}
    back = []

    def err(shown, g):
        return sum(1 for a, b in zip(shown, g) if b is not None and a != b)
    for c in range(40):
        g = target[c * 6:c * 6 + 6]
        ncost, nback = {}, {}
        for (ink, paper), base in cost.items():
            cands = []
            if c in force:
                cands.append(force[c])
            elif c in need:
                nk, npp, bits = need[c]
                if (ink, paper) == (nk, npp):
                    cands.append(0x40 | bits)
                if (ink ^ 7, paper ^ 7) == (nk, npp):
                    cands.append(0xC0 | bits)
            else:
                if not (c == 0 and attr0):
                    for inv, ii, pp in ((0, ink, paper), (0x80, ink ^ 7, paper ^ 7)):
                        bits = 0
                        for k, p in enumerate(g):
                            if p is not None and p == ii and p != pp:
                                bits |= 0x20 >> k
                        cands.append(0x40 | inv | bits)
                for v in cols:
                    for inv in (0, 0x80):
                        if v != ink:
                            cands.append(inv | v)
                        if v != paper:
                            cands.append(inv | 16 | v)
                if c == 0 and attr0:
                    cands.append(16 | paper)
                    cands.append(0x80 | 16 | paper)
            for byte in cands:
                ni, np_, shown = disp(byte, ink, paper)
                tot = base + err(shown, g) * 16 + ((byte & 0x60) == 0) + ((byte & 0x80) != 0) * 0
                if c in need and (byte & 0x60) == 0:
                    continue
                key = (ni, np_)
                if tot < ncost.get(key, INF):
                    ncost[key] = tot
                    nback[key] = ((ink, paper), byte)
        back.append(nback)
        cost = ncost
        if not cost:
            raise ValueError('no encoding (column %d)' % c)
    st = min(cost, key=cost.get)
    best = cost[st]
    out = []
    for c in range(39, -1, -1):
        prev, byte = back[c][st]
        out.append(byte)
        st = prev
    return out[::-1], best >> 4


def decode_line(row):
    ink, paper = 7, 0
    out = []
    for b in row:
        ink, paper, shown = disp(b, ink, paper)
        out += shown
    return out


# --------------------------------------------------------------------------
class TrackMem(bytearray):
    """bytearray recording every write to the Spectrum bitmap"""

    def __init__(self, data):
        super().__init__(data)
        self.written = set()

    def __setitem__(self, i, v):
        if isinstance(i, int) and 0x4000 <= i < 0x5800:
            self.written.add(i)
        super().__setitem__(i, v)


def build_dashboard(img):
    """-> dict with the Spectrum memory of the static dashboard and the Oric
    encoding of lines 100..195 (Spectrum rows 96..191)."""
    m = bytearray(img)
    # static picture: the 9E21 stream without the needles (subs 9 and 10 at
    # 9ECC/9ECE) - they are drawn live by Z_9E1E with the current parameters
    e = Engine(m)
    e.entry_A4D6()
    e.skipsub = ((0x9ECC, 9), (0x9ECE, 10))
    end = e.run(0x9E21)
    assert end == 0x9F2B, hex(end)
    dash_attrs(m)
    final_state = (e.x, e.y)
    # dynamic pixels: wheel (both ways, draw+undraw), all needle positions,
    # gauge glyph redraw
    dyn = {}

    def mark(x, y):
        dyn.setdefault(y, set()).add((x + 6) // 6)

    def diffmark(a, b):
        for i in range(0x4000, 0x5800):
            if a[i] != b[i]:
                h, l = i >> 8, i & 0xFF
                y = ((h & 0x18) << 3) | (h & 7) | ((l & 0xE0) >> 2)
                x = (l & 0x1F) * 8
                for bit in range(8):
                    if (a[i] ^ b[i]) & (0x80 >> bit):
                        mark(x + bit, y)
    def writemark(t):
        for i in t.written:
            h, l = i >> 8, i & 0xFF
            y = ((h & 0x18) << 3) | (h & 7) | ((l & 0xE0) >> 2)
            x = (l & 0x1F) * 8
            for bit in range(8):
                mark(x + bit, y)
    for d in (3, 1):
        mm = TrackMem(m)
        run_inline(mm, 0x9FBF if d & 2 else 0xA002)
        writemark(mm)
        m2 = TrackMem(mm)
        run_inline(m2, 0xA046 if d & 2 else 0xA06C)
        writemark(m2)
    for a in range(18):
        mm = bytearray(m)
        sa399(mm, a, 0x64, 0xA23F)
        sa399(mm, a, 0x3C, 0xA24B)
        m2 = TrackMem(mm)
        run_inline(m2, 0xA373)
        writemark(m2)
    for a in range(12):
        mm = bytearray(m)
        sa457(mm, a, 0xAD, 0xA259)
        sa457(mm, a, 0x51, 0xA25F)
        m2 = TrackMem(mm)
        run_inline(m2, 0xA44E)
        writemark(m2)
        m3 = TrackMem(m2)
        run_inline(m3, 0xA421)
        writemark(m3)
    return m, dyn, final_state


LAMPS = {  # Spectrum attribute cells of the turn indicators: (row, col)
    'L': [(17, 4), (17, 5), (17, 6), (18, 5)],
    'R': [(17, 25), (17, 26), (17, 27), (18, 26)],
}


def target_line(m, y, lamp_off=()):
    t = [ZX2ORIC[(m[0x5800 + (y >> 3) * 32] >> 3) & 7]] * 6
    for x in range(234):
        c = spec_colour(m, x, y)
        for k in lamp_off:
            if (y >> 3, x >> 3) in LAMPS[k]:
                c = 0 if spec_pixel(m, x, y) else 0   # lamp off: black
        t.append(c)
    return t


def encode_dashboard(m, dyn):
    rows = []
    errs = 0
    for y in range(96, 176):
        t = target_line(m, y)
        need = {}
        if y in dyn:
            for c in sorted(dyn[y]):
                bits = 0
                for k in range(6):
                    x = c * 6 + k - 6
                    assert spec_colour(m, x, y) in (0, 6), (x, y)
                    if spec_pixel(m, x, y):
                        bits |= 0x20 >> k
                need[c] = (0, 6, bits)
        colours = set(v for v in t if v is not None)
        colours |= set(7 - v for v in colours)
        row, e = encode_line(t, need=need, colours=colours)
        errs += e
        rows.append(row)
    return rows, errs


def lamp_patches(m, rows, key):
    """XOR list [(line, col, xor)] switching lamp `key` from on to off."""
    cells = LAMPS[key]
    out = []
    for y in range(96, 176):
        if not any(r == y >> 3 for r, _ in cells):
            continue
        xs = [c * 8 for r, c in cells if r == y >> 3]
        lo = (min(xs) + 6) // 6 - 2
        hi = (max(xs) + 7 + 6) // 6 + 2
        on = rows[y - 96]
        force = {c: on[c] for c in range(40) if not lo <= c <= hi or on[c] & 0x60}
        t = target_line(m, y, lamp_off=(key,))
        colours = set(v for v in t if v is not None)
        colours |= set(7 - v for v in colours)
        off, e = encode_line(t, force=force, colours=colours)
        for c in range(40):
            if off[c] != on[c]:
                out.append((y + 4, c, on[c] ^ off[c]))
    return out


# --------------------------------------------------------------------------
def emit_bytes(out, vals, per=16):
    for i in range(0, len(vals), per):
        out.append('        .byte ' + ','.join('$%02X' % v for v in vals[i:i + per]))


def lz2_compress(data, short_min=2):
    """LZ with an optimal parse.  Tokens: 00llllll literal run 1-63;
    01llllll + d8: copy l+2 bytes from distance d8+1; 1lllllll + d16: copy
    l+3 bytes from distance d16; 0 = end."""
    n=len(data); 
    # optimal parse via DP over positions
    INF=1<<30
    best=[INF]*(n+1); best[n]=0; choice=[None]*(n+1)
    # precompute matches
    for i in range(n-1,-1,-1):
        # literal runs of length L (1..63)
        for L in range(1,min(63,n-i)+1):
            c=1+L+best[i+L]
            if c<best[i]: best[i]=c; choice[i]=('L',L)
        # matches
        maxlen={}
        for d in range(1,min(i,65535)+1):
            l=0
            while i+l<n and l<130 and data[i+l-d]==data[i+l]: l+=1
            if l>=2:
                if d<=256:
                    for L in range(short_min,min(l,65)+1):
                        c=2+best[i+L]
                        if c<best[i]: best[i]=c; choice[i]=('S',L,d)
                if l>=3:
                    for L in range(3,l+1):
                        c=3+best[i+L]
                        if c<best[i]: best[i]=c; choice[i]=('M',L,d)
            if d>600 and l<3: pass
    out=bytearray(); i=0
    while i<n:
        ch=choice[i]
        if ch[0]=='L': out.append(ch[1]); out+=data[i:i+ch[1]]; i+=ch[1]
        elif ch[0]=='S': out.append(0x40|(ch[1]-2)); out.append(ch[2]-1); i+=ch[1]
        else: out.append(0x80|(ch[1]-3)); out+=bytes([ch[2]&255,ch[2]>>8]); i+=ch[1]
    out.append(0)
    return bytes(out)
def lz2_decompress(c):
    out=bytearray(); i=0
    while True:
        t=c[i]; i+=1
        if t==0: return bytes(out)
        if t<0x40: out+=c[i:i+t]; i+=t
        elif t<0x80:
            L=(t&0x3F)+2; d=c[i]+1; i+=1
            for _ in range(L): out.append(out[-d])
        else:
            L=(t&0x7F)+3; d=c[i]|c[i+1]<<8; i+=2
            for _ in range(L): out.append(out[-d])

# chars of the ROM font that use pixel column 0 or 7 (or the ROM-code
# 'glyphs' 30/31 printed by sub-stream 21): kept as full 8-bit glyphs
FONT_EXC = (30, 31, 84, 89, 95, 127)


# sub-stream bytes read by the live streams (wheel, needles, gauges); found
# by tracing the model (see check_used_subs)
USED_SUBS = ((0xA17A, 0xA189), (0xA1C6, 0xA1DD), (0xA20A, 0xA22C), (0xA23E, 0xA265),
             (0xA292, 0xA36E))


def check_used_subs(img):
    reads = set()

    class R(bytearray):
        def __getitem__(s, i):
            if isinstance(i, int) and 0xA0EB <= i < 0xA36F:
                reads.add(i)
            return super().__getitem__(i)
    m, _, _ = build_dashboard(img)
    for d in (3, 1):
        mm = R(m)
        run_inline(mm, 0x9FBF if d & 2 else 0xA002)
        run_inline(mm, 0xA046 if d & 2 else 0xA06C)
    for a in (0xA373, 0xA394, 0xA421, 0xA44E):
        run_inline(R(m), a)
    assert all(any(l <= r <= h for l, h in USED_SUBS) for r in reads)


def gen(tape=None):
    img = load_mem(tape)
    rom = img[0:0x4000]
    out = ['; generated by tools/gen_gfx.py from the original tape - do not edit',
           '        .include "zx.inc"', '']
    # ---- the HIRES character set at $9800 (segment CHARSET) ----
    # $9800-$98FF (chars 0-31: serial attributes in the text rows, never
    # shown) holds small tables; chars 32-127 at $9900 are the Spectrum ROM
    # font, pixel columns 1-6 (also used by the engine, shifted left)
    for c in FONT_EXC[2:]:
        assert any(b & 0x81 for b in rom[0x3D00 + 8 * (c - 32):0x3D08 + 8 * (c - 32)])
    for c in range(32, 128):
        if c not in FONT_EXC:
            assert not any(b & 0x81 for b in rom[0x3D00 + 8 * (c - 32):0x3D08 + 8 * (c - 32)])
    out += ['        .segment "CHARSET"',
            '        .export T_FEXC, T_FEXCC, T_AA2F, T_A98E, T_A3D6, T_A47B',
            'cs_start:',
            '; full 8-bit glyphs of the ROM chars that use pixel column 0 or 7 (and',
            '; ROM codes 30/31, ROM code bytes printed by sub-stream 21)', 'T_FEXCC:']
    emit_bytes(out, list(FONT_EXC))
    out.append('T_FEXC:')
    for c in FONT_EXC:
        emit_bytes(out, rom[0x3C00 + 8 * c:0x3C08 + 8 * c])
    out += ['; token strings (entry n at the n-th bit-7 terminator after T_A98E)',
            'T_A98E = * - 1']
    emit_bytes(out, img[0xA98F:0xAA2F])
    out += ['; small gauge needle table DA47B (dx, dy) x 6', 'T_A47B:']
    emit_bytes(out, img[0xA47B:0xA487])
    out += ['        .res $100 - (* - cs_start)',
            '; $9900: ROM font chars 32-127, (byte >> 1) & $3F']
    emit_bytes(out, [(b >> 1) & 0x3F for b in rom[0x3D00:0x4000]])
    out += ['', '        .segment "RODATA"',
            '; custom font DAA2F: glyphs 11-22 only (00-10 are the dashboard pieces',
            '; and dial numerals of the precomputed picture)', 'T_AA2F = * - $11*8']
    emit_bytes(out, img[0xAA2F + 0x11 * 8:0xAB47])
    out += ['; dial needle table DA3D6 (dx, dy, xoff, yoff) x 18', 'T_A3D6:']
    emit_bytes(out, img[0xA3D6:0xA41E])
    # ---- GOSUB table and sub-streams (writable: SA399/SA457 patch them) ----
    subs = [img[SUBS + 2 * i] | (img[SUBS + 2 * i + 1] << 8) for i in range(22)]
    lo, hi = 0xA0EB, 0xA36F
    out += ['', '        .segment "DATA"', '        .export T_A0BF',
            '; GOSUB table DA0BF (22 sub-streams)', 'T_A0BF:']
    for a in subs:
        out.append('        .word L_%04X' % a)
    out.append('; sub-streams A0EB-A36E: only the parts the live streams use (the')
    out.append('; others belong to the precomputed 9E21 picture and point at L_RET)')
    labels = set(subs)
    for lo2, hi2 in USED_SUBS:
        p = lo2
        while p <= hi2:
            if p in labels:
                out.append('L_%04X:' % p)
            if p == 0xA23F:
                out.append('        ZLABEL $A23F, $26     ; needle parameters (SA399/SA457)')
            q = p + 1
            while q <= hi2 and q not in labels and q != 0xA23F:
                q += 1
            emit_bytes(out, img[p:q])
            p = q
    used_lab = set(a for a in subs if any(l <= a <= h for l, h in USED_SUBS))
    out.append('L_RET:  .byte $81')
    for a in sorted(set(subs) - used_lab):
        out.append('L_%04X = L_RET' % a)
    # ---- dashboard ----
    check_used_subs(img)
    m, dyn, final_state = build_dashboard(img)
    rows, errs = encode_dashboard(m, dyn)
    flat = [b for r in rows for b in r]
    delta = bytearray(flat)             # each byte xor the byte above
    for i in range(len(flat) - 1, 39, -1):
        delta[i] ^= flat[i - 40]
    comp = lz2_compress(bytes(delta))
    assert lz2_decompress(comp) == bytes(delta)
    out += ['', '        .segment "DASHBLOB"     ; loaded from disk at game start (src/disk.inc)',
            '        .export T_DASH, T_LAMPL, T_LAMPR, T_DASH_END',
            '; static dashboard: Oric HIRES lines 100-179 (3200 bytes), each byte',
            '; xor the byte above (line 100 plain), LZ packed',
            '; (00llllll: literals; 01llllll d8: copy l+2 from d8+1; 1lllllll d16: copy l+3 from d16; 0 end)',
            '; %d pixels differ from the Spectrum colours' % errs,
            'T_DASH:']
    emit_bytes(out, comp)
    out += ['T_DASH_END:', '        .segment "RODATA"']
    for key in ('L', 'R'):
        pl = lamp_patches(m, rows, key)
        out.append('; indicator lamp %s: (screen address, xor) - on <-> off, 0-terminated' % key)
        out.append('T_LAMP%s:' % key)
        for line, c, x in pl:
            out.append('        .word $%04X' % (0xA000 + line * 40 + c))
            out.append('        .byte $%02X' % x)
        out.append('        .word 0')
    with open(os.path.join(ROOT, 'data', 'gfx_data.s'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    # ---- inline streams ----
    inc = ['; generated by tools/gen_gfx.py - inline command streams (after jsr Z_A4D6)']
    for name, a, b in (('9FBF', 0x9FBF, 0x9FFE), ('A002', 0xA002, 0xA042),
                       ('A046', 0xA046, 0xA068), ('A06C', 0xA06C, 0xA092),
                       ('A373', 0xA373, 0xA377), ('A394', 0xA394, 0xA398),
                       ('A421', 0xA421, 0xA433), ('A44E', 0xA44E, 0xA452),
                       ('9E21', 0x9E21, 0x9F2B)):
        inc.append('.macro STREAM_%s' % name)
        emit_bytes(inc, img[a:b])
        inc.append('.endmacro')
    with open(os.path.join(ROOT, 'data', 'gfx_streams.inc'), 'w') as f:
        f.write('\n'.join(inc) + '\n')
    return dict(m=m, rows=rows, comp=comp, errs=errs, dyn=dyn, final=final_state)


if __name__ == '__main__':
    r = gen(sys.argv[1] if len(sys.argv) > 1 else None)
    print('dashboard: %d bytes packed, %d pixel errors, end cursor %s' % (len(r['comp']), r['errs'], r['final']))
