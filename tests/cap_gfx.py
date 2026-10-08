#!/usr/bin/env python3
"""Capture real-game samples for tests/test_gfx.py (zxref).
usage: cap_gfx.py CITY OUT.pkl [frames]"""
import os
import pickle
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from zxref import Ref, Sample  # noqa: E402

INLINE = {0xBA5F, 0xBA72, 0xBA6A, 0xBA56}


def inline_end(mem, p):
    """end of BA72-style inline data at p (C, N, items)"""
    n = mem[p + 1]
    q = p + 2
    for _ in range(n):
        q += 3 if mem[q] >= 0xC0 else 1
    return q


def capture_multi(r, entries, n, frames, keyfn):
    """samples for several entries (one at a time, not nested)"""
    z = r.z
    out = {e: [] for e in entries}
    st = {'cur': None}

    def bp():
        pc = z.pc
        if st['cur'] is not None:
            e, s, sp, ret = st['cur']
            if pc == ret and (z.sp == sp + 2 or e in INLINE):
                s.post = r.regs()
                s.post_mem = r.mem()
                out[e].append(s)
                st['cur'] = None
                z.clear_breakpoint(ret) if hasattr(z, 'clear_breakpoint') else None
            return
        if pc in out and len(out[pc]) < n:
            s = Sample(r.regs(), r.mem())
            ret = int.from_bytes(z.read(z.sp, 2), 'little')
            if pc in INLINE:
                ret = inline_end(s.pre_mem, ret)
            st['cur'] = (pc, s, z.sp, ret)
            z.set_breakpoint(ret)
    z.on_breakpoint = bp
    for e in entries:
        z.set_breakpoint(e)
    for f in range(frames):
        keyfn(r, f)
        r.run(1)
        if all(len(v) >= n for v in out.values()):
            break
    z.on_breakpoint = lambda: None
    return out


def main():
    city, path = sys.argv[1], sys.argv[2]
    frames = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    r = Ref()
    r.to_menu(city)
    r.press('8', 40)
    # the dashboard drawing itself
    first = capture_multi(r, [0x9E1E], 1, 400, lambda ref, f: None)
    drive = Ref.random_driver(int(city) * 7 + 1)

    def keyfn(ref, f):
        drive(ref, f)
        if f % 400 == 200:
            ref.hold('M')
        if f % 400 == 230:
            ref.release('M')
    s = capture_multi(r, [0xA36F, 0xA41E, 0xA094, 0xA496, 0xA487, 0xBAB8, 0xBB18, 0xBA5F,
                          0xA695, 0xA526, 0xA911], 12, frames, keyfn)
    s.update(first)
    for k, v in sorted(s.items()):
        print('%04X: %d' % (k, len(v)))
    pickle.dump(s, open(path, 'wb'))


if __name__ == '__main__':
    main()
