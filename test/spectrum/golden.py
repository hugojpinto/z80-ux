#!/usr/bin/env python3
"""Golden behaviour tests for the Spectrum build of ZX-UX.

    python3 test/spectrum/golden.py record      sessions on the shipped tape
                                                 -> test/spectrum/golden/*.txt
    python3 test/spectrum/golden.py check       the same sessions on this
                                                 tree's build: must match
    python3 test/spectrum/golden.py show NAME    print one session (this build)

Why: z80-ux restructures the kernel (platform/DESIGN.md), so the Spectrum
build no longer equals the shipped tape byte for byte.  What must stay
equal is what ZX-UX does.  Each session boots ZX-UX on the SDK's headless
48K Spectrum (sdk/bin/py: zxmachine, zxux - the same machine rvm uses),
logs in, types commands as a person does and records the screen, as text,
after each one.  `record` runs them on the shipped ZX-UX.tzx; `check` on
the kernel built from this tree (build.py's spectrum target), booted by
the same tape bootstrap with this tree's image in place of the shipped one.

Masked before comparing (they may differ between builds without ZX-UX
behaving differently): the status line (row 23: the clock); hh:mm:ss times;
free memory and the kernel's size in the boot banner and in df; the order
in which forktest's parent and child print (their counts stay).  Anything
else that differs is a change of behaviour.
"""
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
GOLDEN = os.path.join(HERE, 'golden')
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import zxmachine  # noqa: E402
import zxux  # noqa: E402

SSX = os.path.join(ROOT, 'examples', 'c48-bin', 'ssx')

# A session: a name and steps.  A step is a command typed at the prompt
# (str), or a tuple: ('keys', text, frames) - keys (zxux.parse_keys
# syntax) then that many frames, no prompt awaited; ('tape',) - what was
# saved goes back in the cassette, rewound; ('run', program, frames) - an
# SSX1 program from examples/c48-bin/ssx, launched from the cassette, run
# for that many frames, then BREAK if it is still running (a fourth item:
# only the prompt line is recorded, the picture depends on timing; a cls
# after it keeps what is left of it out of the next screens).
SESSIONS = [
    ('files', [
        'ls /', 'ls /bin', 'ls -l /etc', 'mkdir /tmp/d', 'echo hello > /tmp/d/f',
        'cat /tmp/d/f', 'cp /tmp/d/f /tmp/d/g', 'mv /tmp/d/g /tmp/d/h',
        'ln /tmp/d/h /tmp/d/i', 'ls -l /tmp/d', 'cmp /tmp/d/f /tmp/d/h',
        'wc /tmp/d/f', 'od /tmp/d/f', 'sum /tmp/d/f', 'chmod 4 /tmp/d/f',
        'stat /tmp/d/f', 'rm /tmp/d/i', 'rmdir /tmp/d', 'du /tmp', 'df',
        'cd /tmp/d', 'pwd', 'ls', 'cd /', 'rm /tmp/d/f /tmp/d/h', 'rmdir /tmp/d',
        'ls /tmp', 'cat /nosuch',
    ]),
    ('shell', [
        'echo a; echo b', 'echo /bin/c*', 'echo one > /tmp/x', 'echo two >> /tmp/x',
        'cat < /tmp/x', 'echo echo from a script > /tmp/s', 'sh /tmp/s', 'nosuch',
        'cat /tmp/x /tmp/s', 'more /etc/motd',
    ]),
    ('procs', [
        'sleep 2 &', 'ps', 'date', 'sleep 3', 'ps', 'forktest',
        ('keys', 'clock\n', 150), ('keys', '{BREAK}', 100), 'echo after clock',
        ('keys', 'cat\n', 100), ('keys', '{BREAK}', 100), 'echo after break',
    ]),
    ('pack', [
        'cp /usr/doc/tar /tmp/t', 'ls -l /tmp', 'zxpack /tmp/t', 'ls -l /tmp',
        'cmp /usr/doc/tar /tmp/t', 'df', 'more /usr/doc/more',
    ]),
    ('vi', [
        ('keys', 'vi /tmp/n\n', 150), ('keys', 'ihello from vi{EDIT}:wq\n', 300),
        'cat /tmp/n', 'ls -l /tmp',
    ]),
    ('tape', [
        'echo on the tape > /tmp/td', 'tar cvf /dev/cassette/x /tmp/td', ('tape',),
        'rm /tmp/td', 'tar xvf /dev/cassette/x', 'cat /tmp/td',
    ]),
    ('ssx', [
        ('run', 'hello', 300), 'echo back',
        # BREAK a program that computes in user mode: the frame interrupt
        # delivers it (cat, above, is stopped inside a system call)
        ('run', 'mandel', 150, 'break'), 'cls', 'echo after mandel',
        # spin: one instruction, JR $; it never calls the kernel, so only
        # the frame interrupt can preempt it and deliver BREAK
        ('run', 'spin', 100, 'break'), 'cls', 'echo after spin',
    ]),
]

MASKS = [
    (re.compile(r'\b\d\d:\d\d:\d\d\b'), 'hh:mm:ss'),
    (re.compile(r'free=\d+B'), 'free=NB'),
    (re.compile(r'kernel \d+B'), 'kernel NB'),
    (re.compile(r'^\d+ bytes free', re.M), 'N bytes free'),
]


FORK = re.compile(r'^[Pc]{8,}$', re.M)   # forktest: parent and child take turns


def mask(text):
    for rx, rep in MASKS:
        text = rx.sub(rep, text)
    # forktest's interleaving follows the scheduler's timing, which may move
    # with the code; what it printed may not: count the letters
    return FORK.sub(lambda m: 'forktest: %d P, %d c' % (m.group().count('P'),
                                                         m.group().count('c')), text)


def spin_ssx():
    """An SSX1 program of one instruction, JR $: no system call, ever."""
    import struct
    import rld
    image = b'\x18\xfe'
    hdr = b'SSX1' + struct.pack('<BBHHHHHH', 0, rld.SSX_HDR, len(image), 0, 64, 0, 0, 0)
    return hdr + struct.pack('<H', rld.fletcher16(hdr + image)) + image


# ---------------------------------------------------------------------
class BuildImage:
    """This tree's Spectrum kernel, in place of the shipped image: the tape
    bootstrap (the shipped one) copies it to 5D98h and jumps to 6000h."""

    def __init__(self, shipped):
        import build
        top, src, sym, fsimg, free = build.kernel('spectrum')
        low = build.read(os.path.join(src, 'lowk.bin'))
        unix = build.read(os.path.join(src, 'unix.bin'))
        lo = 0x5D98
        img = bytearray(sym['ITAB'] + len(fsimg) - lo)
        for addr, data in ((sym['LOWK'], low), (sym['KBASE'], unix), (sym['ITAB'], fsimg)):
            img[addr - lo:addr - lo + len(data)] = data
        self.tape = shipped.tape
        self.blocks = shipped.blocks
        self.merged = bytes(img)
        self.sha256 = hashlib.sha256(self.merged).hexdigest()
        self.sym = {k: sym[k] for k in ('NPROC', 'SFREE', 'p_stat', 'p_pid', 'cur', 'scrown')}
        self.syscall = 0x6003


def session(image='shipped'):
    s = zxux.Session(cache=False)
    if image == 'build':
        s.system = BuildImage(s.system)
        y = s.system.sym
        s._p_pid, s._p_stat, s._cur = y['p_pid'], y['p_stat'], y['cur']
        s._scrown, s._nproc, s._sfree = y['scrown'], y['NPROC'], y['SFREE']
    # The kernel enters SA-BYTES at 04D0h (the short pilot, dev.asm
    # rom_save_short), past the emulator's 04C2h trap: trap it there too
    # (053Fh, the ROM's cleanup, is on the stack: the trap returns to it).
    s.m.hooks[0x04D0] = zxmachine.Machine._sa_bytes
    s.boot()
    return s


def screen(s):
    rows = s.text().split('\n')
    return '\n'.join(rows[:23]).rstrip('\n')


def run_session(name, steps, image):
    s = session(image)
    out = ['=== %s: boot' % name, screen(s)]
    for step in steps:
        if isinstance(step, str):
            s.kb.add(zxux.parse_keys(step + '\n'))
            s.wait_prompt(6000)
            label = step
        elif step[0] == 'keys':
            s.kb.add(zxux.parse_keys(step[1]))
            for _ in range(step[2]):
                s.step()
            label = 'keys %r' % step[1]
        elif step[0] == 'tape':
            s.m.cassette = list(s.m.saved)
            s.m.saved = []
            label = 'tape: %d blocks rewound' % len(s.m.cassette)
        elif step[0] == 'run':
            if step[1] == 'spin':
                ssx = spin_ssx()
            else:
                with open(os.path.join(SSX, step[1] + '.ssx'), 'rb') as f:
                    ssx = f.read()
            job = s.launch(ssx, step[1])
            for _ in range(step[2]):
                s.step()
                if job.ended is not None:
                    break
            if job.ended is None:
                s.kb.add(zxux.parse_keys('{BREAK}'))
            s.wait_prompt(6000)
            label = 'run %s' % step[1]
            if len(step) > 3:           # what it drew depends on timing:
                label += ', BREAK'      # only that BREAK brought the prompt back
                out.append('=== %s: %s' % (name, label))
                out.append(s.last_line())
                continue
        out.append('=== %s: %s' % (name, label))
        out.append(screen(s))
    return mask('\n'.join(out)) + '\n'


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if cmd == 'show':
        name = sys.argv[2]
        steps = dict(SESSIONS)[name]
        sys.stdout.write(run_session(name, steps, 'build'))
        return 0
    if cmd not in ('record', 'check'):
        print(__doc__)
        return 2
    image = 'shipped' if cmd == 'record' else 'build'
    os.makedirs(GOLDEN, exist_ok=True)
    fails = 0
    for name, steps in SESSIONS:
        try:
            got = run_session(name, steps, image)
        except zxux.RvmError as e:
            print('%-6s ERROR %s' % (name, str(e).split('\n')[0]))
            fails += 1
            continue
        path = os.path.join(GOLDEN, name + '.txt')
        if cmd == 'record':
            with open(path, 'w') as f:
                f.write(got)
            print('%-6s recorded (%d lines)' % (name, got.count('\n')))
            continue
        want = open(path).read()
        if got == want:
            print('%-6s ok' % name)
            continue
        fails += 1
        import difflib
        print('%-6s DIFFERS' % name)
        for line in list(difflib.unified_diff(want.split('\n'), got.split('\n'),
                                              'golden', 'build', lineterm='', n=1))[:40]:
            print('   ' + line)
    if cmd == 'check':
        print('golden: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
