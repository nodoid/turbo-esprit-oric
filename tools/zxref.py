#!/usr/bin/env python3
"""Reference runs of the original Spectrum game, for differential testing.

Needs the `zx` Spectrum emulator package (pip install zx; Python >= 3.10)
and the original tape in orig/TurboEsprit.tzx.

    from zxref import Ref
    r = Ref()                        # boot, legal screens, city select
    r.to_game(city='1', option='8')  # '8' PLAY, '7' PRACTICE
    r.hold('S')                      # accelerate
    samples = r.capture(0x893C, n=20, frames=2000, keyfn=Ref.random_driver(1))
    s = samples[0]; s.pre_mem / s.post_mem (64K bytes), s.pre / s.post (regs),
    s.rvals = values loaded by "ld a,r" while the routine ran.
"""
import os
import random
import sys

import zx
import zx._keyboard as _kbd
from zx._device import KeyStroke

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zxtape  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TAPE = os.path.join(HERE, '..', 'orig', 'TurboEsprit.tzx')

REGS = ['af', 'bc', 'de', 'hl', 'ix', 'iy', 'sp', 'pc',
        'alt_af', 'alt_bc', 'alt_de', 'alt_hl']

# addresses of every "ld a,r" (ED 5F) in the game
LD_A_R = [0x9096, 0x9193, 0x93E5, 0xA5E3, 0xAC5D, 0xB170, 0xE990, 0xF62C, 0xF71B, 0xF9FD]


class Sample:
    def __init__(self, pre, pre_mem):
        self.pre, self.pre_mem = pre, pre_mem
        self.post = self.post_mem = None
        self.rvals = []


class Ref:
    def __init__(self, tape=TAPE):
        _kbd.Keyboard._state[:] = [0xFF] * 8   # class-level state: reset it
        self.z = zx.Spectrum(headless=True)
        self.frame = 0
        self.held = set()
        self.run(120)                          # ROM boot to BASIC
        img = zxtape.load_image(tape)
        self.poke(0x4000, img[0x4000:0x5C00])
        self.poke(26731, img[26731:0x10000])
        self.poke(23624, [0])
        self.poke(23659, [2])
        sp = 26620
        self.poke(sp, [0x2D, 0x2B])
        self.z.sp = sp
        self.z.pc = 64785
        self.z.on_breakpoint = lambda: None

    # --- basic control -------------------------------------------------
    def run(self, n=1):
        self.z.run(duration=n / 50.0, fast_forward=True)
        self.frame += n

    def peek(self, a, n=1):
        return self.z.read(a, n)

    def poke(self, a, data):
        data = bytes(data)
        if a + len(data) <= 0xC000:
            self.z.write(a, data, ram_page=0)
            return
        if a < 0xC000:
            n = 0xC000 - a
            self.z.write(a, data[:n], ram_page=0)
            a, data = 0xC000, data[n:]
        # the zx package drops the offset inside the top bank: rewrite it whole
        bank = bytearray(self.z.read(0xC000, 0x4000))
        bank[a - 0xC000:a - 0xC000 + len(data)] = data
        self.z.write(0xC000, bytes(bank), ram_page=0)

    def key(self, k, down):
        self.z.devices.notify(KeyStroke(k.upper() if len(k) == 1 else k, pressed=down))
        (self.held.add if down else self.held.discard)(k)

    def hold(self, k):
        self.key(k, True)

    def release(self, k=None):
        for h in ([k] if k else list(self.held)):
            self.key(h, False)

    def press(self, k, n=5):
        self.key(k, True)
        self.run(n)
        self.key(k, False)
        self.run(n)

    def mem(self):
        return bytes(self.z.read(0, 0x10000))

    def regs(self):
        return {r: getattr(self.z, r) for r in REGS}

    # --- navigation ----------------------------------------------------
    def to_menu(self, city='1'):
        self.run(30)
        self.press('SPACE')
        self.run(30)
        self.press('SPACE')
        self.run(100)
        self.press(city, 20)
        self.run(50)

    def to_game(self, city='1', option='8', settle=300):
        self.to_menu(city)
        self.press(option, 40)
        self.run(settle)

    # --- capture -------------------------------------------------------
    def capture(self, entry, n=20, frames=3000, keyfn=None, skip=0):
        """Record state at `entry` and when it returns, for up to n calls
        (after skipping `skip` calls) within `frames` frames."""
        z = self.z
        samples = []
        st = {'cur': None, 'sp': None, 'ret': None, 'seen': 0}

        def bp():
            pc = z.pc
            if st['cur'] is not None:
                if pc == st['ret'] and z.sp == st['sp'] + 2:
                    st['cur'].post = self.regs()
                    st['cur'].post_mem = self.mem()
                    samples.append(st['cur'])
                    st['cur'] = None
                    return
                if pc in rpost:
                    st['cur'].rvals.append(z.af >> 8)
                return
            if pc == entry and len(samples) < n:
                st['seen'] += 1
                if st['seen'] <= skip:
                    return
                st['cur'] = Sample(self.regs(), self.mem())
                st['sp'] = z.sp
                st['ret'] = int.from_bytes(z.read(z.sp, 2), 'little')
                z.set_breakpoint(st['ret'])
        rpost = set(a + 2 for a in LD_A_R)
        z.on_breakpoint = bp
        z.set_breakpoint(entry)
        for a in rpost:
            z.set_breakpoint(a)
        for f in range(frames):
            if keyfn:
                keyfn(self, f)
            self.run(1)
            if len(samples) >= n:
                break
        z.on_breakpoint = lambda: None
        return samples

    @staticmethod
    def random_driver(seed=1, period=10):
        """keyfn: random steering/throttle/fire, re-chosen every `period` frames."""
        rng = random.Random(seed)
        probs = {'S': 0.6, 'J': 0.2, 'L': 0.2, 'K': 0.3, 'A': 0.1}

        def fn(ref, f):
            if f % period == 0:
                ref.release()
                for k, p in probs.items():
                    if rng.random() < p:
                        ref.hold(k)
        return fn
