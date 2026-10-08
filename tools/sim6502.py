#!/usr/bin/env python3
"""Run single translated routines on a 6502 (py65) and compare them with the
original Z80 routine's effect (see zxref.py).

    from sim6502 import Sim
    sim = Sim('build/test_render.bin', 'build/test_render.lbl')
    sim.load_state(sample.pre_mem, sample.pre)     # Spectrum state -> Oric
    sim.call('Z_893C', rvals=sample.rvals)
    diffs = sim.compare(sample.post_mem)           # [] when identical

Memory mapping (docs/PORTING.md):
  * $5B00-$7BBD is identical on both machines;
  * a relocated Spectrum variable at address X is the exported label ZV_xxxx
    with size ZVS_xxxx (copied in and compared);
  * Z80 registers map to the zero-page register file (zc, zb, ...); A is the
    6502 accumulator; the alternate set goes to zc2... and za2.
"""
import os
import sys

from py65.devices.mpu6502 import MPU

ZX_LO, ZX_HI = 0x5B00, 0x7BBE
LOAD = 0x0600
STOP = 0x0300           # I/O page: never code; reaching it ends a call


class Sim:
    def __init__(self, binpath, lblpath=None):
        self.mem = bytearray(0x10000)
        data = open(binpath, 'rb').read()
        self.mem[LOAD:LOAD + len(data)] = data
        if os.path.exists(binpath + '.ovl'):           # RAM under the ROM
            ovl = open(binpath + '.ovl', 'rb').read()
            self.mem[0xC000:0xC000 + len(ovl)] = ovl
        self.sym = {}
        lblpath = lblpath or os.path.splitext(binpath)[0] + '.lbl'
        for line in open(lblpath):
            p = line.split()
            if len(p) >= 3:
                self.sym[p[2].lstrip('.')] = int(p[1], 16)
        self.zvars = {}     # spectrum addr -> (oric addr, size)
        for name, v in self.sym.items():
            if name.startswith('ZV_'):
                zxa = int(name[3:], 16)
                size = self.sym.get('ZVS_' + name[3:], 1)
                self.zvars[zxa] = (v, size)
        self.mpu = MPU(memory=self.mem, pc=0)
        self.cycles = 0
        self.a = 0
        self.carry = 0
        self.zero = 0
        self.hooks = {}     # pc -> fn(sim); the hooked routine is skipped (RTS)
        self.keys_down = set()   # logical keys for the Z_F37A hook: 'JLKASMT'
        if 'Z_F37A' in self.sym:
            self.hooks[self.sym['Z_F37A']] = Sim._f37a

    @staticmethod
    def _f37a(sim):
        # key test: zl/zh -> key-table entry ($7524 + 3*k for J L K A S M T)
        m = sim.mem
        hl = m[sim.sym['zl']] | (m[sim.sym['zh']] << 8)
        k = (hl - 0x7524) // 3
        down = 0 <= k < 7 and 'JLKASMT'[k] in sim.keys_down
        hl += 2
        m[sim.sym['zl']] = hl & 0xFF
        m[sim.sym['zh']] = hl >> 8
        sim.mpu.a = 0 if down else 1
        sim.mpu.p = (sim.mpu.p & ~0x82) | (0x02 if down else 0)

    def addr(self, x):
        return self.sym[x] if isinstance(x, str) else x

    # ----------------------------------------------------------------------
    def load_state(self, zxmem, regs=None, ident=True, zvars=True):
        if ident:
            self.mem[ZX_LO:ZX_HI] = zxmem[ZX_LO:ZX_HI]
        if zvars:
            for zxa, (oa, n) in self.zvars.items():
                self.mem[oa:oa + n] = zxmem[zxa:zxa + n]
        if regs:
            self.set_regs(regs)

    def set_regs(self, r):
        s = self.sym

        def put(name, v):
            if name in s:
                self.mem[s[name]] = v & 0xFF
        for pair, lo, hi in (('bc', 'zc', 'zb'), ('de', 'ze', 'zd'), ('hl', 'zl', 'zh'),
                             ('ix', 'zixl', 'zixh'), ('iy', 'ziyl', 'ziyh'),
                             ('alt_bc', 'zc2', 'zb2'), ('alt_de', 'ze2', 'zd2'),
                             ('alt_hl', 'zl2', 'zh2')):
            if pair in r:
                put(lo, r[pair])
                put(hi, r[pair] >> 8)
        if 'alt_af' in r:
            put('za2', r['alt_af'] >> 8)
        if 'af' in r:
            self.a = r['af'] >> 8
            put('za', self.a)
            self.carry = r['af'] & 1
            self.zero = (r['af'] >> 6) & 1

    def get_regs(self):
        s, m = self.sym, self.mem

        def g(name):
            return m[s[name]] if name in s else 0
        return {'a': self.mpu.a, 'bc': g('zc') | g('zb') << 8, 'de': g('ze') | g('zd') << 8,
                'hl': g('zl') | g('zh') << 8, 'ix': g('zixl') | g('zixh') << 8,
                'iy': g('ziyl') | g('ziyh') << 8,
                'carry': self.mpu.p & 1, 'zero': (self.mpu.p >> 1) & 1}

    # ----------------------------------------------------------------------
    def call(self, target, a=None, rvals=(), max_cycles=20_000_000, carry=None):
        """JSR to target with an empty stack; returns cycles used."""
        mpu = self.mpu
        mpu.sp = 0xFF
        ret = STOP - 1
        mpu.stPushWord(ret)
        mpu.pc = self.addr(target)
        mpu.a = self.a if a is None else a
        mpu.p = 0x20 | (1 if (carry if carry is not None else getattr(self, 'carry', 0)) else 0)
        rnd = self.sym.get('rnd_r')
        rv = list(rvals)
        start = mpu.processorCycles
        hooks = self.hooks
        while mpu.pc != STOP:
            if mpu.pc in hooks:
                hooks[mpu.pc](self)
                lo = self.mem[0x100 + ((mpu.sp + 1) & 0xFF)]
                hi = self.mem[0x100 + ((mpu.sp + 2) & 0xFF)]
                mpu.sp = (mpu.sp + 2) & 0xFF
                mpu.pc = ((hi << 8) | lo) + 1
                continue
            if mpu.pc == rnd:
                mpu.a = rv.pop(0) if rv else 0
                mpu.p = (mpu.p & ~0x82) | (0x02 if mpu.a == 0 else 0) | (mpu.a & 0x80)
                lo = self.mem[0x100 + ((mpu.sp + 1) & 0xFF)]
                hi = self.mem[0x100 + ((mpu.sp + 2) & 0xFF)]
                mpu.sp = (mpu.sp + 2) & 0xFF
                mpu.pc = ((hi << 8) | lo) + 1
                continue
            mpu.step()
            if mpu.processorCycles - start > max_cycles:
                raise RuntimeError('routine did not return (pc=%04X)' % mpu.pc)
        self.cycles = mpu.processorCycles - start
        return self.cycles

    # ----------------------------------------------------------------------
    def compare(self, zxmem, ident=True, zvars=True, ignore=()):
        """List of (spectrum_addr, spectrum_value, oric_value) that differ."""
        ign = set()
        for r in ignore:
            if isinstance(r, tuple):
                ign.update(range(r[0], r[1]))
            else:
                ign.add(r)
        out = []
        if ident:
            for a in range(ZX_LO, ZX_HI):
                if a not in ign and self.mem[a] != zxmem[a]:
                    out.append((a, zxmem[a], self.mem[a]))
        if zvars:
            for zxa, (oa, n) in self.zvars.items():
                for i in range(n):
                    if zxa + i not in ign and self.mem[oa + i] != zxmem[zxa + i]:
                        out.append((zxa + i, zxmem[zxa + i], self.mem[oa + i]))
        return out


def fmt_diffs(d, limit=20):
    return ' '.join('%04X:%02X/%02X' % x for x in d[:limit]) + (' ...(%d)' % len(d) if len(d) > limit else '')


if __name__ == '__main__':
    print(__doc__)
    sys.exit(0)
