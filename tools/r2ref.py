"""Reference re-implementation of the Turbo Esprit 3D road renderer (Z80 0x7BBE-0x862D).
Operates on a 64K bytearray `m` (Spectrum address space).  Written to be bit-exact with the
original (verified against the emulator, see verify.py).  Register-level state that matters is
kept in explicit variables:
  CUR  : the "pixel cursor" (Z80 alternate set hl'/c'/b'/de'):  addr (buffer byte address),
         mask (single set bit = pixel inside the byte), y1 (b' = screen row + 1, decremented on
         every upward step)
  ACC  : Bresenham error accumulator (A' in the original), carried across calls
  X    : ixl = "inward x" of the line cursor (pixels from the outer screen edge of the half)
  IY   : pointer to the current 12-byte perspective record (D78FE table)
  SEL  : column (7..11) of the 12-byte record that gives major-axis pixels per depth unit
  SLD,SLE : line slope (d,e) popped from the line record
"""
IX = 0x75E1

class Renderer:
    def __init__(s, m):
        s.m = m
        s.cur_addr = 0; s.cur_mask = 0; s.cur_y1 = 0
        s.ACC = 0; s.X = 0; s.IY = 0; s.SEL = 7; s.SLD = 0; s.SLE = 0
        s.right = False            # mirrors D75E5 bit7 / the 7D3E opcode patch set
        s.dither_mode = False      # 82D5/831C == 0x3F (ccf) instead of nop
        s.plot = True              # 82DA/830D == 'or c' (0xB1) instead of nop

    # ---------------- memory helpers
    def rb(s, a): return s.m[a & 0xFFFF]
    def wb(s, a, v): s.m[a & 0xFFFF] = v & 0xFF
    def rw(s, a): return s.m[a & 0xFFFF] | (s.m[(a + 1) & 0xFFFF] << 8)
    def ww(s, a, v): s.wb(a, v); s.wb(a + 1, v >> 8)
    def ix(s, o): return s.m[IX + o]
    def setix(s, o, v): s.m[IX + o] = v & 0xFF
    def iyb(s, o): return s.m[(s.IY + o) & 0xFFFF]

    # ---------------- 7D3E: patch for half.  Left: rlc/dec l outward, rrc/inc l inward.
    def patch(s, right):
        s.right = right
        m = s.m
        if not right:
            a, h, l, d, e = 0x00, 0x01, 0x09, 0x2C, 0x2D
        else:
            a, h, l, d, e = 0x22, 0x09, 0x01, 0x2D, 0x2C
        m[0x8194] = a
        for x in (0x8237, 0x834D, 0x836A): m[x] = h
        for x in (0x82E9, 0x8301): m[x] = l
        for x in (0x82ED, 0x8304): m[x] = d
        for x in (0x823F, 0x8350, 0x836D): m[x] = e

    # pixel steps.  'outward' = toward the outer screen edge of the current half
    def _out(s, addr, mask, page_only=True):
        # left: rlc c; on carry dec l     right: rrc c; on carry inc l   (8-bit l only!)
        if not s.right:
            mask = ((mask << 1) | (mask >> 7)) & 0xFF
            if mask == 0x01: addr = (addr & 0xFF00) | ((addr - 1) & 0xFF)
        else:
            mask = ((mask >> 1) | (mask << 7)) & 0xFF
            if mask == 0x80: addr = (addr & 0xFF00) | ((addr + 1) & 0xFF)
        return addr, mask

    def _in(s, addr, mask):
        if not s.right:
            mask = ((mask >> 1) | (mask << 7)) & 0xFF
            if mask == 0x80: addr = (addr & 0xFF00) | ((addr + 1) & 0xFF)
        else:
            mask = ((mask << 1) | (mask >> 7)) & 0xFF
            if mask == 0x01: addr = (addr & 0xFF00) | ((addr - 1) & 0xFF)
        return addr, mask

    # ---------------- 8195 / 81B7 horizontal span fills (cursor unchanged)
    def fill_dir(s, pattern, leftward):
        hl = s.cur_addr; c = s.cur_mask; m = s.m
        a = m[hl] | c; m[hl] = a
        while True:
            if leftward:
                cy = c >> 7; c = ((c << 1) | cy) & 0xFF
            else:
                cy = c & 1; c = ((c >> 1) | (cy << 7)) & 0xFF
            if cy:
                while True:
                    hl = (hl & 0xFF00) | ((hl + (-1 if leftward else 1)) & 0xFF)
                    a = m[hl]
                    if a != 0: break
                    m[hl] = pattern
            if a & c: return
            a = (pattern & c) | m[hl]; m[hl] = a

    def fill_out(s, pattern=0xFF):       # 8191 (pattern FF) : jr patched to 8195 (left) / 81B7 (right)
        s.fill_dir(pattern, not s.right)

    def fill_out_dither(s):              # 8188
        s.wb(0x81D5, s.rb(0x81D5) ^ 0xFF)
        s.fill_out(s.rb(0x81D5))

    # ---------------- 81D7: pop a 16-byte line record from the record stack (D74FB)
    def pop_line(s):
        p = s.rw(0x74FB); m = s.m
        a = m[(p + 1) & 0xFFFF]
        if a & 0x80:
            # end marker: SP advanced by the 'pop af' only
            s.ww(0x74FB, p + 2)
            return None, a
        s.wb(0x82C4, a); s.SEL = a
        q = p + 2
        if s.ix(4) & 0x80:
            q += 4
        s.cur_addr = s.rw(q); s.cur_mask = m[(q + 2) & 0xFFFF]; s.cur_y1 = m[(q + 3) & 0xFFFF]
        q += 4
        if not (s.ix(4) & 0x80):
            q += 4
        s.X = m[q]; acc = m[q + 1]
        s.SLE = m[q + 2]; s.SLD = m[q + 3]
        s.IY = s.rw(q + 4)
        s.ww(0x74FB, q + 6)
        return True, acc       # acc = value returned in A

    # ---------------- 82AA/82AC/82AF : advance along the current line by b depth units
    def line(s, b, plot):
        s.plot = plot
        s.wb(0x82DA, 0xB1 if plot else 0); s.wb(0x830D, 0xB1 if plot else 0)
        a = 0
        if b == 0: b = 256
        while b:
            if s.iyb(7) & 0x80: break
            a = (a + s.iyb(s.SEL)) & 0xFF
            s.IY = (s.IY + 12) & 0xFFFF
            b -= 1
        n = a
        if n == 0: return
        d, e = s.SLD, s.SLE
        m = s.m
        if d >= e:
            # y-major (82D5 loop)
            first = True
            for _ in range(n):
                if s.dither_mode:
                    if s.plot: s.fill_out_dither()
                else:
                    if s.plot: m[s.cur_addr] |= s.cur_mask
                acc = s.ACC + e
                if acc > 0xFF or (acc & 0xFF) >= d:
                    acc = (acc - d) & 0xFF
                    s.X = (s.X + 1) & 0xFF
                    s.cur_addr, s.cur_mask = s._in(s.cur_addr, s.cur_mask)
                s.ACC = acc & 0xFF
                s.cur_addr = (s.cur_addr - 32) & 0xFFFF
                s.cur_y1 = (s.cur_y1 - 1) & 0xFF
        else:
            # x-major (82FF loop).  'fl' = carry of the scratch AF: fill on first pixel of each row
            fl = s.dither_mode
            for _ in range(n):
                s.cur_addr, s.cur_mask = s._in(s.cur_addr, s.cur_mask)
                s.X = (s.X + 1) & 0xFF
                if fl:
                    if s.plot: s.fill_out_dither()
                    fl = False
                else:
                    if s.plot: m[s.cur_addr] |= s.cur_mask
                    fl = False
                acc = s.ACC + d
                if acc > 0xFF or (acc & 0xFF) >= e:
                    acc = (acc - e) & 0xFF
                    s.cur_y1 = (s.cur_y1 - 1) & 0xFF
                    s.cur_addr = (s.cur_addr - 32) & 0xFFFF
                    if s.dither_mode: fl = not fl
                s.ACC = acc & 0xFF

    # ---------------- 8337 : roof line from cursor, dx=l (inward->outward), dy=h (upwards)
    def roofline(s, l, h):
        if (l | h) == 0: return
        m = s.m
        if h >= l:
            b = h; a = h >> 1
            for _ in range(b):
                t = a + l
                if t > 0xFF or (t & 0xFF) >= h:
                    a = (t - h) & 0xFF
                    m[s.cur_addr] |= s.cur_mask
                    s.cur_addr, s.cur_mask = s._out(s.cur_addr, s.cur_mask)
                else:
                    a = t & 0xFF
                s.cur_addr = (s.cur_addr - 32) & 0xFFFF     # de' = -32
        else:
            b = l; a = l >> 1
            for _ in range(b):
                t = a + h
                if t > 0xFF or (t & 0xFF) >= l:
                    a = (t - l) & 0xFF
                    s.cur_addr = (s.cur_addr - 32) & 0xFFFF
                else:
                    a = t & 0xFF
                s.cur_addr, s.cur_mask = s._out(s.cur_addr, s.cur_mask)
                m[s.cur_addr] |= s.cur_mask

    # ---------------- 8276 : dithered fill downwards under mask d starting below hl
    def dfill_down(s, hl, d):
        if d == 0: return
        m = s.m
        e = m[0x81D5]
        if d == 0xFF:
            while True:
                hl = (hl + 32) & 0xFFFF
                a = m[hl]
                if a != 0: break
                m[hl] = e
                e = ((e << 1) | (e >> 7)) & 0xFF
            if a == 0xFF: return
            # fall into per-bit loop at 8287 (hl already advanced)
            while True:
                c = m[hl]; m[hl] = c | (d & e)
                e = ((e << 1) | (e >> 7)) & 0xFF
                d = (~c) & d & 0xFF
                if d == 0: return
                hl = (hl + 32) & 0xFFFF
        while True:
            hl = (hl + 32) & 0xFFFF
            c = m[hl]; m[hl] = c | (d & e)
            e = ((e << 1) | (e >> 7)) & 0xFF
            d = (~c) & d & 0xFF
            if d == 0: return

    # ---------------- 820B : extend vertical edge b pixels up, then side wall (span + dither + down line)
    # cursor (hl,c) passed/returned through CUR; b given; uses iy[6] as span width
    def side_wall(s, b, entry_8222=False):
        m = s.m; hl = s.cur_addr; c = s.cur_mask
        if not entry_8222:
            if b == 0: b = 256
            for _ in range(b):
                m[hl] |= c; hl = (hl - 32) & 0xFFFF
            b = s.iyb(6)
            if (s.ix(4) & 0x80) and (s.ix(2) & 0x40):
                entry_8222 = True
        if entry_8222:
            # 8222: rlc c is NOT patched (always moves left); dec hl is 16-bit
            while True:
                cy = c >> 7; c = ((c << 1) | cy) & 0xFF
                if cy:
                    while True:
                        hl = (hl - 1) & 0xFFFF
                        if m[hl] != 0: break
                if m[hl] & c: break
            b = 0
        # 8231
        m[hl] |= c
        d = 0
        def step_out(hl, c):
            # 8236 rlc/rrc (patched h) ; returns hl? (no byte move here), c, carry
            if not s.right:
                cy = c >> 7; c = ((c << 1) | cy) & 0xFF
            else:
                cy = c & 1; c = ((c >> 1) | (cy << 7)) & 0xFF
            return c, cy
        bb = b
        while True:
            # L8236
            c, cy = step_out(hl, c)
            if cy:
                s.dfill_down(hl, d)
                done_full = False
                while True:
                    # L823D
                    d = 0
                    hl = (hl & 0xFF00) | ((hl + (-1 if not s.right else 1)) & 0xFF)
                    if m[hl] != 0: break
                    if bb < 8: break
                    bb -= 8
                    d = 0xFF; m[hl] = 0xFF
                    s.dfill_down(hl, d)
                    if bb == 0:
                        done_full = True; break
                if done_full:
                    break    # -> L8269
            # L8256
            if m[hl] & c:
                s.dfill_down(hl, d)
                s.cur_addr = hl; s.cur_mask = c
                return
            d |= c
            m[hl] |= c
            bb = (bb - 1) & 0xFF
            if bb != 0: continue
            d ^= c
            s.dfill_down(hl, d)
            break
        # L8269 : draw down until a set pixel
        hl = (hl + 32) & 0xFFFF
        while not (c & m[hl]):
            m[hl] |= c; hl = (hl + 32) & 0xFFFF
        s.cur_addr = hl; s.cur_mask = c

    # ======================================================================================
    # 84ED / 8511 : centre-line vertical draw / skip of n depth units (column 7 of iy records)
    def _sum7(s, n):
        a = 0
        b = n if n else 256
        while b:
            if s.iyb(7) & 0x80: break
            a = (a + s.iyb(7)) & 0xFF
            s.IY = (s.IY + 12) & 0xFFFF
            b -= 1
        return a
    def cdraw(s, n):
        n &= 0xFF
        if n == 0: return
        k = s._sum7(n)
        for _ in range(k):
            s.m[s.cur_addr] |= s.cur_mask; s.cur_addr = (s.cur_addr - 32) & 0xFFFF
    def cskip(s, n):
        n &= 0xFF
        if n == 0: return
        k = s._sum7(n)
        s.cur_addr = (s.cur_addr - 32 * k) & 0xFFFF

    # ======================================================================================
    # 7D64 : building line (per side)
    def side_scan(s, ofs, p):
        m = s.m
        s.setix(1, ofs)
        m[0x7509] = 0x80
        s.ww(0x74FB, s.rw(0x75DC))
        t = m[p]; s.setix(2, t)
        s.ww(0x74F5, s.rw((s.rw(0x75D8) + 2 * (t & 7)) & 0xFFFF))
        s.setix(4, s.ix(4) | 4)
        p += 1
        a = (m[p] - s.ix(1)) & 0xFF
        # ---- near loop (8-byte records at (D75DA)) ----
        while a < s.ix(0):
            s.setix(3, a)
            p += 1
            saved_p = p
            s.IY = (s.rw(0x75DA) + ((a * 8) & 0xFF)) & 0xFFFF
            s.setix(4, s.ix(4) & ~1)
            t = s.ix(2)
            if t & 0x80: t = 0
            sel = t & 7; m[0x7DE7] = sel
            x = s.iyb(5)
            if s.ix(4) & 0x80: x = (0xE0 - x) & 0xFF
            mask = m[0x75CE + (x & 7)]
            addr = 0x7002 + ((x >> 3) & 0x1F)
            h = s.iyb(sel); s.setix(5, h)
            if h == 0: s.setix(4, s.ix(4) | 1)
            b = (0x60 - h) & 0xFF
            s.cur_addr, s.cur_mask = addr, mask
            if b != 0:
                for _ in range(b):
                    m[addr] |= mask; addr = (addr - 32) & 0xFFFF
                m[addr] |= mask
                s.cur_addr = addr
                if not (s.ix(4) & 1):
                    L, H = m[0x74F5], m[0x74F6]
                    l = (s.iyb(5) - L) & 0xFF
                    hh = (s.ix(5) - H) & 0xFF
                    s.roofline(l, hh)
                    if s.ix(4) & 4: s.fill_out()
                else:
                    s.fill_out()
                s.cur_addr, s.cur_mask = addr, mask
            # L7E28
            p = saved_p
            a = m[p]
            if a == 0 and not (s.ix(2) & 0x80):
                m[0x7509] = (0x6E - s.iyb(5)) & 0xFF
                a = 0
            s.setix(2, a)
            if not (a & 0x80) and (a & 7):
                sel = a & 7; m[0x7E4F] = sel
                v = s.iyb(sel)
                if v < s.ix(5):
                    diff = (s.ix(5) - v) & 0xFF
                    s.setix(5, v)
                    s.side_wall(diff)
                else:
                    s.setix(5, v)
                if s.ix(5) != 0:
                    s.setix(4, s.ix(4) & ~4)
                    s.ww(0x74F5, s.iyb(5) | (s.ix(5) << 8))
                else:
                    s.ww(0x74F5, s.rw((s.rw(0x75D8) + 2 * (s.ix(2) & 7)) & 0xFFFF))
                    s.setix(4, s.ix(4) | 4)
            # L7E92
            p += 1
            a = (s.ix(3) + m[p]) & 0xFF
        # ---- L7E9A : far part, along the perspective line ----
        s.ww(0x74FD, p - 1)
        a2 = (a - s.ix(0)) & 0xFF
        s.setix(9, a2)
        ok, acc = s.pop_line()
        s.ACC = acc
        b = a2
        if b != 0:
            r = s._far_seg(p, b)
            if r is None: return
        p = p
        while True:
            # L7F23
            p = s._boundary(p)
            # 8064
            p = s.rw(0x74F7) + 1
            b = m[p]
            r = s._far_seg(p, b)
            if r is None: return

    def _far_seg(s, p, b):
        """L7EAE: draw the line along segment for b depth units. returns None to end 7D64."""
        m = s.m
        if s.iyb(7) & 0x80: return None
        t = m[0x75E3]
        if t & 0x40: return None
        if t & 0x80:
            s.line(b, False); return True
        if (t & 7) or (m[0x75FD] & 0x80):
            s.line(b, True); return True
        # side-road gap
        ln = m[p]
        lm2 = (ln - 2) & 0xFF
        if lm2 < b:
            s.line((b - lm2) & 0xFF, False)
            b = lm2
        half = ln >> 1
        if half < b:
            first = b - half; b = half
            s.line(first, bool(m[0x75E7] & 2))
            if s.iyb(0) >= 0x23: s.fill_out()
        if b < 3:
            s.line(b, False)
        else:
            s.line(b - 2, bool(m[0x75E7] & 8))
            s.line(1, False)
            if s.iyb(0) >= 0x23: s.fill_out()
            s.line(1, False)
        return True

    def _boundary(s, p):
        """L7F23..8063 : at the end of a segment: vertical edge, roof line, side wall."""
        m = s.m
        acc_saved = s.ACC; X_saved = s.X; sld, sle = s.SLD, s.SLE
        s.setix(7, s.X)
        p += 1
        s.ww(0x74F7, p)
        if m[p] & 0x40:
            if m[0x75E5] & 0x80:
                s.fill_dir(0xFF, True)
        line_pt = (s.cur_addr, s.cur_mask, s.cur_y1)
        s.setix(8, s.cur_y1)
        s.setix(4, s.ix(4) & ~2)
        t = s.ix(2)
        gap = False
        if t & 0x80:
            if m[s.rw(0x74F7)] & 0x80: gap = None   # -> L7FC8 directly
            else: gap = True
        elif (t & 7) == 0:
            gap = True
        if gap is True:
            if not (s.iyb(7) & 0x80): s.fill_out()
            s.setix(4, s.ix(4) | 2)
            s.setix(10, s.iyb(6))
            s.setix(5, 0)
            s.m[(s.IY + 6) & 0xFFFF] = 0
        elif gap is False:
            sel = t & 7; m[0x7F86] = sel
            v = s.iyb(sel)
            s.setix(4, s.ix(4) & ~1)
            if v == s.cur_y1: s.setix(4, s.ix(4) | 1)
            s.setix(5, v)
            addr, mask = s.cur_addr, s.cur_mask
            for _ in range(v if v else 256):
                m[addr] |= mask; addr = (addr - 32) & 0xFFFF
            m[addr] |= mask
            s.cur_addr = addr
            if not (s.ix(4) & 1):
                L, H = m[0x74F5], m[0x74F6]
                l = (s.ix(7) - L) & 0xFF
                t1 = (s.ix(8) - s.ix(5)) & 0xFF
                hh = t1 - H
                if hh < 0: hh = 0
                s.roofline(l, hh)
                if s.ix(4) & 4: s.fill_out()
            else:
                s.fill_out()
            s.cur_addr, s.cur_mask, s.cur_y1 = addr, mask, 0
        # L7FC8
        pp = s.rw(0x74F7)
        a = m[pp]
        if a == 0 and not (s.ix(2) & 0x80):
            m[0x7509] = (0x6E - s.ix(7)) & 0xFF
            a = 0
        s.setix(2, a)
        if not (a & 0x80) and (a & 7):
            sel = a & 7; m[0x7FF1] = sel
            v = s.iyb(sel); old = s.ix(5)
            if v > old:
                s.setix(5, v)
                if not (s.iyb(7) & 0x80):
                    s.side_wall((v - old) & 0xFF)
            elif v == old:
                s.setix(5, v)
                if (s.ix(4) & 0x80) and (s.ix(2) & 0x40):
                    s.side_wall(0, entry_8222=True)
            else:
                s.setix(5, v)
            a = (s.ix(8) - s.ix(5)) & 0xFF
            if a != 0:
                s.setix(4, s.ix(4) & ~4)
                s.ww(0x74F5, s.ix(7) | (a << 8))
            else:
                s.ww(0x74F5, s.rw((s.rw(0x75D8) + 2 * (s.ix(2) & 7)) & 0xFFFF))
                s.setix(4, s.ix(4) | 4)
        # L804D
        if s.ix(4) & 2:
            s.m[(s.IY + 6) & 0xFFFF] = s.ix(10)
        s.cur_addr, s.cur_mask, s.cur_y1 = line_pt
        s.SLD, s.SLE = sld, sle
        s.X = X_saved
        s.ACC = acc_saved
        return p

    # ======================================================================================
    # 806C : kerb line + pavement dither
    def kerb(s):
        m = s.m
        s.dither_mode = True; m[0x82D5] = 0x3F; m[0x831C] = 0x3F
        ok, acc = s.pop_line()
        p = s.rw(0x74FD)
        s.ACC = acc
        a = (m[0x75E0] + m[0x75EA]) & 0xFF
        p += 1
        if a >= m[p]:
            a = (a - m[p]) & 0xFF; p -= 2
        p -= 1
        b = a
        s.ww(0x74FD, p); m[0x75EA] = a
        t = m[p]
        if t & 0x80:
            # L8155
            p += 1; a = b; b = 0x3C
            while True:
                p += 1
                if not (m[p] & 0x80): break
                p += 1; a = (a + m[p]) & 0xFF
                if a >= b: return
            c = a; saved_b = b
            if a: s.line(a, False)
            cur = (s.cur_addr, s.cur_mask, s.cur_y1)
            s.end_band()
            s.cur_addr, s.cur_mask, s.cur_y1 = cur
            s.line(1, False)
            b = saved_b
            if (m[p] & 7) == 0:
                st = 'L80F6'
            else:
                c = 0xFF; st = 'L80DE'
            return s._kerb_loop(p, a, b, c, st)
        if (t & 7) == 0 and not (m[0x75FD] & 0x80):
            c = b
            bb = (0x3C - c) & 0xFF
            p += 1
            if c != 0:
                if c != 1:
                    n = (c - 1) & 0xFF
                    if ((c + 1) & 0xFF) == m[p]:
                        if not (s.iyb(7) & 0x80): s.fill_out()
                        n = (m[p] - 2) & 0xFF
                    s.line(n, False)
                if not (s.iyb(7) & 0x80): s.fill_out()
            b = bb; a = 1
        else:
            p += 1; a = b; b = 0x3C
        return s._kerb_loop(p, a, b, None, 'L80D3')

    def _kerb_loop(s, p, a, b, c, st):
        m = s.m
        while True:
            if st == 'L80D3':
                p += 1
                if m[p] & 0x40:
                    # L8114
                    a = (a - 1) & 0xFF
                    if a: s.line(a, True)
                    s.end_band(); return
                c = a
                if (m[p] & 7) == 0 and not (m[0x75FD] & 0x80):
                    c = (c + 1) & 0xFF
                    s.line(c, True)
                    st = 'L80F6'
                else:
                    st = 'L80DE'
            if st == 'L80F6':
                s.fill_out()
                p += 1
                s.line((m[p] - 2) & 0xFF, False)
                if s.iyb(7) & 0x80: return
                s.fill_out()
                b = (b - c - m[p]) & 0xFF
                a = 1
                st = 'L80D3'; continue
            if st == 'L80DE':
                p += 1
                a = (m[p] + c) & 0xFF
                if a < b: st = 'L80D3'; continue
                s.line(a, True)
                return

    def end_band(s):
        """8119: right side only - full-width band at a dead end (solid line + dithered rows)."""
        m = s.m
        if not (m[0x75E5] & 0x80): return
        s.fill_dir(0xFF, True); s.fill_dir(0xFF, False)
        a = s.iyb(7)
        if a == 0 or (a & 0x80): return
        a -= 1
        if a == 0: return
        for _ in range(a):
            s.cur_addr = (s.cur_addr - 32) & 0xFFFF
            m[0x81D5] ^= 0xFF
            s.fill_dir(m[0x81D5], True)
            s.fill_dir(m[0x81D5], False)
            if (m[0x81D5] & s.cur_mask) == 0:
                m[s.cur_addr] &= (~s.cur_mask) & 0xFF

    # ======================================================================================
    # 8377 : centre line
    def centre(s):
        m = s.m
        s.cur_addr = 0x7010; s.cur_mask = 0x80
        q = s.rw(0x74FD)
        s.IY = 0x78FE
        E = 0xFF
        a = m[q]; q += 1
        special = bool(a & 0x80)
        fills = lambda bitL, bitR: (
            (s.fill_dir(E, True) if m[0x75EC] & bitL else None),
            (s.fill_dir(E, False) if m[0x75EC] & bitR else None))
        def f84B1(c):
            s.cdraw((c + 4) & 0xFF)
            if s.iyb(7) & 0x80: return None
            s.fill_dir(E, True); s.fill_dir(E, False)
            return f84C6(4)
        def f84C6(a):
            s.cskip(a)
            s.fill_dir(E, True); s.fill_dir(E, False)
            return 0xF8
        state = None
        if special:
            a = m[0x75EA]; b = 7
            while True:
                q += 1
                if not (m[q] & 0x80): break
                q += 1; a = (a + m[q]) & 0xFF
                b = (b - 1) & 0xFF
                if b == 0: return
            a = (a + 1) & 0xFF
            s.cskip(a)
            s.fill_dir(E, True); s.fill_dir(E, False)
            if (m[q] & 7) and (m[q - 35] & 7):
                a = 0xFF; q += 1
                a = (a + m[q]) & 0xFF; state = 'L83E5'
            else:
                q += 1
                c = ((m[q] >> 1) - 1) & 0xFF
                z = not (m[0x75EC] & 0x40); a = c
                state = 'L8418'
        elif a & 0x20:
            a = m[0x75EA]
            if a < 4:
                b = 7; state = 'L83C5'
            else:
                a -= 4
                if a < 4:
                    r = f84C6(a)
                else:
                    r = f84B1((a - 8) & 0xFF)
                if r is None: return   # (84B1 returned early: 'ret nz' returns to 8377's caller? no: to 83A7)
                q += 1; b = 7; c = 4; state = 'L83C8'
        else:
            z = (a & 7) == 0
            if not z: z = (m[q - 36] & 7) == 0
            a = m[0x75EA]; b = 7
            state = 'L844B' if z else 'L83C5'
        while True:
            if state == 'L83C5':
                q += 1; c = a; state = 'L83C8'
            if state == 'L83C8':
                a = m[q]
                if a & 0x40:
                    a = c
                    if a == 0: return
                    a = (a - 1) & 0xFF
                    if a == 0: return
                    s.cdraw(a); return
                if a & 0x20:
                    r = f84B1(c)
                    if r is not None: c = r
                    a = m[q]
                q += 1
                if (a & 7) == 0 or (m[q - 36] & 7) == 0:
                    state = 'L83F2'
                else:
                    a = (c + m[q]) & 0xFF
                    state = 'L83E5'
            if state == 'L83E5':
                b = (b - 1) & 0xFF
                if b: state = 'L83C5'; continue
                s.cdraw(a); return
            if state == 'L83F2':
                s.cdraw(c)
                if s.iyb(7) & 0x80: return
                fills(1, 2)
                c = m[q] >> 1
                z = not (m[0x75EC] & 0x40); a = c
                state = 'L8418'
            if state == 'L844B':
                a = (a * 2) & 0xFF
                if a < m[q]:
                    a >>= 1; c = a; z = not (m[0x75EC] & 0x80); state = 'L842E'
                else:
                    a = ((a - m[q]) & 0xFF) >> 1; c = a; z = not (m[0x75EC] & 0x40); state = 'L8418'
            if state == 'L8418':
                (s.cskip if z else s.cdraw)(a)
                if s.iyb(7) & 0x80: return
                fills(4, 8)
                c = m[q] >> 1
                z = not (m[0x75EC] & 0x80); a = c
                state = 'L842E'
            if state == 'L842E':
                (s.cskip if z else s.cdraw)(a)
                if s.iyb(7) & 0x80: return
                fills(0x10, 0x20)
                a = 0
                state = 'L83E5'

    # ======================================================================================
    # 8532 / 8552 / 85E5 : lane dividers (dashed)
    def dashes(s, a, phase):
        n = a >> 2
        if a & 3: n += 1
        n &= 0xFF
        if phase < 4:
            b = 4 - phase
            mode = 'draw'
        else:
            b = (4 - (phase - 4)) & 0xFF
            mode = 'gap'
        while True:
            if mode == 'draw':
                s.line(b, True)
                n = (n - 1) & 0xFF
                if n == 0: return
                b = 4; mode = 'gap'
            if s.iyb(0) >= 0x23:
                s.line(b, False)
            else:
                s.line(b, True)
            n = (n - 1) & 0xFF
            if n == 0: return
            b = 4; mode = 'draw'

    def lanes_pass(s, count):
        m = s.m
        p = 0x76FC
        while True:
            s.ww(0x74FB, p)
            ok, acc = s.pop_line()
            s.ACC = acc
            q = s.rw(0x74FD)
            a = m[q]; q += 1
            z = (a & 7) == 0
            special = bool(a & 0x80)
            phase = m[0x74FF]; a = m[0x75EA]; c = 7
            st = 'L8592'
            if special:
                stop = False
                while True:
                    if not (m[q + 1] & 0x80):
                        st = 'L857F'; break
                    q += 2; a = (a + m[q]) & 0xFF
                    c = (c - 1) & 0xFF
                    if c == 0: stop = True; break
                if stop: return
            elif z:
                if a == 0: st = 'L858A'
                elif (m[0x75EC] & 3) == 0: st = 'L8592'
                else: st = 'L857F'
            while True:
                if st == 'L857F':
                    phase = a
                    if a: s.line(a, False)
                    if s.iyb(7) & 0x80: st = 'L85AA'; break
                    st = 'L858A'
                if st == 'L858A':
                    a = 0; phase = 0; c = (c - 1) & 0xFF
                    if c == 0: st = 'L85AA'; break
                    st = 'L8592'
                if st == 'L8592':
                    # L8595 loop
                    st2 = None
                    while True:
                        q += 1; d = a; a = m[q]
                        if a & 0x40: st2 = 'L85C3'; break
                        if (a & 7) == 0 and (m[0x75EC] & 0x33) != 0: st2 = 'L85B2'; break
                        q += 1; a = (d + m[q]) & 0xFF
                        c = (c - 1) & 0xFF
                        if c == 0: st2 = 'L85A7'; break
                    if st2 == 'L85A7':
                        s.dashes(a, phase); st = 'L85AA'; break
                    if st2 == 'L85C3':
                        a = d
                        if a != 0:
                            a = (a - 1) & 0xFF
                            if a: s.dashes(a, phase)
                        st = 'L85AA'; break
                    if st2 == 'L85B2':
                        a = d; q += 1
                        if a: s.dashes(a, phase)
                        a = m[q]; st = 'L857F'; continue
            count = (count - 1) & 0xFF
            p = 0x76DC
            if count == 0: return

    def lanes(s):
        m = s.m
        n = (m[0x75DF] - 1) & 0xFF
        if n == 0: return
        s.lanes_pass(n)
        m[0x75E5] &= 0x7F
        s.patch(False)
        s.lanes_pass(n)

    # ======================================================================================
    # 7D1B : advance a (segment pointer, offset) pair by D75F6
    def advance(s, p, a):
        m = s.m
        p += 1
        a = (a + m[0x75F6]) & 0xFF
        if a & 0x80:
            p -= 2; a = (a + m[p]) & 0xFF
        if a >= m[p]:
            a = (a - m[p]) & 0xFF; p += 1
        else:
            p -= 1
        return p, a

    # 7BF8.. : everything after the block-change check
    def render_from_7BF8(s):
        m = s.m
        s.ww(0x7502, (s.rw(0x7502) - s.rw(0x75F6)) & 0xFFFF)
        s.patch(False)
        m[0x75E5] = 0
        p, a = s.advance(s.rw(0x7D15), m[0x7D17])
        s.ww(0x7D15, p); m[0x7D17] = a
        if not (m[0x7610] & 1):
            s.side_scan(a, p)
            s.kerb()
        s.dither_mode = False; m[0x82D5] = 0; m[0x831C] = 0
        m[0x750A] = m[0x7509]
        s.patch(True)
        m[0x75E5] = 0x80
        p, a = s.advance(s.rw(0x7D18), m[0x7D1A])
        m[0x7D1A] = a; s.ww(0x7D18, p)
        if m[0x7610] & 1: return
        v = m[0x75E7]; m[0x75E7] = ((v >> 1) | (v << 7)) & 0xFF
        s.side_scan(a, p)
        s.kerb()
        v = m[0x75E7]; m[0x75E7] = ((v << 1) | (v >> 7)) & 0xFF
        s.dither_mode = False; m[0x82D5] = 0; m[0x831C] = 0
        s.centre()
        s.lanes()

    # 7BBE..7BF7 prologue (returns True if 7C8D / 7C82 would be called = block change)
    def prologue(s):
        m = s.m
        a = m[0x81D6]
        if m[0x75F6] != 0:
            a ^= 0xFF; m[0x81D6] = a
        m[0x81D5] = a
        m[0x74FF] = (m[0x74FF] + m[0x75F6]) & 7
        a = (m[0x7508] + m[0x75F6]) & 0xFF
        m[0x7508] = a
        call = None
        if a >= m[0x75F5] and ((a - m[0x75F5]) & 0xFF) >= 0x7B: call = '7C8D'
        return call

# ---- 7CB0..7D14 (tail of 7CA1 'start new block'): recompute scroll/phase/segment pointers
def block_setup_tail(m):
    rb = lambda a: m[a]
    m[0x7793] |= 0x80
    if m[0x7793] & 0x40: b = (m[0x779B] + 0x64) & 0xFF
    else: b = m[0x7798]
    l = (b - 0x3A + m[0x75F6]) & 0xFF
    m[0x7502] = l; m[0x7503] = 0x5C
    m[0x74FF] = (-(b + 5)) & 7
    a = (-b + m[0x75F5] + 0xC7 - m[0x75E1] + m[0x75E0]) & 0xFF
    m[0x7508] = a
    b2 = (a - m[0x75F6]) & 0xFF
    for start, ptr in ((0x787D, 0x7D15), (0x78A0, 0x7D18)):
        a = b2; hl = start
        while a >= m[hl]:
            a -= m[hl]; hl += 2
        hl -= 1
        m[ptr] = hl & 0xFF; m[ptr + 1] = hl >> 8; m[ptr + 2] = a
