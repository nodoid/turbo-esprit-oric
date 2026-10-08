#!/usr/bin/env python3
"""Build a test binary from a subset of modules, stubbing missing symbols.

usage: buildtest.py NAME module.s [module.s ...]
  -> build/test_NAME.bin / .lbl / .map  (load at $0600, see sim6502.py)

src/zx.s and src/hw.s... are NOT added automatically except src/zx.s (the
shared register file).  Every symbol imported but not defined by the given
modules becomes a stub: an exported label on its own RTS (followed by 15
spare bytes, so small data references do not overlap code).  The stub names
are printed, so a test can tell when a stub got called (sim.sym[name]).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


def main():
    name = sys.argv[1]
    mods = sys.argv[2:]
    if 'src/zx.s' not in mods:
        mods = ['src/zx.s'] + mods
    out = os.path.join('build', 'test_' + name)
    os.makedirs(os.path.join(ROOT, out), exist_ok=True)
    objs = []
    for m in mods:
        o = os.path.join(out, os.path.basename(m).replace('.s', '.o'))
        r = run(['ca65', '-g', '-I', 'src', '-I', 'data', '--bin-include-dir', 'data', '-o', o, m])
        if r.returncode:
            sys.stderr.write(r.stdout + r.stderr)
            sys.exit(1)
        objs.append(o)
    base = os.path.join('build', 'test_' + name)
    stubs = []
    for attempt in range(2):
        cmd = ['ld65', '-C', 'src/turbo.cfg', '-m', base + '.map', '-Ln', base + '.lbl',
               '--dbgfile', base + '.dbg', '-o', base + '.bin'] + objs
        r = run(cmd)
        if r.returncode == 0:
            break
        miss = re.findall(r"Unresolved external '([^']+)'", r.stdout + r.stderr)
        if not miss or attempt:
            sys.stderr.write(r.stdout + r.stderr)
            sys.exit(1)
        stubs = sorted(set(miss))
        src = os.path.join(out, 'stubs.s')
        with open(os.path.join(ROOT, src), 'w') as f:
            f.write('; generated stubs\n        .code\n')
            for s in stubs:
                f.write('        .export %s\n%s:     rts\n        .res 15\n' % (s, s))
        so = os.path.join(out, 'stubs.o')
        r2 = run(['ca65', '-o', so, src])
        if r2.returncode:
            sys.stderr.write(r2.stdout + r2.stderr)
            sys.exit(1)
        objs.append(so)
    for line in r.stderr.splitlines():
        if 'Warning' in line and 'does not exist' not in line:
            sys.stderr.write(line + '\n')
    if stubs:
        print('stubs:', ' '.join(stubs))
    print('built', base + '.bin')


if __name__ == '__main__':
    main()
