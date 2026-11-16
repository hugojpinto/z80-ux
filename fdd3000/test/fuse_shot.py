#!/usr/bin/env python3
"""Run the ZX-UX disk in Fuse (TC3256 FUSE fork) as a TT3000 and take a
screenshot of the terminal.

The TT3000 is the Terminal 3000: the FDD3000 is built in and the terminal
ROM is always running, so ZX-UX boots straight onto its screen.  Fuse is
driven by its FUSE_AUTOKEY harness (keys typed at given frames, @fddreset
for the controller's reset button), and FUSE_AUTOQUIT / FUSE_AUTODUMP dump
both display files of the SCLD's 512-pixel hi-res mode at the end; this
script turns them into a PNG.

    python3 fdd3000/test/fuse_shot.py OUT.png 'root\\r' 'ls\\r' ...

Each argument is typed after the previous one's output had time to show;
~N lets N more frames (1/50 s) go by.  Fuse takes at most 96 keys.
FUSE   the fuse binary (default ../TC3256/EMUL/fuse).
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LOADZX = os.path.dirname(ROOT)
FUSE = os.environ.get('FUSE', os.path.join(LOADZX, 'TC3256', 'EMUL', 'fuse'))
DISK = os.path.join(ROOT, 'build', 'fdd3000', 'ZX-UX-FDD3000.dsk')

KEYGAP = 12           # frames between keys (each is held 4)
BOOT = 400            # frames for the FDD3000 to boot ZX-UX to login:
SETTLE = 150          # frames after each line for its output


# The TT3000 keyboard is an ASCII terminal's: / . , - ; : @ [ \ ] ^ have
# keys of their own (typed as themselves); the rest are Shift (CS) + a key,
# bit-paired as on an ASCII keyboard.
SYM = {'>': '.', '<': ',', '*': ':', '+': ';', '!': '1', '"': '2', '#': '3',
       '$': '4', '%': '5', '&': '6', "'": '7', '(': '8', ')': '9', '=': '-',
       '?': '/'}


def keyspec(lines, first):
    """FUSE_AUTOKEY entries.  Upper case letters are Shift + the key;
    symbols are typed with the TT3000's Symbol Shift layer as Fuse maps
    host characters (the plain character names)."""
    out, f = [], first
    for line in lines:
        if line.startswith('~'):            # ~N: let N frames go by
            f += int(line[1:])
            continue
        for ch in line:
            if ch == '\r':
                out.append('%d:CR' % f)
            elif ch.isupper():
                out.append('%d:CS,%d:%s' % (f, f, ch.lower()))
            elif ch in SYM:
                out.append('%d:CS,%d:%s' % (f, f + 1, SYM[ch]))
            elif ch == ' ':
                out.append('%d: ' % f)
            else:
                out.append('%d:%s' % (f, ch))
            f += KEYGAP
        f += SETTLE
    return ','.join(out), f


def png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def render(d1, d2, path, scale=2):
    """SCLD hi-res: 64 bytes a line, alternately from the two display
    files (4000h, 6000h), Spectrum line order; white on black like the
    TT3000's green-screen-less default."""
    rows = []
    for y in range(192):
        off = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
        line = []
        for x in range(32):
            for b in (d1[off + x], d2[off + x]):
                for bit in range(7, -1, -1):
                    line.append(255 if b >> bit & 1 else 0)
        rows.append(line)
    big = []
    for r in rows:
        rr = [p for p in r for _ in range(1)]
        for _ in range(scale):
            big.append(rr)
    png(path, 512, 192 * scale, big)


def shoot(out_png, lines, disk=DISK, reset_at=60):
    with tempfile.TemporaryDirectory() as t:
        d = os.path.join(t, 'zx.dsk')
        with open(disk, 'rb') as f, open(d, 'wb') as g:
            g.write(f.read())             # AUTOQUIT writes drive A back
        keys, end = keyspec(lines, BOOT)
        spec = '%d:@fddreset' % reset_at + (',' + keys if keys else '')
        dumps = '4000:1800:%s;6000:1800:%s' % (os.path.join(t, 'd1'), os.path.join(t, 'd2'))
        env = dict(os.environ, FUSE_AUTOKEY=spec, FUSE_AUTOQUIT=str(end + 100),
                   FUSE_AUTODUMP=dumps)
        r = subprocess.run([FUSE, '--machine', 'tt3000', '--no-sound',
                            '--timex_fdddisk', d], env=env, capture_output=True,
                           text=True, timeout=600)
        if not os.path.exists(os.path.join(t, 'd1')):
            raise SystemExit('fuse: no dump\n' + r.stdout + r.stderr)
        with open(os.path.join(t, 'd1'), 'rb') as f1, open(os.path.join(t, 'd2'), 'rb') as f2:
            render(f1.read(), f2.read(), out_png)


if __name__ == '__main__':
    shoot(sys.argv[1], [a.encode().decode('unicode_escape') for a in sys.argv[2:]])
