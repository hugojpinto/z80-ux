#!/usr/bin/env python3
"""The screen kinds on the Spectrum (platform/screen-kinds.md).

    python3 test/spectrum/kinds.py

Programs built with rcc --ux, on this tree's Spectrum kernel (and one on
the shipped one), on the SDK's headless Spectrum:
  - hello, fortune (console kind): their text through the kernel's
    console; no display file claimed;
  - colour (console, test/kinds/colour.c): INK and PAPER reach the
    attribute bytes of what the console draws;
  - lines (stream, test/kinds/lines.c): its output redirected to a file,
    which then holds it;
  - mandel (bitmap): it claims the screen and draws; BREAK stops it;
  - mandel on the shipped ZX-UX.tzx, a kernel with no system call 41:
    the runtime falls back to 4000h and it draws all the same.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import golden  # noqa: E402
import zxux  # noqa: E402

OUT = os.path.join(ROOT, 'build', 'kinds')
SRC = {'hello': 'examples/c48-src/examples/hello.c',
       'fortune': 'examples/c48-src/games/fortune.c',
       'mandel': 'examples/c48-src/demos/mandel.c',
       'colour': 'test/kinds/colour.c',
       'lines': 'test/kinds/lines.c'}
KIND = ['stream', 'console', 'bitmap', 'fixed']


def build():
    subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)
    os.makedirs(OUT, exist_ok=True)
    out = {}
    import rld
    for name, src in SRC.items():
        dst = os.path.join(OUT, name + '.ssx')
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'rcc'), '--ux',
                            '-o', dst, os.path.join(ROOT, src)], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('rcc %s: %s%s' % (name, r.stdout, r.stderr))
        data = open(dst, 'rb').read()
        f = rld.parse_ssx(data)['flags']
        out[name] = (data, KIND[f >> 1 & 3] if f & 8 else 'undeclared')
    return out


def run(s, data, name, frames, keys=None):
    job = s.launch(data, name)
    for i in range(frames):
        s.step()
        if keys and i == frames // 2:
            s.kb.add(zxux.parse_keys(keys))
        if job.ended is not None:
            break
    return job


def settle(s, n=50):
    for _ in range(n):
        s.step()


def main():
    progs = build()
    fails = []

    def check(cond, why):
        if not cond:
            fails.append(why)

    for name, want in (('hello', 'console'), ('fortune', 'console'), ('colour', 'console'),
                       ('lines', 'stream'), ('mandel', 'bitmap')):
        check(progs[name][1] == want, '%s is %s, not %s' % (name, progs[name][1], want))

    s = golden.session('build')
    m = s.m
    # console: hello, fortune
    job = run(s, progs['hello'][0], 'hello', 400)
    settle(s)
    text = s.text()
    check(job.ended is not None, 'hello did not end')
    check('hello from c48' in text, 'hello: %r' % text[-200:])
    check(not job.owned, 'hello claimed the screen')
    job = run(s, progs['fortune'][0], 'fortune', 600, keys='q')
    settle(s)
    text = s.text()
    check('C48 FORTUNE' in text, 'fortune: %r' % text[-300:])
    check(not job.owned, 'fortune claimed the screen')
    # console with colour: the attribute bytes
    run(s, progs['colour'][0], 'colour', 300)
    settle(s)
    rows = s.text().split('\n')
    check(rows[5][6:17] == 'red on cyan', 'colour row 5: %r' % rows[5])
    a5 = m.mem[0x5800 + 5 * 32 + 6 // 2]
    a7 = m.mem[0x5800 + 7 * 32 + 6 // 2]
    check(a5 == (5 << 3) | 2, 'red on cyan: attribute %02X, not 2A' % a5)
    check(a7 == 7, 'plain: attribute %02X, not 07' % a7)
    # stream: redirected
    import rtap
    s.kb.type('cls\n')
    s.wait_prompt()
    m.cassette.extend(rtap.records(progs['lines'][0], 'lines'))
    s.kb.type('/dev/cassette/lines > /tmp/out\n')
    s.wait_prompt(6000)
    s.kb.type('cat /tmp/out\n')
    s.wait_prompt()
    text = s.text()
    check('1 line\n2 line\n3 line' in text, 'lines > /tmp/out: %r' % text[-200:])
    # bitmap: mandel draws, BREAK stops it
    s.kb.type('cls\n')
    s.wait_prompt()
    job = run(s, progs['mandel'][0], 'mandel', 2500)     # it computes before it draws
    check(job.owned, 'mandel did not claim the screen')
    check('#' in s.text(), 'mandel drew nothing')
    s.kb.add(zxux.parse_keys('{BREAK}'))
    s.wait_prompt(6000)
    check(job.ended is not None, 'BREAK did not stop mandel')

    # the shipped kernel: no call 41
    t = golden.session('shipped')
    job = run(t, progs['mandel'][0], 'mandel', 2500)
    check(job.owned and '#' in t.text(), 'mandel on the shipped kernel drew nothing')
    t.kb.add(zxux.parse_keys('{BREAK}'))
    t.wait_prompt(6000)

    for f in fails:
        print('FAIL:', f)
    print('kinds: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
