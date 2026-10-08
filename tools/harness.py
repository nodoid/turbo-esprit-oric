#!/usr/bin/env python3
"""Headless Oric Atmos test harness.

Runs a cc65 .tap (machine code that takes the hardware over - no ROM needed)
on a py65 6502 core with just enough VIA / AY / keyboard emulation, and
renders the ULA picture (HIRES + text lines) to PNG files.

usage: harness.py game.tap outdir --ticks 600 \
           --keys 50-60:SPACE --keys 100-300:RIGHT+SPACE --shot 80 --shot 300
Times are in 20ms timer ticks.
"""
import argparse
import os
import struct
import sys
import zlib

from py65.devices.mpu6502 import MPU

MATRIX = [
    ['7', 'N', '5', 'V', 'RCTL', '1', 'X', '3'],
    ['J', 'T', 'R', 'F', None, 'ESC', 'Q', 'D'],
    ['M', '6', 'B', '4', 'CTRL', 'Z', '2', 'C'],
    ['K', '9', ';', '-', None, None, '\\', "'"],
    ['SPACE', ',', '.', 'UP', 'LSHIFT', 'LEFT', 'DOWN', 'RIGHT'],
    ['U', 'I', 'O', 'P', 'FUNCT', 'DEL', ']', '['],
    ['Y', 'H', 'G', 'E', None, 'A', 'S', 'W'],
    ['8', 'L', '0', '/', 'RSHIFT', 'RETURN', None, '='],
]
KEYMAP = {k: (r, c) for r, row in enumerate(MATRIX) for c, k in enumerate(row) if k}

PALETTE = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0),
           (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]

T1_PERIOD = 20000


class Machine:
    def __init__(self):
        self.ram = bytearray(65536)
        for a in range(0xC000, 0x10000):
            self.ram[a] = 0x60          # RTS everywhere in "ROM"
        self.ram[0xFFFE] = 0x44         # Atmos ROM: IRQ -> $0244
        self.ram[0xFFFF] = 0x02
        self.ier = 0
        self.t1_irq_seen = 0
        self.orb = 0
        self.ora = 0
        self.ay = [0] * 16
        self.ay_latch = 0
        self.pressed = set()
        self.t1_start = None
        self.t1_ack = 0
        self.t2_start = 0
        self.t2_val = 0xFFFF
        self.t2_latch = 0xFF
        self.cycles = 0
        self.rom_hits = 0
        self.aylog = None

    # --- VIA ---------------------------------------------------------
    def t1_count(self):
        if self.t1_start is None:
            return 0
        return (self.cycles - self.t1_start) // T1_PERIOD

    def keybit(self):
        row = self.orb & 7
        cols = (~self.ay[14]) & 0xFF
        for (r, c) in self.pressed:
            if r == row and cols & (1 << c):
                return 0x08
        return 0

    def read(self, a):
        if 0x0300 <= a <= 0x030F:
            r = a & 15
            if r == 0:
                return (self.orb & 0xF7) | self.keybit()
            if r == 4:
                self.t1_ack = self.t1_count()
                return 0
            if r in (8, 9):
                v = (self.t2_val - (self.cycles - self.t2_start)) & 0xFFFF
                return v & 0xFF if r == 8 else v >> 8
            if r == 13:
                f = 0x40 if self.t1_count() > self.t1_ack else 0
                if self.cycles - self.t2_start > self.t2_val:
                    f |= 0x20
                return f
            if r in (1, 15):
                return self.ora
            return 0
        return self.ram[a]

    def write(self, a, v):
        if 0x0300 <= a <= 0x030F:
            r = a & 15
            if r == 0:
                self.orb = v
            elif r in (1, 15):
                self.ora = v
            elif r == 5:
                self.t1_start = self.cycles
                self.t1_ack = 0
            elif r == 14:
                if v & 0x80:
                    self.ier |= v & 0x7F
                else:
                    self.ier &= ~v & 0x7F
            elif r == 8:
                self.t2_latch = v
            elif r == 9:
                self.t2_val = (v << 8) | self.t2_latch
                self.t2_start = self.cycles
            elif r == 12:
                if v == 0xFF:
                    self.ay_latch = self.ora & 15
                elif v == 0xFD:
                    self.ay[self.ay_latch] = self.ora
                    if self.aylog is not None and self.ay_latch < 14:
                        self.aylog.append((self.cycles, self.ay_latch, self.ora))
            return
        if a >= 0xC000:
            return
        self.ram[a] = v


class Mem:
    """Memory object for py65 that routes I/O page accesses."""

    def __init__(self, m):
        self.m = m
        self.ram = m.ram

    def __getitem__(self, a):
        if isinstance(a, slice):
            return [self[i] for i in range(*a.indices(65536))]
        if 0x0300 <= a <= 0x030F:
            return self.m.read(a)
        return self.ram[a]

    def __setitem__(self, a, v):
        if 0x0300 <= a <= 0x030F or a >= 0xC000:
            self.m.write(a, v)
        else:
            self.ram[a] = v

    def __len__(self):
        return 65536


def load_tap(path, ram):
    d = open(path, 'rb').read()
    i = 0
    while d[i] == 0x16:
        i += 1
    assert d[i] == 0x24, "bad tap sync"
    i += 1
    hdr = d[i:i + 9]
    end = (hdr[4] << 8) | hdr[5]
    start = (hdr[6] << 8) | hdr[7]
    i += 9
    while d[i] != 0:
        i += 1
    i += 1
    data = d[i:i + (end - start + 1)]
    ram[start:start + len(data)] = data
    return start, end, hdr


def render(ram):
    w, h = 240, 224
    img = bytearray(w * h * 3)
    hires = ram[0xBFDF] in (0x1E, 0x1F) or ram[0xBFDF] in (0x1C, 0x1D)

    def put(x, y, col):
        o = (y * w + x) * 3
        img[o:o + 3] = bytes(PALETTE[col])

    for y in range(h):
        ink, paper = 7, 0
        for c in range(40):
            if hires and y < 200:
                b = ram[0xA000 + y * 40 + c]
                pat = None
            else:
                if hires:
                    t, cr = (y - 200) // 8, (y - 200) % 8
                    b = ram[0xBF68 + t * 40 + c]
                    cs = 0x9800
                else:
                    t, cr = y // 8, y % 8
                    if t >= 28:
                        continue
                    b = ram[0xBB80 + t * 40 + c]
                    cs = 0xB400
                pat = ram[cs + (b & 0x7F) * 8 + cr]
            inv = 7 if b & 0x80 else 0
            if (b & 0x60) == 0:
                v = b & 0x1F
                if v < 8:
                    ink = v
                elif 16 <= v < 24:
                    paper = v - 16
                for p in range(6):
                    put(c * 6 + p, y, paper ^ inv)
                continue
            bits = (b & 0x3F) if pat is None else (pat & 0x3F)
            for p in range(6):
                on = bits & (0x20 >> p)
                put(c * 6 + p, y, (ink if on else paper) ^ inv)
    return w, h, img


def write_png(path, w, h, rgb, scale=2):
    raw = bytearray()
    for y in range(h):
        row = bytearray()
        for x in range(w):
            o = (y * w + x) * 3
            row += rgb[o:o + 3] * scale
        for _ in range(scale):
            raw.append(0)
            raw += row
    def chunk(t, data):
        c = struct.pack('>I', len(data)) + t + data
        return c + struct.pack('>I', zlib.crc32(t + data) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('tap')
    ap.add_argument('outdir')
    ap.add_argument('--ticks', type=int, default=300)
    ap.add_argument('--keys', action='append', default=[])
    ap.add_argument('--shot', action='append', type=int, default=[])
    ap.add_argument('--every', type=int, default=0, help='screenshot every N ticks')
    ap.add_argument('--raw', help='dump raw RGB frames every tick to this file')
    ap.add_argument('--profile', help='tick range a-b to sample PCs in')
    ap.add_argument('--labels', default=None)
    ap.add_argument('--watch', help='comma list of hex addrs to print each tick')
    ap.add_argument('--poke', action='append', default=[], help='tick:addr=val[,addr=val]')
    ap.add_argument('--watchfrom', type=int, default=0)
    ap.add_argument('--entry', type=lambda s: int(s, 0), default=None)
    args = ap.parse_args()

    syms = {}
    lblpath = args.labels or args.tap.replace('.tap', '.lbl')
    if os.path.exists(lblpath):
        for line in open(lblpath):
            parts = line.split()
            if len(parts) >= 3:
                syms[parts[2].lstrip('.')] = int(parts[1], 16)

    def addr(x):
        if x in syms:
            return syms[x]
        if x.startswith('_') and x in syms:
            return syms[x]
        if '+' in x:
            b, o = x.split('+')
            return addr(b) + int(o, 0)
        return int(x, 16)

    m = Machine()
    start, end, hdr = load_tap(args.tap, m.ram)
    entry = args.entry if args.entry is not None else (start + 12 if hdr[2] == 0 else start)
    mpu = MPU(memory=Mem(m), pc=entry)
    mpu.sp = 0xFF
    os.makedirs(args.outdir, exist_ok=True)

    events = []
    for k in args.keys:
        rng, names = k.split(':')
        a, b = (rng.split('-') + [None])[:2]
        a = int(a)
        b = int(b) if b else a + 2
        events.append((a, b, [KEYMAP[n] for n in names.split('+')]))

    shots = set(args.shot)
    raw = open(args.raw, 'wb') if args.raw else None
    tick = -1
    prof = {}
    pa = pb = -1
    if args.profile:
        pa, pb = map(int, args.profile.split('-'))
    while tick < args.ticks:
        if pa <= tick < pb:
            prof[mpu.pc] = prof.get(mpu.pc, 0) + 1
        mpu.step()
        m.cycles = mpu.processorCycles
        if (m.ier & 0x40) and m.t1_count() > m.t1_ack and not (mpu.p & mpu.INTERRUPT):
            m.t1_ack = m.t1_count()     # level stays until read; we model edge
            mpu.stPushWord(mpu.pc)
            mpu.stPush(mpu.p & ~mpu.BREAK | mpu.UNUSED)
            mpu.p |= mpu.INTERRUPT
            mpu.pc = m.ram[0xFFFE] | (m.ram[0xFFFF] << 8)
        if mpu.pc >= 0xC000:
            m.rom_hits += 1
            if m.rom_hits < 5:
                print("ROM call at %04X" % mpu.pc, file=sys.stderr)
        t = m.cycles // T1_PERIOD
        if t != tick:
            tick = t
            m.pressed = set()
            for a, b, ks in events:
                if a <= tick < b:
                    m.pressed.update(ks)
            for pk in args.poke:
                pt, rest = pk.split(':')
                if int(pt) == tick:
                    for kv in rest.split(','):
                        ad, v = kv.split('=')
                        m.ram[addr(ad)] = int(v, 0)
            if args.watch and tick >= args.watchfrom:
                print(tick, ' '.join('%3d' % m.ram[addr(x)] for x in args.watch.split(',')))
            if tick in shots or (args.every and tick % args.every == 0):
                w, h, img = render(m.ram)
                write_png(os.path.join(args.outdir, 'shot_%05d.png' % tick), w, h, img)
            if raw:
                w, h, img = render(m.ram)
                raw.write(img)
    if prof:
        labs = []
        for line in open(args.labels or args.tap.replace('.tap', '.lbl')):
            parts = line.split()
            if len(parts) >= 3:
                name = parts[2].lstrip('.')
                if name.startswith('L') and name[1:].isalnum() and any(ch.isdigit() for ch in name[1:2]):
                    continue
                if name.startswith('@') or name.startswith('__'):
                    continue
                labs.append((int(parts[1], 16), name))
        labs.sort()
        import bisect
        keys = [a for a, _ in labs]
        agg = {}
        for pc, n in prof.items():
            i = bisect.bisect_right(keys, pc) - 1
            nm = labs[i][1] if i >= 0 else '?'
            agg[nm] = agg.get(nm, 0) + n
        tot = sum(agg.values())
        for nm, n in sorted(agg.items(), key=lambda x: -x[1])[:25]:
            print("%6.2f%% %s" % (100.0 * n / tot, nm))
    print("done: %d cycles, pc=%04X" % (m.cycles, mpu.pc))


if __name__ == '__main__':
    main()
