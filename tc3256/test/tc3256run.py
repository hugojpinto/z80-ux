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
SPEED = os.environ.get('FUSE_SPEED', '1000')   # Fuse's emulation speed, %: frames count, not seconds
KEYGAP = 12             # frames between typed keys (Fuse holds each 4)
AUTOKEY_MAX = 96        # Fuse's harness takes this many entries at most (spectrum.c)
SETTLE = 150            # frames after a line for its output
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
        r = subprocess.run([FUSE, '--machine', 'tc3256', '--no-sound', '--speed', SPEED, '--timex-fdd',
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


FONT = os.path.join(ROOT, 'zx-ux', 'src', 'font4x8.bin')   # the console's characters


def screen_text(d):
    """The console's 64 columns x 24 rows, read from a display file (4000h,
    6144 bytes) by its own 4x8 font: '?' where a cell is no character."""
    with open(FONT, 'rb') as f:
        font = f.read()[8:8 + 384]
    glyphs = {}
    for g in range(96):
        rows = tuple(n for b in font[g * 4:g * 4 + 4] for n in (b >> 4, b & 15))
        glyphs.setdefault(rows, chr(0x20 + g))
    out = []
    for row in range(24):
        line = ''
        for col in range(64):
            nibs = []
            for k in range(8):
                y = row * 8 + k
                a = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (col >> 1)
                b = d[a]
                nibs.append(b >> 4 if not col & 1 else b & 15)
            line += glyphs.get(tuple(nibs), '?')
        out.append(line.rstrip())
    return '\n'.join(out)


FONT8 = os.path.join(ROOT, 'drivers', 'font8', 'font8.txt')  # the 32-column console's


def screen_text8(d):
    """The narrow console's 32 columns x 24 rows: 8x8 characters of
    drivers/font8 (a cell a byte column), '?' where a cell is none."""
    glyphs, cur = {}, None
    with open(FONT8) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith(';'):
                continue
            if line.startswith('= '):
                cur = int(line[2:], 16)
                glyphs[cur] = []
            else:
                glyphs[cur].append(int(line.replace('#', '1').replace('.', '0'), 2))
    table = {}
    for c, rows in sorted(glyphs.items(), reverse=True):
        table[tuple(rows)] = chr(c)
    out = []
    for row in range(24):
        line = ''
        for col in range(32):
            cell = []
            for k in range(8):
                y = row * 8 + k
                cell.append(d[((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | col])
            line += table.get(tuple(cell), '?')
        out.append(line.rstrip())
    return '\n'.join(out)


def pixel(d, x, y):
    """The display file's pixel at x (0-255), y (0-191, from the top)."""
    return d[((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)] >> (7 - (x & 7)) & 1


def _keyboard():
    sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'kbd', os.path.join(ROOT, 'sdk', 'bin', 'py', 'libux', 'rbc', 'keyboard.py'))
    kb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kb)
    return kb


def keys(lines, first):
    """FUSE_AUTOKEY entries typing LINES on the Spectrum keyboard from
    frame FIRST (a symbol: SYMBOL SHIFT + its key, keyboard.py's; a
    capital: CAPS SHIFT; '\\r' ENTER; '~N' N more frames) -> (spec, the
    frame after)."""
    kb = _keyboard()
    sym = {v: k for k, v in kb.SYMBOL.items() if len(v) == 1 and len(k) == 1}
    out, f = [], first
    for line in lines:
        if line.startswith('~'):
            f += int(line[1:])
            continue
        for ch in line:
            if ch == '\r':
                out.append('%d:CR' % f)
            elif ch == ' ':
                out.append('%d: ' % f)
            elif ch.isupper():
                out.append('%d:CS,%d:%s' % (f, f, ch.lower()))
            elif ch in sym:
                out.append('%d:SS,%d:%s' % (f, f, sym[ch].lower()))
            else:
                out.append('%d:%s' % (f, ch))
            f += KEYGAP
        f += SETTLE
    return ','.join(out), f


def with_files(disk, files, out):
    """A copy of the system disk DISK at OUT, FILES ({path: bytes}) put on
    its system volume (where kernel.json says it is): scripts a test types
    'sh /mnt/a/NAME' to run, under Fuse's limit of keys."""
    import json
    import zxdfs
    with open(os.path.join(os.path.dirname(disk), 'kernel.json')) as f:
        base, _ = json.load(f)['volume']
    d = dsk.Disk.load(disk)
    fs = zxdfs.FS(zxdfs.Device(d), base)
    for path, data in files.items():
        fs.put(path, data)
    if fs.check():
        raise SystemExit('the volume: %s' % fs.check())
    d.save(out)
    return out


def run_disk(path, keys='', quit=QUIT, dumps=((0x4000, 0x1800),), keep=None):
    """Fuse's TC3256 on the disk at PATH: key 4 (Disk start), then KEYS
    (FUSE_AUTOKEY entries, frame:key, comma separated) -> the dumps; KEEP:
    where to put the disk as it was left."""
    if keys and len(keys.split(',')) + 1 > AUTOKEY_MAX:
        raise SystemExit('%d keys: Fuse takes %d' % (len(keys.split(',')) + 1, AUTOKEY_MAX))
    with tempfile.TemporaryDirectory() as t:
        d = os.path.join(t, 'a.dsk')
        with open(path, 'rb') as f, open(d, 'wb') as g:
            g.write(f.read())
        files = {(a, n): os.path.join(t, 'd%04X' % a) for a, n in dumps}
        spec = '%d:4' % MENU_KEY + (',' + keys if keys else '')
        env = dict(os.environ, FUSE_AUTOKEY=spec, FUSE_AUTOQUIT=str(quit),
                   FUSE_AUTODUMP=';'.join('%X:%X:%s' % (a, n, files[a, n]) for a, n in dumps))
        r = subprocess.run([FUSE, '--machine', 'tc3256', '--no-sound', '--speed', SPEED, '--timex-fdd',
                            '--timex_fdddisk', d], env=env, capture_output=True,
                           text=True, timeout=900)
        out = {}
        for k, p in files.items():
            if not os.path.exists(p):
                raise SystemExit('fuse: no dump %04X\n%s%s' % (k[0], r.stdout, r.stderr))
            with open(p, 'rb') as f:
                out[k] = f.read()
        if keep:                        # drive A as Fuse wrote it back (AUTOQUIT)
            with open(d, 'rb') as f, open(keep, 'wb') as g:
                g.write(f.read())
        return out


RS232_BAUD = 1200        # the line's speed (tc3256/src/rs232.asm: RS_BAUD)


def run_serial(path, script, quit, dumps=((0x4000, 0x1800),), poll=0.05, wait=600):
    """Fuse's TC3256 on the disk at PATH (Disk start), a terminal on its
    RS-232 port (the fork's FUSE_RS232_*): SCRIPT is (text, keys) pairs -
    once TEXT has come out on the line (after the last one found), KEYS
    are sent (the far end holds them while the TC3256's RTS is down).
    Fuse stops at frame QUIT -> (the dumps, the line's output, its trace:
    [(frame, 'OUT' or 'IN', byte)], the texts never seen)."""
    import time
    with tempfile.TemporaryDirectory() as t:
        d = os.path.join(t, 'a.dsk')
        with open(path, 'rb') as f, open(d, 'wb') as g:
            g.write(f.read())
        out, inp, trace = (os.path.join(t, n) for n in ('out', 'in', 'trace'))
        open(inp, 'wb').close()
        files = {(a, n): os.path.join(t, 'd%04X' % a) for a, n in dumps}
        env = dict(os.environ, FUSE_AUTOKEY='%d:4' % MENU_KEY, FUSE_AUTOQUIT=str(quit),
                   FUSE_AUTODUMP=';'.join('%X:%X:%s' % (a, n, files[a, n]) for a, n in dumps),
                   FUSE_RS232_OUT=out, FUSE_RS232_IN=inp, FUSE_RS232_TRACE=trace,
                   FUSE_RS232_BAUD=str(RS232_BAUD))
        p = subprocess.Popen([FUSE, '--machine', 'tc3256', '--no-sound', '--speed', SPEED,
                              '--timex-fdd', '--timex_fdddisk', d], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        missed, pos, end = [], 0, time.time() + wait

        def line():
            try:
                with open(out, 'rb') as f:
                    return f.read().decode('latin-1')
            except FileNotFoundError:
                return ''
        for text, keys in script:
            while True:
                k = line().find(text, pos)
                if k >= 0:
                    pos = k + len(text)
                    break
                if p.poll() is not None or time.time() > end:
                    missed.append(text)
                    break
                time.sleep(poll)
            if missed:
                break
            with open(inp, 'ab') as f:
                f.write(keys.encode('latin-1'))
        try:
            p.wait(timeout=max(1, end - time.time()))
        except subprocess.TimeoutExpired:
            p.kill()
            raise SystemExit('fuse: did not stop at frame %d' % quit)
        got = {}
        for k, f in files.items():
            if os.path.exists(f):
                with open(f, 'rb') as g:
                    got[k] = g.read()
        tr = []
        if os.path.exists(trace):
            with open(trace) as f:
                for ln in f:
                    w = ln.split()
                    if len(w) >= 4:
                        tr.append((int(w[0]), w[2], int(w[3], 16)))
        return got, line(), tr, missed


if __name__ == '__main__':
    with open(sys.argv[1], 'rb') as f:
        boot = f.read()
    dumps = [tuple(int(x, 16) for x in a.split(':')) for a in sys.argv[2:]] or [(0x4000, 0x1B00)]
    got, _ = run(boot, dumps)
    for (a, n), b in got.items():
        print('%04X: %s' % (a, b[:64].hex()))
