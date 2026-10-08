#!/usr/bin/env python3
"""Test view.s (S862E): buffer/colour clearing must match the original
exactly; the Oric picture is written next to the Spectrum one as PNGs for
visual comparison.   usage: test_view.py [outdir]"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
from zxref import Ref                         # noqa: E402
from sim6502 import Sim, fmt_diffs            # noqa: E402
import harness                                # noqa: E402
import zxscreen                               # noqa: E402
from PIL import Image                         # noqa: E402

PAL = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0),
       (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]


def oric_img(ram):
    w, h, rgb = harness.render(ram)
    return Image.frombytes('RGB', (w, h), bytes(rgb))


def zx_img(mem):
    rows = zxscreen.decode(mem[0x4000:0x5B00])
    im = Image.new('RGB', (256, 192))
    im.putdata([PAL[c] for r in rows for c in r])
    return im


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'build/test_view'
    os.makedirs(out, exist_ok=True)
    os.system('python3 tools/buildtest.py view src/view.s data/view_data.s >/dev/null')
    sim = Sim('build/test_view.bin', keep_holes=True)   # its tables are in HOLE2
    sim.mem[0xBFDF] = 0x1E
    sim.call('view_init')
    total = bad = 0
    for city in '1234':
        r = Ref()
        r.to_game(city, '8')
        r.hold('S')
        samples = r.capture(0x862E, n=4, frames=1500, keyfn=Ref.random_driver(int(city)), skip=3)
        r.release()
        r.hold('M')                                # map view
        samples += r.capture(0x862E, n=1, frames=200, skip=2)
        for k, s in enumerate(samples):
            sim.load_state(s.pre_mem, s.pre)
            cyc = sim.call('Z_862E')
            d = sim.compare(s.post_mem, zvars=True, ignore=[(0x71D0, 0x7300), 0x74F9, 0x74FA])
            total += 1
            if d:
                bad += 1
                print('city', city, k, 'DIFF', fmt_diffs(d))
            a = zx_img(s.post_mem).resize((512, 384), Image.NEAREST)
            b = oric_img(sim.mem).resize((480, 448), Image.NEAREST)
            im = Image.new('RGB', (1000, 448))
            im.paste(a, (0, 32))
            im.paste(b, (520, 0))
            im.save(os.path.join(out, 'view_%s_%d.png' % (city, k)))
            print('city', city, 'sample', k, 'cycles', cyc)
    print('%d samples, %d with differences' % (total, bad))


if __name__ == '__main__':
    main()
