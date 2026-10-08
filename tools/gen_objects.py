#!/usr/bin/env python3
"""Generate data/objects_data.s: the sprite bank of the original
(Spectrum $BB1F-$DA7F: sprite images, traffic-light lamp frames, the master
sprite table $C581) for src/objects.s.

usage: gen_objects.py [tape.tzx] [out.s] [--stats]

The bank keeps its original byte layout (image addresses are computed as
"base + sum of size bytes", so offsets inside a chain must not change).  It is
split in two pieces around the code/table hole $BF72-$BFA3 (LBF72 is
translated in objects.s, its frame table $BF9C is emitted as T_BF9C):

    SPR1 = $BB1F-$BF71   (sprites 00,01,03,... + lamp frames $BEDA-$BF71)
    SPR2 = $BFA4-$DA7F   (sprites 02.. + table $C581 + cars, pedestrians...)

Every absolute pointer inside the data (table base words, view-angle
container base words, alias targets) becomes a label expression.  The script
walks every image the renderer can reach and checks that no size byte that
the renderer adds up is a relocated pointer byte, and that every chain stays
inside one piece.

The 4 lamp areas of sprite 03 rewritten by LBF72 are ZLABELs (ZV_BDE2,
ZV_BE05, ZV_BE45, ZV_BEA3) so tests copy/compare them like Spectrum state.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zxtape  # noqa: E402

P1 = (0xBB1F, 0xBF72)
P2 = (0xBFA4, 0xDA80)
TABLE = 0xC581
NSPR = 40
PATCH = {0xBDE2: 3, 0xBE05: 5, 0xBE45: 15, 0xBEA3: 15}
FRAMES = 0xBF9C
# view-angle indices the game can produce per sprite id (see notes R7 1.2):
# objects using sprite 10 are always on the left (angles 0..3).
ANGLES = {0x10: range(0, 4)}


def piece(a):
    if P1[0] <= a < P1[1]:
        return 1
    if P2[0] <= a < P2[1]:
        return 2
    raise ValueError('address %04X outside the bank' % a)


class Bank:
    def __init__(self, m):
        self.m = m
        self.ptrs = {}          # address of a pointer word -> target
        self.sizes = set()      # addresses of size bytes the renderer adds
        self.images = {}        # real image address -> info
        self.errors = []

    def w(self, a):
        return self.m[a] | self.m[a + 1] << 8

    def chain(self, rec, n):
        """address = word(rec) + sum(n bytes after it), 16-bit (S8D35)."""
        base = self.w(rec)
        self.ptrs[rec] = base
        v = base
        for k in range(n):
            self.sizes.add(rec + 2 + k)
            v = (v + self.m[rec + 2 + k]) & 0xFFFF
        if piece(v) != piece(base):
            self.errors.append('chain %04X+%d crosses pieces' % (rec, n))
        return v

    def image(self, p, side_angles, sprite=None):
        m = self.m
        if m[p] & 0x40:
            for k in side_angles:
                self.image(self.chain(p + 1, k), None, sprite)
            return
        if m[p] & 0x80:
            t = self.w(p + 1)
            self.ptrs[p + 1] = t
            p = t
            if m[p] & 0xC0:
                self.errors.append('alias %04X -> non-plain image' % p)
        if p in self.images:
            self.images[p]['sprites'].add(sprite)
            return
        f = m[p]
        W = f & 15
        H = m[p + 2]
        q = p + 3 + W * H
        maxend = 0
        runs = 0
        for r in range(H):
            if not f & 0x10:
                v = m[q]
                q += 1
                maxend = max(maxend, (v & 7) + (v >> 3))
                runs = max(runs, 1)
            else:
                x = m[q]
                q += 1
                n = 0
                while True:
                    ln = m[q]
                    q += 1
                    x += ln & 0x7F
                    n += 1
                    if not ln & 0x80:
                        break
                    x += m[q]
                    q += 1
                maxend = max(maxend, x)
                runs = max(runs, n)
        ov = []
        if f & 0x20:
            for mir in (0, 1):
                for b3 in (0, 1):
                    h = q
                    if mir:
                        h += m[h]
                    h += 1
                    if b3:
                        h += m[h]
                    h += 1
                    n = m[h]
                    if n == 0:
                        self.errors.append('%04X: empty overlay list (Z80 would write 256 pairs)' % p)
                    ov += [m[h + 2 + 2 * i] for i in range(n)]
        self.images[p] = dict(W=W, H=H, f=f, b1=m[p + 1], maxend=maxend, runs=runs, ov=ov,
                              maskbytes=q - (p + 3 + W * H), sprites={sprite})

    def walk(self):
        for i in range(NSPR):
            rec = TABLE + 8 * i
            angles = ANGLES.get(i, range(8))
            for lev in range(7):
                self.image(self.chain(rec, lev), angles, i)
        for k in range(4):
            a = FRAMES + 2 * k
            self.ptrs[a] = self.w(a)
        bad = self.sizes & (set(self.ptrs) | {a + 1 for a in self.ptrs})
        if bad:
            self.errors.append('size bytes overlap pointers: ' + ' '.join('%04X' % a for a in sorted(bad)))
        # properties src/objects.s relies on
        for p, i in self.images.items():
            W, H = i['W'], i['H']
            explosion_only = all(sp is not None and sp >= 0x24 for sp in i['sprites'])
            if not 1 <= W <= 5:
                self.errors.append('%04X: W=%d (row code handles 1..5)' % (p, W))
            if (W + 1) * H > 128:
                self.errors.append('%04X: (W+1)*H > 128 (overlay buffer $71D0)' % p)
            if i['maxend'] > W * 8 and not explosion_only:
                self.errors.append('%04X: mask run beyond W*8 (mask rows are not clipped)' % p)
            if i['maskbytes'] > 255:
                self.errors.append('%04X: mask data > 255 bytes' % p)
            if any(o % (W + 1) == W for o in i['ov']):
                self.errors.append('%04X: overlay writes the spare column' % p)
            if explosion_only and i['f'] & 0x20:
                self.errors.append('%04X: explosion image with overlay' % p)


def expr(a):
    return '$%04X+R%d' % (a, piece(a))


def emit(bank, out):
    m = bank.m
    ptrs = {a: t for a, t in bank.ptrs.items() if not FRAMES <= a < FRAMES + 8}
    L = ['; objects_data.s - generated by tools/gen_objects.py from the original tape.',
         '; Sprite bank of the Spectrum original ($BB1F-$DA7F, minus the LBF72 code',
         '; hole $BF72-$BFA3), byte layout unchanged; pointers are label expressions',
         '; (Rn = new address - Spectrum address of piece n).  Included by objects.s.',
         '']
    for n, (lo, hi) in ((1, P1), (2, P2)):
        L.append('SPR%d:' % n)
        L.append('R%d = SPR%d - $%04X' % (n, n, lo))
        a = lo
        row = []

        def flush():
            if row:
                L.append('        .byte ' + ','.join(row))
                row.clear()
        while a < hi:
            if a in PATCH:
                flush()
                L.append('        ZLABEL $%04X, %d' % (a, PATCH[a]))
            if a == TABLE:
                flush()
                L.append('T_C581:')
            if a in ptrs:
                flush()
                L.append('        .word %s' % expr(ptrs[a]))
                a += 2
                continue
            row.append('$%02X' % m[a])
            if len(row) == 16:
                flush()
            a += 1
        flush()
    L.append('T_BF9C:')
    for k in range(4):
        L.append('        .word %s' % expr(bank.w(FRAMES + 2 * k)))
    open(out, 'w').write('\n'.join(L) + '\n')


def main():
    args = [x for x in sys.argv[1:] if not x.startswith('--')]
    tape = args[0] if args else os.path.join(HERE, '..', 'orig', 'TurboEsprit.tzx')
    out = args[1] if len(args) > 1 else os.path.join(HERE, '..', 'data', 'objects_data.s')
    m = zxtape.load_image(tape)
    bank = Bank(m)
    bank.walk()
    if bank.errors:
        sys.exit('\n'.join(bank.errors))
    if '--stats' in sys.argv:
        im = bank.images.values()
        print('images', len(bank.images), 'pointers', len(bank.ptrs))
        print('max W', max(i['W'] for i in im), 'max (W+1)*H', max((i['W'] + 1) * i['H'] for i in im))
        print('max H', max(i['H'] for i in im))
        print('runs beyond W*8:', ['%04X' % a for a, i in bank.images.items() if i['maxend'] > i['W'] * 8])
        print('max runs/row', max(i['runs'] for i in im))
        print('overlay offset in spare column:', ['%04X' % a for a, i in bank.images.items()
                                                  if any(o % (i['W'] + 1) == i['W'] for o in i['ov'])])
        print('overlay max offset vs size:', ['%04X:%d/%d' % (a, max(i['ov']), (i['W'] + 1) * i['H'])
                                              for a, i in bank.images.items() if i['ov']])
        print('W>=8:', ['%04X:%d' % (a, i['W']) for a, i in bank.images.items() if i['W'] >= 8])
    emit(bank, out)
    print('wrote', out, (P1[1] - P1[0]) + (P2[1] - P2[0]) + 8, 'bytes')


if __name__ == '__main__':
    main()
