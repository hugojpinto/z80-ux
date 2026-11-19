#!/usr/bin/env python3
"""rbc --ux against rbc: the same BASIC program, the same screen.

    python3 test/basic/uxsame.py [-v] [--frames N] [--part i/n] [name ...]

Each example (examples/basic-src, or the names given: a substring of the
path) is compiled twice - by rbc (the ROM's routines) and by rbc --ux
--rom-ok (libux's clean-room routines, the ROM for those not written
yet) - and both are run on this tree's Spectrum kernel, on the SDK's
headless Spectrum, from the same state with the same keys.  The display
files (pixels and attributes) must match after every step: each
clean-room routine must draw what the ROM's draws.  FRAMES is held at 0
at each frame, so RANDOMIZE seeds RND alike.  The first step is before
any key, and must match; after keys, a program polling INKEY$ can see a
key on another pass of its loop (the routines take other times), so a
difference there is reported, not failed.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'test', 'spectrum'))
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import golden  # noqa: E402
import zxux  # noqa: E402

OUT = os.path.join(ROOT, 'build', 'rbcux')
RBC = os.path.join(ROOT, 'sdk', 'bin', 'rbc')
KEYS = ['1', '\n', 'y', '5', '\n', 'n', ' ', '\n', '2', '\n']     # one per step


def sources(names):
    out = []
    for d, _, files in sorted(os.walk(os.path.join(ROOT, 'examples', 'basic-src'))):
        for f in sorted(files):
            if f.lower().endswith('.bas'):
                p = os.path.join(d, f)
                if not names or any(n.lower() in p.lower() for n in names):
                    out.append(p)
    return out


def compile_(src, ux):
    name = os.path.basename(src)[:-4] + ('.ux' if ux else '') + '.ssx'
    dst = os.path.join(OUT, name)
    if not os.path.exists(dst) or os.path.getmtime(dst) < max(
            os.path.getmtime(src), newest_lib()):
        cmd = [sys.executable, RBC, '-o', dst, src] + (['--ux', '--rom-ok'] if ux else [])
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            return None, (r.stderr.strip().splitlines() or ['?'])[-1]
    return open(dst, 'rb').read(), ''


_NEWEST = []


def newest_lib():
    if not _NEWEST:
        d = os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux')
        _NEWEST.append(max(os.path.getmtime(os.path.join(d, f))
                           for f in ('librbc.ssa', 'libc48.ssa', 'librom.ssa')))
    return _NEWEST[0]


SYSCALL = 0x6003
ROM_OUT = 0x15F2                            # PRINT-A-2: RST 10h's characters and PRINT-FP's digits
START = bytes.fromhex('2101003e27cd0360')    # the wrapper's first instructions: ld hl,1 / ld a,39 / call 6003h
CDRAWN = 0x5C92 + 12                        # dev.asm: the console's cursor is on the screen
EVERY = 40                                  # a picture at every 40th character printed


def run(data, name, frames, steps, entry):
    """-> ({characters printed: display file}, the count before the first key,
    the frame it ended, the final display file, the text)."""
    s = golden.session('build')
    m = s.m
    job = s.launch(data, zxux.program_name(name))
    count = [0]
    shots = {}

    def hit(mm):
        if job.started is not None and job.ended is None:
            count[0] += 1
            if count[0] % EVERY == 0:
                # not while the kernel's cursor is drawn (dev.asm cdrawn): it
                # blinks with time, which the two builds do not share
                pic = None if mm.mem[CDRAWN] else bytearray(mm.mem[0x4000:0x5B00])
                if pic and s.text().split('\n')[23:24] and s.text().split('\n')[23].startswith('1.init'):
                    mask_status(pic)        # the kernel's status line: its clock ticks
                shots[count[0]] = pic and bytes(pic)
        return False
    if not isinstance(entry, tuple):
        m.hooks[entry] = hit
    else:                               # at its first system call (39, the
        sys_hook = m.hooks[SYSCALL]     # wrapper's claim): it is loaded there
        offset = entry[1]

        def first_call(mm):
            if m.hooks.get(SYSCALL) is first_call and mm.cpu.a == 39:
                sp = mm.cpu.sp
                ret = mm.mem[sp] | mm.mem[sp + 1] << 8
                base = ret - len(START)
                if bytes(mm.mem[base:ret]) == START:
                    m.hooks[base + offset] = hit
                    m.hooks[SYSCALL] = sys_hook
            return sys_hook(mm)
        m.hooks[SYSCALL] = first_call
    before = None
    for i in range(steps):
        for _ in range(frames):
            m.mem[0x5C78:0x5C7B] = b'\0\0\0'     # FRAMES: RANDOMIZE's seed, the same
            s.step()
            if job.ended is not None:
                break
        if before is None:
            before = count[0]
        if job.ended is not None:
            break
        s.kb.add(zxux.parse_keys(KEYS[i % len(KEYS)]))
    last = bytearray(job.exit_picture[0] if job.exit_picture else m.mem[0x4000:0x5B00])
    if any(r.startswith('1.init') for r in s.text().split('\n')[23:24]):
        mask_status(last)               # the kernel's status line, as it ended
    return shots, before, job.ended, bytes(last), s.text()


def mask_status(pic):
    """Blank row 23 (pixels and attributes), where the kernel shows its status line."""
    for line in range(184, 192):
        o = (line & 0xC0) << 5 | (line & 7) << 8 | (line & 0x38) << 2
        pic[o:o + 32] = bytes(32)
    pic[6144 + 23 * 32:6144 + 24 * 32] = bytes(32)


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            if i < 6144:
                row = (i >> 5 & 0xC0) | (i >> 2 & 0x38) | (i >> 8 & 7)
                return 'pixels, line %d, column %d' % (row, i & 31)
            return 'attributes, row %d, column %d' % ((i - 6144) >> 5, i & 31)
    return None


def main():
    args = sys.argv[1:]
    verbose = '-v' in args
    frames = 150
    if '--frames' in args:
        frames = int(args[args.index('--frames') + 1])
        del args[args.index('--frames'):args.index('--frames') + 2]
    part = None
    if '--part' in args:                # --part i/n: the i-th of n slices (to keep runs short)
        i, n = args[args.index('--part') + 1].split('/')
        part = (int(i), int(n))
        del args[args.index('--part'):args.index('--part') + 2]
    names = [a for a in args if a != '-v']
    subprocess.run([sys.executable, os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)
    os.makedirs(OUT, exist_ok=True)
    same = differ = skipped = timing = big = 0
    srcs = sources(names)
    if part:
        srcs = srcs[part[0] - 1::part[1]]
    for src in srcs:
        name = os.path.basename(src)[:-4]
        rom, why = compile_(src, False)
        if rom is None:
            skipped += 1
            if verbose:
                print('%-28s skipped: rbc: %s' % (name, why))
            continue
        ux, why = compile_(src, True)
        if ux is None:
            differ += 1
            print('%-28s FAIL: rbc --ux: %s' % (name, why))
            continue
        entry = ROM_OUT                     # the ROM's, or the clean-room @r10 (an offset)
        mp = os.path.join(OUT, name + '.ux.ssx.map')
        if os.path.exists(mp):
            import json
            off = json.load(open(mp)).get('@r10')
            if off is not None:
                entry = ('offset', off)
        a, na, ea, fa, ta = run(rom, name, frames, 4, ROM_OUT)
        b, nb, eb, fb, tb = run(ux, name, frames, 4, entry)
        if 'not enough memory' in tb and 'not enough memory' not in ta:
            big += 1
            print('%-28s too big for the Spectrum with its clean-room routines' % name)
            continue
        bad = late = None
        for k in sorted(set(a) & set(b)):
            if a[k] is None or b[k] is None:
                continue
            d = first_diff(a[k], b[k])
            if d:
                if k <= min(na, nb):
                    bad = 'before any key, at character %d: %s' % (k, d)
                else:
                    late = 'after keys, at character %d: %s' % (k, d)
                break
        if not bad and not late and ea is not None and eb is not None:
            d = first_diff(fa, fb)
            if d:
                bad = 'when both ended: %s' % d
        if late and not bad:
            same += 1
            timing += 1
            if verbose:
                print('%-28s same before keys; differs %s (timing: when INKEY$ sees a key)'
                      % (name, late))
        elif bad:
            differ += 1
            print('%-28s DIFFERS: %s' % (name, bad))
            if verbose:
                print(ta[-400:])
                print('---')
                print(tb[-400:])
        else:
            same += 1
            if verbose:
                print('%-28s same (%d pictures, %s)' % (name, len(set(a) & set(b)),
                                                      'ended' if ea is not None else 'running'))
    print('uxsame: %d the same (%d only before keys), %d differ, %d too big here, '
          '%d not compiled by rbc' % (same, timing, differ, big, skipped))
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main())
