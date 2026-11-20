#!/usr/bin/env python3
"""The TC3256, started from disk, in Fuse (the LoadZX fork, TC3256/EMUL).

    python3 tc3256/test/tc3256run.py BOOT.bin [DUMP ...]

A new TOS system disk, made by tomato (-new tos40: TOS on its tracks 0-3,
which the FDD3000 boots and loads its overlays from), gets the file BOOT
- TOS's CODE form: type 3, length, start 8000h, the bytes.  Fuse starts a TC3256 with the
Timex FDD, the boot menu's key 4 ("Disk start") is pressed, and at the end
the memory named (FUSE_AUTODUMP: hex address and length) is read back, the
link's traffic too if asked (FUSE_LINK_TRACE).  Fuse's harness: its
spectrum.c (FUSE_AUTOKEY, FUSE_AUTOQUIT, FUSE_AUTODUMP).

FUSE    the fuse binary (default ../TC3256/EMUL/fuse).
TOMATO  the tomato binary (default ../tomato/tomato).
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LOADZX = os.path.dirname(ROOT)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import dsk  # noqa: E402
import tosfs  # noqa: E402

FUSE = os.environ.get('FUSE', os.path.join(LOADZX, 'TC3256', 'EMUL', 'fuse'))
TOMATO = os.environ.get('TOMATO', os.path.join(LOADZX, 'tomato', 'tomato'))
SJASMPLUS = os.environ.get('SJASMPLUS', os.path.join(ROOT, 'fdd3000', 'tools', 'bin', 'sjasmplus'))

CODE = 3                # TOS's file types (the shadow ROM's LOADP): 3 a CODE file
BOOT_AT = 0x8000        # where Disk start loads BOOT (the shadow ROM, BOOT_KEY4_DISK)
MENU_KEY = 400          # the frame the boot menu's key is pressed at
QUIT = 3000             # ... and the one Fuse stops at (50 a second)


def code_file(data, start=BOOT_AT):
    """TOS's CODE file: its type, length and start, then the bytes."""
    return bytes([CODE]) + struct.pack('<HH', len(data), start) + data


def assemble(src, out):
    """sjasmplus SRC in its own directory -> the bytes of OUT it saves."""
    d = os.path.dirname(os.path.abspath(src))
    r = subprocess.run([SJASMPLUS, '--nologo', '--msg=war', os.path.basename(src)],
                       cwd=d, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('sjasmplus %s:\n%s%s' % (src, r.stdout, r.stderr))
    p = os.path.join(d, out)
    with open(p, 'rb') as f:
        data = f.read()
    os.remove(p)
    return data


def disk_with(boot, work):
    """A new TOS system disk (tomato) with BOOT on it."""
    path = os.path.join(work, 'tos.dsk')
    r = subprocess.run([TOMATO, '-new', 'tos40', '-saveas', path], capture_output=True, text=True)
    if r.returncode or not os.path.exists(path):
        raise SystemExit('tomato: %s%s' % (r.stdout, r.stderr))
    d = dsk.Disk.load(path)
    tosfs.TOS(d).put('BOOT', code_file(boot))
    return d


def run(boot, dumps, trace=False, key='4', quit=QUIT):
    """Disk start BOOT -> {(addr, len): bytes}, the link's trace (or None)."""
    with tempfile.TemporaryDirectory() as t:
        dpath = os.path.join(t, 'a.dsk')
        disk_with(boot, t).save(dpath)
        files = {(a, n): os.path.join(t, 'd%04X' % a) for a, n in dumps}
        env = dict(os.environ, FUSE_AUTOKEY='%d:%s' % (MENU_KEY, key), FUSE_AUTOQUIT=str(quit),
                   FUSE_AUTODUMP=';'.join('%X:%X:%s' % (a, n, files[a, n]) for a, n in dumps))
        if trace:
            env['FUSE_LINK_TRACE'] = os.path.join(t, 'link.txt')
        r = subprocess.run([FUSE, '--machine', 'tc3256', '--no-sound', '--timex-fdd',
                            '--timex_fdddisk', dpath], env=env, capture_output=True,
                           text=True, timeout=900)
        out = {}
        for k, p in files.items():
            if not os.path.exists(p):
                raise SystemExit('fuse: no dump %04X\n%s%s' % (k[0], r.stdout, r.stderr))
            with open(p, 'rb') as f:
                out[k] = f.read()
        tr = None
        if trace and os.path.exists(env['FUSE_LINK_TRACE']):
            with open(env['FUSE_LINK_TRACE']) as f:
                tr = f.read()
        return out, tr


if __name__ == '__main__':
    with open(sys.argv[1], 'rb') as f:
        boot = f.read()
    dumps = [tuple(int(x, 16) for x in a.split(':')) for a in sys.argv[2:]] or [(0x4000, 0x1B00)]
    got, _ = run(boot, dumps)
    for (a, n), b in got.items():
        print('%04X: %s' % (a, b[:64].hex()))
