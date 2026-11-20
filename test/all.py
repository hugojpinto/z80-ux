#!/usr/bin/env python3
"""Every check of the tree, in order: the builds, then the suites.

    python3 test/all.py [--quick] [name ...]

The builds (the kernels and the FDD3000 image - upstream's must stay
identical to ZX-UX.tzx - and libux), then each suite; a line for each,
and the total.  --quick leaves out the slow ones (the float engine's and
the routines' random runs at full count).  Names: only the suites whose
name contains one of them.  (test/basic/uxsame.py, rbc against rbc --rom48k
on every example, takes about 25 minutes: run it by hand, by name.)
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable

BUILDS = [
    ('build', ['fdd3000/tools/build.py']),
    ('libux', ['sdk/bin/py/libux/build.py']),
]
FDD = ['fd', 'zfs', 'boot', 'ssx', 'tmr', 'bound', 'fsmod', 'tfs', 'kinds', 'basic']
SUITES = [
    ('spectrum/golden', ['test/spectrum/golden.py', 'check'], False),
    ('spectrum/kinds', ['test/spectrum/kinds.py'], False),
] + [('fdd3000/' + t, ['fdd3000/test/test_%s.py' % t], False) for t in FDD] + [
    ('fp/engine', ['test/fp/fptest.py', '300'], True),
    ('fp/strings', ['test/fp/strtest.py'], True),
    ('tc3256/probe', ['tc3256/test/test_probe.py'], False),
    ('tc3256/boot', ['tc3256/test/test_boot.py'], False),
    ('tc3256/disk', ['tc3256/test/test_disk.py'], False),
    ('basic/romdiff', ['test/basic/romdiff.py', '40'], True),
    ('basic/romdiff-clean', ['test/basic/romdiff.py', '20', 'RST28'], True),
]
QUICK = {'fp/engine': ['test/fp/fptest.py', '40'], 'fp/strings': ['test/fp/strtest.py', '200'],
         'basic/romdiff': ['test/basic/romdiff.py', '8']}


def run(name, args, env=None):
    t = time.time()
    r = subprocess.run([PY] + args, cwd=ROOT, capture_output=True, text=True,
                       env=dict(os.environ, **(env or {})))
    out = (r.stdout + r.stderr).strip().splitlines()
    ok = r.returncode == 0
    print('%-22s %s  %4.0fs  %s' % (name, 'ok  ' if ok else 'FAIL', time.time() - t,
                                    out[-1][:70] if out else ''))
    if not ok:
        for line in out[-12:]:
            print('    ' + line)
    return ok


def main():
    args = sys.argv[1:]
    quick = '--quick' in args
    names = [a for a in args if a != '--quick']
    fails = []
    for name, cmd in BUILDS:
        if not run(name, cmd):
            fails.append(name)
    upstream = subprocess.run([PY, 'fdd3000/tools/build.py', 'upstream'], cwd=ROOT,
                              capture_output=True, text=True)
    same = upstream.returncode == 0 and 'differs' not in upstream.stdout
    print('%-22s %s' % ('upstream identical', 'ok' if same else 'FAIL'))
    if not same:
        fails.append('upstream identical')
    for name, cmd, slow in SUITES:
        if names and not any(n in name for n in names):
            continue
        if quick and slow and name in QUICK:
            cmd = QUICK[name]
        env = {'ROMDIFF_ENGINE': 'clean'} if name.endswith('-clean') else None
        if not run(name, cmd, env):
            fails.append(name)
    print('all: %s' % ('FAIL: ' + ', '.join(fails) if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
