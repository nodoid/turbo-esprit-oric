#!/usr/bin/env python3
"""Tests for src/gfx.s + src/dash.s (Spectrum 9E1E-AB46, BA56-BB1E).

  1. buffer mode, bit-exact against the Python model of the engine
     (tools/gen_gfx.py Engine, verified against the emulator by R5): every
     stream of the region and synthetic streams (all commands, modes,
     mirrors, fills, dither with replayed R values, text, tokens, numbers).
  2. real game captures (zxref): SA36F, LA41E, SA094, SA496/SA487, BA5F,
     BAB8, map-view buffer printing (A526/A695/A911): variables bit-exact
     and, for screen output, the Oric screen converted back to Spectrum
     pixels compared with the Spectrum screen (every visible pixel byte).
  3. comparison PNGs (Spectrum | Oric) in $SP/work_gfx/.

run: python tests/test_gfx.py [--quick]
"""
import os
import random
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
os.chdir(ROOT)
import gen_gfx as G          # noqa: E402
from sim6502 import Sim, fmt_diffs  # noqa: E402

SP = os.environ.get('SP', 'build')
OUT = os.path.join(SP, 'work_gfx')
TRAMP = 0xC000          # (free in the test build; HIBSS is at $9Dxx)
QUICK = '--quick' in sys.argv

RESULTS = []


def result(name, ok, info=''):
    RESULTS.append((name, ok, info))
    print('%-44s %s %s' % (name, 'OK ' if ok else 'FAIL', info))


HOLES = []      # program segments placed in holes of the Spectrum RAM


def build():
    r = subprocess.run([sys.executable, 'tools/buildtest.py', 'gfx', 'src/gfx.s', 'src/dash.s', 'data/gfx_data.s'],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr)
        sys.exit(1)
    sim = Sim('build/test_gfx.bin')
    sim.mem[0x9900:0x9900 + 768] = OFONT       # left there by the ROM's HIRES
    # segments of ours inside $5B00-$7BBD (e.g. RODATAH1): the Spectrum state
    # copied in by load_state overwrites them, so they are restored after it
    import re
    for line in open('build/test_gfx.map'):
        mm = re.match(r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+[0-9A-F]{6}', line)
        if mm and not mm.group(1).startswith('ZXRAM') and mm.group(1) != 'DASHBLOB':
            a, b = int(mm.group(2), 16), int(mm.group(3), 16)
            if 0x5B00 <= a < 0x7BBE:
                HOLES.append((a, bytes(sim.mem[a:b + 1])))
    orig = sim.load_state

    def load_state(*args, **kw):
        orig(*args, **kw)
        for a, data in HOLES:
            sim.mem[a:a + len(data)] = data
    sim.load_state = load_state
    return sim


def restore_holes(sim):
    for a, data in HOLES:
        sim.mem[a:a + len(data)] = data


IMG = G.load_mem()
OFONT = G.load_oric_font()      # the model draws ROM-font text with the Oric font


def zx_state_to_sim(sim, m):
    """Copy the engine's Spectrum state (ZVARs of the region) from m."""
    for zxa, (oa, n) in sim.zvars.items():
        if 0x9E1E <= zxa < 0xAB47 or 0xBA56 <= zxa < 0xBB1F:
            sim.mem[oa:oa + n] = m[zxa:zxa + n]


def run_stream(sim, stream, entry='Z_A4D6', rvals=(), regs=None):
    code = bytes([0x20, sim.sym[entry] & 0xFF, sim.sym[entry] >> 8]) + bytes(stream) + bytes([0x60])
    sim.mem[TRAMP:TRAMP + len(code)] = code
    if regs:
        sim.set_regs(regs)
    sim.a = 0
    sim.carry = 0
    return sim.call(TRAMP, rvals=rvals, max_cycles=5_000_000)


# ---------------------------------------------------------------------------
def dash_linear():
    """the static dashboard bitmap as a linear 32-byte/row buffer image
    (0x6400 + y*32), so buffer-mode wheel/needle streams find their borders"""
    m, dyn, _ = G.build_dashboard(IMG)
    b = bytearray(0x2000)
    for y in range(192):
        for c in range(32):
            b[y * 32 + c] = m[G.scr_addr(c * 8, y)]
    return b


DASHLIN = None


def buffer_streams():
    """(name, bytes) - the region's streams with 8C replaced by 8E (stay in
    buffer mode) and the GOSUB sub-streams patched the same way."""
    m = IMG

    def strip(a, b):
        return bytes(0x8E if x == 0x8C else x for x in m[a:b])
    out = [('9FBF', strip(0x9FBF, 0x9FFE)), ('A002', strip(0xA002, 0xA042)),
           ('A046', strip(0xA046, 0xA068)), ('A06C', strip(0xA06C, 0xA092)),
           ('A373', strip(0xA373, 0xA377)), ('A421', strip(0xA421, 0xA433))]
    return out


def synth_streams(rng, n):
    """random streams exercising every command in buffer mode"""
    out = []
    for k in range(n):
        s = bytearray()
        text = False
        custom = False
        y0 = rng.randrange(8, 24)
        s += bytes([0x87, rng.randrange(40, 200), y0])
        for _ in range(rng.randrange(3, 12)):
            c = rng.choice(['line', 'line', 'move', 'rmove', 'op', 'mir', 'text', 'fill', 'dither',
                            'yoff', 'font'])
            if c == 'line' and not text:
                cnt = rng.randrange(1, 4)
                s.append(cnt)
                for _ in range(cnt):
                    # (no 0,0 segments: 256 steps that leave the screen, where
                    #  the Spectrum and Oric layouts wrap differently)
                    s += bytes([rng.randrange(1, 20) | rng.choice((0, 0x80)),
                                rng.randrange(0, 6) | rng.choice((0, 0x80))])
            elif c == 'move':
                s += bytes([0x87, rng.randrange(0, 256), rng.randrange(2, 28)])
            elif c == 'rmove':
                s += bytes([0x88, rng.randrange(-8, 9) & 0xFF, rng.randrange(-3, 4) & 0xFF])
            elif c == 'op':
                s.append(rng.choice((0x82, 0x83, 0x84)))
            elif c == 'mir':
                s.append(rng.choice((0x89, 0x8A)))
            elif c == 'dither':
                s.append(0x86)
            elif c == 'yoff':
                s += bytes([0x90, rng.randrange(0, 3)])
            elif c == 'font':
                s.append(0x8D)
                custom = not custom
            elif c == 'fill' and not text:
                # a closed box, then fill inside it
                x, y = rng.randrange(20, 200), rng.randrange(4, 20)
                w, h = rng.randrange(3, 30), rng.randrange(2, 6)
                s += bytes([0x82, 0x87, x, y, 4, w, 0, 0, h, 0x80 | w, 0, 0, 0x80 | h,
                            0x85, 1, 1])
            elif c == 'text':
                s.append(0x8B)
                text = not text
                if text:
                    items = []
                    s2 = bytearray([0xFF, rng.randrange(0, 240), rng.randrange(0, 20)])
                    for _ in range(rng.randrange(1, 6)):
                        r = rng.random()
                        if r < 0.15:
                            s2 += bytes([0xFE, rng.randrange(0, 24)])
                        elif r < 0.25:
                            s2 += bytes([0xFD, rng.randrange(0, 4)])
                        elif r < 0.35 and not custom:
                            s2 += bytes([0xFC, rng.choice((0, 6, 12, 18, 24)),
                                         rng.choice((0, 0x80 | 0x20, 0xC0))])
                        else:
                            items.append(1)
                            # (ROM font: 32-127 only; the original never prints
                            #  ROM codes < 32, which would show ROM code bytes;
                            #  custom font: 11-22, the glyphs kept on the Oric)
                            s2.append(rng.randrange(0x11, 0x23) if custom else
                                      rng.choice((rng.randrange(0x20, 0x80),
                                                  rng.randrange(0x81, 0x99))))
                    s2.append(0x12 if custom else 0x41)
                    items.append(1)
                    s.append(len(items))
                    s += s2
        if text:
            s.append(0x8B)
        s.append(0)
        out.append(bytes(s))
    return out


def copy_subs(sim, m):
    for lo, hi in G.USED_SUBS:
        oa = sim.sym['L_%04X' % lo]
        sim.mem[oa:oa + hi + 1 - lo] = m[lo:hi + 1]


def test_buffer(sim):
    global DASHLIN
    DASHLIN = dash_linear()
    rng = random.Random(5)
    skipped = 0
    # (the region's wheel/needle streams reach Spectrum rows 96-191, i.e.
    #  $7000-$7BFF in buffer mode, where the Oric program keeps tables in
    #  holes of the Spectrum RAM; the game only uses buffer mode for the map,
    #  inside the 3D buffer.  They are tested in screen mode instead.)
    streams = [('syn%d' % i, s) for i, s in enumerate(synth_streams(rng, 30 if QUICK else 300))]
    bad = 0
    for name, st in streams:
        st = bytes(st)
        if st[-1] != 0:
            st = st + b'\x00'
        # model
        m = bytearray(IMG)
        m[0x6400:0x7000] = bytes(0xC00)
        # sub-streams with 8C -> 8E (model and sim)
        for a in range(0xA0EB, 0xA36F):
            if m[a] == 0x8C:
                m[a] = 0x8E
        m[0x9D80:0x9D80 + len(st)] = st
        rv = [rng.randrange(128) for _ in range(3000)]
        e = G.Engine(m, list(rv))
        e.entry_A4D6()
        # (with a digit skip, values >= 10^digits print ROM codes < 32 -
        #  garbage that the original never shows; keep those small)
        skips = any(st[i] == 0xFC and st[i + 1] for i in range(len(st) - 1))
        num = rng.randrange(100) if skips else rng.randrange(65536)
        e.num = num
        e.nop8e = True
        e.run(0x9D80)
        if m[0x7000:0x9D80] != IMG[0x7000:0x9D80] or m[0x5B00:0x6400] != IMG[0x5B00:0x6400]:
            skipped += 1        # drew outside the 3D buffer (Oric tables live there)
            continue
        # sim
        sim.mem[0x6400:0x7000] = bytes(0xC00)
        restore_holes(sim)
        # sub-streams (only the parts in the Oric data)
        copy_subs(sim, m)
        sim.mem[sim.sym['ZV_A4C3']] = num & 0xFF
        sim.mem[sim.sym['ZV_A4C3'] + 1] = num >> 8
        run_stream(sim, st, rvals=rv)
        d = [a for a in range(0x6400, 0x7000) if sim.mem[a] != m[a]]
        restore_holes(sim)
        st_ok = (sim.mem[sim.sym['ZV_A691']] == e.x and sim.mem[sim.sym['ZV_A691'] + 1] == e.y)
        if d or not st_ok:
            bad += 1
            if bad < 4:
                print('  %s: %d byte diffs %s, xy %02X,%02X vs %02X,%02X' % (
                    name, len(d), ' '.join('%04X:%02X/%02X' % (a, m[a], sim.mem[a]) for a in d[:8]),
                    e.x, e.y, sim.mem[sim.sym['ZV_A691']], sim.mem[sim.sym['ZV_A691'] + 1]))
    copy_subs(sim, IMG)                       # undo the 8C->8E patch
    result('buffer mode streams vs model', bad == 0, '%d streams (%d skipped: drew outside $6400-$6FFF), %d bad'
           % (len(streams) - skipped, skipped, bad))


# ---------------------------------------------------------------------------
# screen mode
LINE0 = 100                     # Oric line of Spectrum row 96
ROWS = range(96, 176)           # dashboard rows on the HIRES screen


def lineaddr(y):
    return 0xA000 + (y + 4) * 40


def oric_bits(mem):
    """{(x, y): bit} for every visible Spectrum pixel of the dashboard that
    sits in an Oric pixel byte"""
    out = {}
    for y in ROWS:
        la = lineaddr(y)
        for c in range(1, 40):
            b = mem[la + c]
            if not b & 0x40:
                continue
            for k in range(6):
                x = c * 6 + k - 6
                if x < 234:
                    out[(x, y)] = (b >> (5 - k)) & 1
    return out


def spec_to_oric(mem, zxm):
    """write the Spectrum dashboard pixels of zxm into the Oric pixel bytes"""
    db = dynbytes()
    for y in ROWS:
        la = lineaddr(y)
        for c in range(1, 40):
            b = mem[la + c]
            if not b & 0x40 or la + c not in db:
                continue
            bits = 0
            for k in range(6):
                x = c * 6 + k - 6
                if x < 234 and G.spec_pixel(zxm, x, y):
                    bits |= 0x20 >> k
            mem[la + c] = (b & 0xC0) | bits ^ (0x3F if inverted(mem, la, c) else 0)


LAMPBYTES = set()
_DYN = None


def dynbytes():
    """Oric bytes of the dynamic dashboard areas (pixel bits = Spectrum ink
    there; elsewhere bits may encode colour clashes)"""
    global _DYN
    if _DYN is None:
        _, dyn, _ = G.build_dashboard(IMG)
        # (c < 0: -1-c, a cell only the XOR needles touch: either polarity)
        _DYN = set(lineaddr(y) + (c if c >= 0 else -1 - c) for y, cols in dyn.items() for c in cols)
        DYN_XOR.update(lineaddr(y) - 1 - c for y, cols in dyn.items() for c in cols if c < 0)
    return _DYN


DYN_XOR = set()     # cells only the XOR needles touch (encoded either polarity)


def inverted(mem, la, c):
    """True if a set bit of the pixel byte at column c of the line at la
    shows cyan (needle-only cells may be encoded with paper black / ink
    cyan; XOR drawing looks the same either way)"""
    ink, paper = 7, 0
    for k in range(c):
        ink, paper, _ = G.disp(mem[la + k], ink, paper)
    inv = 7 if mem[la + c] & 0x80 else 0
    return (ink ^ inv) == 6 and (paper ^ inv) == 0


def bitdiff(mem, zxm, allbytes=False):
    db = dynbytes()
    out = []
    pol = {}
    for (x, y), b in oric_bits(mem).items():
        a = lineaddr(y) + (x + 6) // 6
        if a in LAMPBYTES or not (allbytes or a in db):
            continue
        if a not in pol:
            pol[a] = inverted(mem, lineaddr(y), (x + 6) // 6)
            if pol[a] and a not in DYN_XOR:
                pol[a] = None   # live cell near a lamp, reversed by design
                #                 (tools/gen_gfx.py): the wheel shows inverted
        if pol[a] is None:
            continue
        if (b ^ pol[a]) != G.spec_pixel(zxm, x, y):
            out.append((x, y))
    return out


def setup_screen(sim):
    m = sim.mem
    for a in range(0xBF68, 0xBFDF):
        m[a] = 0x20
    m[0xBFDF] = 0x1E
    m[sim.sym['ZV_9494']] = 0
    m[sim.sym['ZV_9495']] = 11
    m[sim.sym['ZV_E968']] = 0
    sim.a = 0
    sim.carry = 0
    # the packed dashboard is a disk blob (src/disk.inc): DREAD -> RTS and
    # the blob put at its load address, as the boot/disk code would
    m[0x0530] = 0x60
    blob = open('build/test_gfx.bin.dash', 'rb').read()
    m[0x6900:0x6900 + len(blob)] = blob
    cyc = sim.call('Z_9E1E')
    return cyc


def test_dash_model(sim):
    """Z_9E1E + Z_A41E + Z_A36F(0) vs the Python model of the original"""
    cyc = setup_screen(sim)
    sim.call('Z_A41E')
    sim.call('Z_A36F', a=0)
    m, dyn, _ = G.build_dashboard(IMG)
    st = bytes([0x8C, 0x80, 0x09, 0x80, 0x0A, 0x00])
    m[0x9D80:0x9D86] = st
    G.run_inline(m, 0x9D80)
    m[0x9494], m[0x9495], m[0xE968] = 0, 11, 0
    G.run_inline(m, 0xA421)
    G.sa457(m, m[0x9494], 0xAD, 0xA259)
    G.sa457(m, m[0x9495], 0x51, 0xA25F)
    G.run_inline(m, 0xA44E)
    G.run_inline(m, 0xA373)
    G.sa399(m, 0, 0x64, 0xA23F)
    G.sa399(m, 1, 0x3C, 0xA24B)
    G.run_inline(m, 0xA394)
    d = bitdiff(sim.mem, m)
    n = len([1 for (x, y) in oric_bits(sim.mem) if lineaddr(y) + (x + 6) // 6 in dynbytes()])
    da = bitdiff(sim.mem, m, True)
    print('  (all pixel bytes incl. colour-clash areas: %d of %d differ)' % (len(da), len(oric_bits(sim.mem))))
    pv = sim.mem[sim.sym['ZV_A23F']:sim.sym['ZV_A23F'] + 0x26] == m[0xA23F:0xA265]
    result('dashboard+needles vs model (pixels)', not d and pv,
           '%d pixels compared, %d differ; params %s; 9E1E %d cycles' % (n, len(d), 'ok' if pv else 'DIFF', cyc))
    save_cmp(sim.mem, m, 'dash_model')
    return m


def test_menus(sim):
    """A4C9 streams of other modules (menu screens: 8F CLS + text) in screen
    mode: every HIRES pixel of Spectrum rows 0-175 vs the model, text rows"""
    rom = IMG[0:0x4000]
    for addr in (0x73DA, 0x73EB, 0xF876, 0xFA21, 0xFD1D, 0xF35F, 0xF8F8):
        m = bytearray(IMG)
        m[0x4000:0x5800] = bytes(0x1800)
        e = G.Engine(m)
        e.entry_A4C9(0)
        end = e.run(addr)
        st = bytes(IMG[addr:end])
        for a in range(0xA000, 0xBF40):
            sim.mem[a] = 0x40
        sim.mem[0xBFDF] = 0x1E
        sim.set_regs({'hl': 0})
        run_stream(sim, st, entry='Z_A4C9')
        bad = 0
        n = 0
        for y in range(0, 176):
            la = lineaddr(y)
            for c in range(1, 40):
                b = sim.mem[la + c]
                if not b & 0x40:
                    continue
                for k in range(6):
                    x = c * 6 + k - 6
                    if x < 234:
                        n += 1
                        bad += ((b >> (5 - k)) & 1) != G.spec_pixel(m, x, y)
        td = sum(1 for a, b in zip(sum(text_rows_from_spec(m, rom, True), []), sum(text_rows_oric(sim.mem), []))
                 if a != b and a != 0x20)
        result('A4C9 stream %04X (menu text)' % addr, bad == 0 and td == 0,
               '%d pixels, %d differ; text rows %d differ' % (n, bad, td))
        save_cmp(sim.mem, m, 'menu_%04X' % addr)


def test_squeeze(sim):
    """gfx_squeeze = 1 (text-page mode): menu streams; every glyph must be
    its full 8-pixel bitmap at Oric x = ((x*7)>>3) + 6 (later glyphs
    overwrite / OR the earlier ones, like the engine's op)"""
    sq = sim.sym['gfx_squeeze']
    for addr in (0xFA21, 0xFD1D, 0x73DA):
        m = bytearray(IMG)
        m[0x4000:0x5800] = bytes(0x1800)
        e = G.Engine(m)
        e.entry_A4C9(0)
        placed = []
        orig = G.Engine.char

        def char(s_, ch, placed=placed):
            if s_.screen and s_.y < 176:
                if s_.font == G.ROM_FONT and 32 <= ch < 128:
                    rows = [(OFONT[(ch - 32) * 8 + r] << 1) & 0xFF for r in range(8)]
                else:
                    rows = [m[(s_.font + ch * 8 + r) & 0xFFFF] for r in range(8)]
                placed.append((s_.x, s_.y, rows, s_.op))
            orig(s_, ch)
        G.Engine.char = char
        try:
            end = e.run(addr)
        finally:
            G.Engine.char = orig
        exp = {}
        for x, y, rows, op in placed:
            p0 = ((x * 7) >> 3) + 6
            for r, g in enumerate(rows):
                for k in range(8):
                    b = (g >> (7 - k)) & 1
                    key = (p0 + k, y + r)
                    if op == 'or':
                        exp[key] = exp.get(key, 0) | b
                    elif op == 'xor':
                        exp[key] = exp.get(key, 0) ^ b
                    else:
                        exp[key] = b
        for a in range(0xA000, 0xBF40):
            sim.mem[a] = 0x40
        sim.mem[0xBFDF] = 0x1E
        blob = open('build/test_gfx.bin.menu', 'rb').read()     # MCODE (menu blob)
        sim.mem[0x5C00:0x5C00 + len(blob)] = blob
        sim.mem[sq] = 1
        run_stream(sim, bytes(IMG[addr:end]), entry='Z_A4C9')
        sim.mem[sq] = 0
        bad = n = 0
        for y in range(176):
            la = lineaddr(y)
            for c in range(1, 40):
                b = sim.mem[la + c]
                if not b & 0x40:
                    continue
                for k in range(6):
                    n += 1
                    bad += ((b >> (5 - k)) & 1) != exp.get((c * 6 + k, y), 0)
        result('text-page mode (gfx_squeeze=1) %04X' % addr, bad == 0,
               '%d pixels, %d differ, %d glyphs' % (n, bad, len(placed)))
        save_cmp(sim.mem, m, 'squeeze_%04X' % addr)


def test_screen_synth(sim):
    """synthetic streams in screen mode (after 8F 38: inverse-video pixel
    bytes) vs the model: every visible pixel of rows 0-175; streams whose
    model output reaches x >= 234 (cut on the Oric) are skipped"""
    rng = random.Random(11)
    n = bad = skipped = 0
    for st in synth_streams(rng, 20 if QUICK else 150):
        st = bytes([0x8F, 0x38, 0x8C]) + st
        m = bytearray(IMG)
        m[0x9D80:0x9D80 + len(st)] = st
        rv = [rng.randrange(128) for _ in range(3000)]
        e = G.Engine(m, list(rv))
        e.entry_A4D6()
        e.nop8e = True
        num = rng.randrange(100)
        e.num = num
        e.run(0x9D80)
        if any(G.spec_pixel(m, x, y) for y in range(176) for x in range(234, 256)):
            skipped += 1
            continue
        sim.mem[sim.sym['ZV_A4C3']] = num
        sim.mem[sim.sym['ZV_A4C3'] + 1] = 0
        run_stream(sim, st, rvals=rv)
        n += 1
        d = 0
        for y in range(176):
            la = lineaddr(y)
            for c in range(1, 40):
                b = sim.mem[la + c]
                if not b & 0x40:
                    d += 1
                    continue
                if not b & 0x80:
                    d += 1          # bit 7 (inverse video) must be kept
                for k in range(6):
                    x = c * 6 + k - 6
                    if x < 234:
                        d += ((b >> (5 - k)) & 1) != G.spec_pixel(m, x, y)
        if d:
            bad += 1
            if bad <= 3:
                print('  screen synth: %d diffs, stream %s' % (d, st.hex()))
                save_cmp(sim.mem, m, 'synth_bad_%d' % bad)
    result('screen mode synthetic streams vs model', bad == 0,
           '%d streams (%d skipped: x>=234), %d bad' % (n, skipped, bad))


def text_rows_from_spec(zxm, rom, oric=False):
    """decode Spectrum char rows 22, 23 into character codes (glyph shapes of
    the Spectrum ROM font, or with oric=True of the Oric font as the model
    draws it)"""
    if oric:
        glyphs = {bytes((OFONT[8 * (c - 32) + k] << 1) & 0xFF for k in range(8)): c for c in range(32, 128)}
    else:
        glyphs = {bytes(rom[0x3D00 + 8 * (c - 32):0x3D00 + 8 * (c - 31)]): c for c in range(32, 128)}
    rows = []
    for r in (22, 23):
        row = []
        for c in range(32):
            g = bytes(zxm[G.scr_addr(c * 8, r * 8 + k)] for k in range(8))
            row.append(glyphs.get(g, 0x3F if any(g) else 0x20))
        rows.append(row)
    return rows


def text_rows_oric(mem):
    return [[mem[0xBF68 + r * 40 + 4 + c] for c in range(32)] for r in (0, 1)]


IGNORE_ZV = {0xA683, 0xA684, 0xA685, 0xA686, 0xA687, 0xA688}   # Oric representation in screen mode


def oric_expected(smp, entry):
    """the Spectrum's post state, with the buffer drawn by the model from the
    pre state using the Oric font for ROM-font text (the port's font)"""
    m = bytearray(smp.pre_mem)
    e = G.Engine(m)
    e.screen = m[0xA6D7] != 0
    e.op = {0x00: 'andnot', 0xB6: 'or', 0xAE: 'xor'}[m[0xA6E0]]
    e.font = m[0xA6BC] | m[0xA6BD] << 8
    e.x, e.y = m[0xA691], m[0xA692]
    e.taddr = m[0xA687] | m[0xA688] << 8
    e.tbit = m[0xA683]
    a = smp.pre['af'] >> 8
    if entry == 0xA695:
        e.printc(a)
    else:
        e.number(a, smp.pre['de'] & 0xFF, smp.pre['hl'])
    post = bytearray(smp.post_mem)
    post[0x6400:0x7040] = m[0x6400:0x7040]      # (the 3D buffer)
    return bytes(post)


def test_samples(sim, caps):
    tmpl = None
    setup_screen(sim)
    tmpl = bytes(sim.mem[0xA000:0xBFE0])
    lamp_bytes(sim)
    lampshow = sim.sym['lampshow']
    rom = IMG[0:0x4000]
    stats = {}
    shots = 0
    for city, cap in caps:
        for entry, samples in sorted(cap.items()):
            for i, smp in enumerate(samples):
                name = '%04X' % entry
                screen = smp.pre_mem[0xA6D7] == 0x11
                if entry in (0xA526, 0xA695, 0xA911) and screen:
                    name += 's'
                sim.mem[0xA000:0xBFE0] = tmpl
                sim.load_state(smp.pre_mem, smp.pre)
                # Oric screen = the Spectrum screen of the pre state
                spec_to_oric(sim.mem, smp.pre_mem)
                for k, za in ((0, 0x5A24), (1, 0x5A39)):
                    sim.mem[lampshow + k] = 0x40
                    if not smp.pre_mem[za] & 0x40:
                        lamp_toggle(sim, k)
                for r, row in enumerate(text_rows_from_spec(smp.pre_mem, rom)):
                    for c, ch in enumerate(row):
                        sim.mem[0xBF68 + r * 40 + 4 + c] = ch
                if entry in (0xBA5F,):
                    # inline data: copy the caller's data into the trampoline
                    ret = smp.pre_mem[smp.pre['sp']] | smp.pre_mem[smp.pre['sp'] + 1] << 8
                    import cap_gfx
                    end = cap_gfx.inline_end(smp.pre_mem, ret)
                    code = bytes([0x20, sim.sym['Z_BA5F'] & 0xFF, sim.sym['Z_BA5F'] >> 8]) + \
                        bytes(smp.pre_mem[ret:end]) + bytes([0x60])
                    sim.mem[TRAMP:TRAMP + len(code)] = code
                    sim.call(TRAMP, a=smp.pre['af'] >> 8)
                else:
                    sim.call('Z_%04X' % entry, a=smp.pre['af'] >> 8, rvals=smp.rvals)
                ign = set(IGNORE_ZV) if screen or entry not in (0xA526, 0xA695, 0xA911) else set()
                sp = smp.pre['sp']
                post = smp.post_mem
                if entry in (0xA695, 0xA911) and not screen:
                    post = oric_expected(smp, entry)
                d = [x for x in sim.compare(post, ignore=((sp - 0x40, sp + 2),) + tuple((h, h + len(d)) for h, d in HOLES))
                     if x[0] not in ign]
                bd = bitdiff(sim.mem, smp.post_mem) if entry not in (0xA526, 0xA695, 0xA911) or screen else []
                td = []
                if entry in (0xBA5F, 0xBAB8, 0xBB18) or (screen and entry in (0xA695, 0xA911)):
                    td = [1 for a, b in zip(sum(text_rows_from_spec(smp.post_mem, rom), []),
                                            sum(text_rows_oric(sim.mem), [])) if a != b]
                st = stats.setdefault(name, [0, 0])
                st[0] += 1
                if d or bd or td:
                    st[1] += 1
                    if st[1] <= 2:
                        print('  %s city %s #%d: %d var diffs %s; %d pixel diffs %s; %d text diffs' % (
                            name, city, i, len(d), fmt_diffs(d, 6), len(bd), bd[:5], len(td)))
                if entry in (0xA094, 0xA36F, 0xBA5F) and shots < 6 and i < 2:
                    shots += 1
                    save_cmp(sim.mem, smp.post_mem, 'sample_%s_%s_%d' % (name, city, i))
    for name, (n, bad) in sorted(stats.items()):
        result('real game %s' % name, bad == 0, '%d samples, %d bad' % (n, bad))


def lamp_bytes(sim):
    for k in ('T_LAMPL', 'T_LAMPR'):
        a = sim.sym[k]
        while sim.mem[a + 1]:
            LAMPBYTES.add(sim.mem[a] | sim.mem[a + 1] << 8)
            a += 3


def lamp_toggle(sim, k):
    """apply the T_LAMPL/R xor list (as Z_A49B does)"""
    a = sim.sym['T_LAMPL' if k == 0 else 'T_LAMPR']
    m = sim.mem
    while True:
        ad = m[a] | m[a + 1] << 8
        if not m[a + 1]:
            break
        m[ad] ^= m[a + 2]
        a += 3
    sim.mem[sim.sym['lampshow'] + k] ^= 0x40


def save_cmp(mem, zxm, name):
    """PNG: Spectrum screen (left) | Oric screen (right)"""
    from PIL import Image
    import harness as H
    pal = [(0, 0, 0), (0, 0, 205), (205, 0, 0), (205, 0, 205), (0, 205, 0), (0, 205, 205),
           (205, 205, 0), (205, 205, 205)]
    palb = [(0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255), (0, 255, 0), (0, 255, 255),
            (255, 255, 0), (255, 255, 255)]
    im = Image.new('RGB', (256 + 16 + 240, 224))
    px = im.load()
    for y in range(192):
        for cx in range(32):
            b = zxm[G.scr_addr(cx * 8, y)]
            a = zxm[0x5800 + (y >> 3) * 32 + cx]
            p = palb if a & 64 else pal
            for bit in range(8):
                px[cx * 8 + bit, y + 4] = p[a & 7] if b & (0x80 >> bit) else p[(a >> 3) & 7]
    ram = bytearray(mem)
    ram[0xBFDF] = 0x1E
    w, h, rgb = H.render(ram)
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            px[272 + x, y] = tuple(rgb[o:o + 3])
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    im.save(os.path.join(OUT, name + '.png'))


# ---------------------------------------------------------------------------
if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    sim = build()
    if '--nobuf' not in sys.argv:
        test_buffer(sim)
    test_dash_model(sim)
    test_menus(sim)
    test_screen_synth(sim)
    test_squeeze(sim)
    import pickle
    caps = []
    for c in '1234':
        f = os.path.join(OUT, 'cap_%s.pkl' % c)
        if os.path.exists(f):
            caps.append((c, pickle.load(open(f, 'rb'))))
    if caps:
        test_samples(sim, caps)
    else:
        print('no captures: run tests/cap_gfx.py CITY %s/cap_CITY.pkl first' % OUT)
    ok = all(r[1] for r in RESULTS)
    print('\n%d tests, %d failed' % (len(RESULTS), sum(1 for r in RESULTS if not r[1])))
