#!/usr/bin/env python3
"""TOS disks under ZX-UX: the file system module /etc/fs/tos (tfs.asm),
on the emulated FDD3000.

Drive B: a real TOS disk of the LoadZX collection (TENET-A1, if it is
there; else one made by tosfs.py with the same kind of files), mounted
with mount -t tos and only read: every file is copied to a blank TOS disk
in drive C, through ZX-UX (cp), and the copies are compared on the host
with what tosfs.py - checked against tomato - reads from drive B.  Then,
on drive C:
  - files made, overwritten (truncated), longer than one part (16K);
  - a directory, a file in it, both removed (rmdir);
  - ln refused (TOS has no links); mv done by copying;
  - dd seek= past the end: the gap reads as zeros;
  - a file unlinked while open: an orphan on the disk until its last
    close, then nothing;
  - the disk filled: the write stops short, ENOSPC; rm gives it back.
Afterwards both disks are checked on the host (tosfs.py check: AUs used
once and in range, parts whole, sizes the AUs hold), drive B is as it
was, and tomato (if built) lists drive C and exports what ZX-UX wrote.

    python3 fdd3000/test/test_tfs.py
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import fddrun  # noqa: E402
import dsk  # noqa: E402
import tosfs  # noqa: E402
from test_fsmod import Run, to_host, to_model  # noqa: E402

LOADZX = os.path.dirname(ROOT)
REAL = os.path.join(LOADZX, 'DISKS', 'TENET Sanitized Disks', 'TENET-A1.dsk')
TOMATO = os.path.join(LOADZX, 'tomato', 'tomato')
OUT = os.path.join(ROOT, 'build', 'tfs')


def drive_b():
    if os.path.exists(REAL):
        return dsk.Disk.load(REAL), 'TENET-A1'
    d = dsk.Disk(cyls=40, sides=1)
    fs = tosfs.mkfs(d, 'Z')
    rnd = random.Random(1)
    for name, n in (('START', 3945), ('DIG2.BAS', 19635), ('NET.SCR', 6917),
                    ('BIOMAS2.BAS', 22067), ('TAS1.BAS', 49)):
        fs.put(name, bytes(rnd.randrange(256) for _ in range(n)))
    sub = fs.mkdir('**PAULO')
    fs.put('XPTO1', b'in a directory\n' * 15, sub)
    return d, 'made by tosfs.py'


def main():
    os.makedirs(OUT, exist_ok=True)
    b, what = drive_b()
    fsb = tosfs.TOS(b)
    want = {}                                   # ZX-UX name -> bytes
    for i, parts in fsb.files().items():
        e = fsb.ent(i)
        if e[0] == 0:
            want[fsb.zxname(i, e)] = fsb.read_file(i)
    c = dsk.Disk(cyls=40, sides=1)
    tosfs.mkfs(c, 'ZXUX')
    mb, mc = to_model(b), to_model(c)
    r = Run([fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK), mb, mc])
    m = r.m
    fails = []

    def check(cond, why):
        if not cond:
            fails.append(why)

    def ok(out, why):
        tail = out.split('\n', 1)[-1]
        check(':' not in tail and 'error' not in tail, '%s: %r' % (why, out[-160:]))

    ok(r.sh('/etc/mount -t tos /dev/fd1 /mnt/b'), 'mount B')
    ok(r.sh('/etc/mount -t tos /dev/fd2 /mnt/c'), 'mount C')
    out = r.sh('ls /mnt/b')
    names = [n for n in out.split('\n')[1:] if n and not n.startswith('#')]
    check(set(want) <= set(names), 'ls /mnt/b: %s, not %s' % (names, sorted(want)))

    # B: read every file of its root, through cp to C
    r.sh('mkdir /mnt/c/b')
    for n in sorted(want):
        r.sh('cp /mnt/b/%s /mnt/c/b/%s' % (n, n), limit=240)
    out = r.sh('cmp /mnt/b/%s /mnt/c/b/%s' % (sorted(want)[0], sorted(want)[0]))
    check('differ' not in out, 'cmp: %r' % out)
    fsc = tosfs.TOS(to_host(mc))               # the copies, on the host
    check(not fsc.check(), 'drive C with the copies: %s' % fsc.check()[:3])
    bid = [d for d, i in fsc.dirs().items() if fsc.name(fsc.ent(i))[0] == 'B']
    for n, data in sorted(want.items()):        # (named as ZX-UX showed them)
        try:
            got = fsc.read_file(fsc.lookup('%d:%s' % (bid[0] if bid else 0, n.upper())))
        except tosfs.TOSError as e:
            got = str(e).encode()
        check(got == data, 'copy of %s: %d bytes, not %d' % (n, len(got), len(data)))
    big = max(want, key=lambda k: len(want[k]))
    for n in sorted(want):                      # and away: rm gives it all back
        if n != big:
            r.sh('rm /mnt/c/b/%s' % n)
    r.sh('mv /mnt/c/b/%s /mnt/c/big' % big, limit=240)
    r.sh('rmdir /mnt/c/b')
    fsc = tosfs.TOS(to_host(mc))
    used = sum(1 for _ in fsc.used_aus())
    check(used == (len(want[big]) + 1023) // 1024 and not fsc.dirs(),
          'after rm: %d AUs used, directories %s' % (used, fsc.dirs()))

    # C: files, parts, a directory, links, mv, holes
    r.sh('echo hello, tos > /mnt/c/note.txt')
    out = r.sh('cat /mnt/c/note.txt')
    check('hello, tos\n' in out, 'cat: %r' % out)
    r.sh('cp /mnt/c/big /mnt/c/big2', limit=240)
    out = r.sh('cmp /mnt/c/big /mnt/c/big2')
    check('differ' not in out and 'EOF' not in out, 'cmp big big2: %r' % out)
    r.sh('echo short > /mnt/c/big2')            # truncated: its parts go
    r.sh('mkdir /mnt/c/sub')
    r.sh('echo in sub > /mnt/c/sub/f')
    out = r.sh('ls /mnt/c/sub')
    check('f\n' in out, 'ls /mnt/c/sub: %r' % out)
    out = r.sh('cat /mnt/c/sub/../note.txt')
    check('hello, tos' in out, '..: %r' % out)
    r.sh('mkdir /mnt/c/gone')
    r.sh('rm /mnt/c/sub/f')
    r.sh('rmdir /mnt/c/gone')
    out = r.sh('ls /mnt/c')
    check('gone' not in out and 'sub' in out, 'rmdir: %r' % out)
    out = r.sh('ln /mnt/c/note.txt /mnt/c/h2')
    check("can't link" in out, 'ln was not refused: %r' % out)
    r.sh('mv /mnt/c/note.txt /mnt/c/memo.txt')
    out = r.sh('ls /mnt/c')
    check('memo.txt' in out and 'note.txt' not in out, 'mv: %r' % out)
    r.sh('dd if=/etc/motd of=/mnt/c/gap seek=70')  # 70 * 256: two parts

    # unlinked while open
    r.sh('echo kept open > /mnt/c/open')
    r.sh('sleep 25 < /mnt/c/open &')
    r.sh('rm /mnt/c/open')
    fsc = tosfs.TOS(to_host(mc))
    orphans = [i for i, e in fsc.entries() if e[0] == tosfs.ORPHAN]
    check(len(orphans) == 1, 'orphans while open: %s' % orphans)
    m.run_for(28)
    r.sh('ls /mnt/c')

    # full
    r.sh('dd if=/dev/fd0 of=/mnt/c/fill count=255', limit=400)    # (64K: a file's most)
    out = r.sh('dd if=/dev/fd0 of=/mnt/c/fill2 count=255', limit=400)
    check('error' in out.lower(), 'filling: %r' % out[-120:])
    fsc = tosfs.TOS(to_host(mc))
    free = [a for a in range(4, fsc.limit) if a not in fsc.used_aus()]
    check(not free, 'full disk with %d AUs free' % len(free))
    check(not fsc.check(), 'full: %s' % fsc.check()[:3])
    r.sh('rm /mnt/c/fill')
    r.sh('rm /mnt/c/fill2')
    out = r.sh('echo after > /mnt/c/after')
    ok(out, 'a write after the disk was full')

    ok(r.sh('/etc/umount /dev/fd1'), 'umount B')
    ok(r.sh('/etc/umount /dev/fd2'), 'umount C')
    out = r.sh('echo the end')
    check('the end' in out and m.stopped is None, 'the machine did not survive')

    # on the host
    hb, hc = to_host(mb), to_host(mc)
    same = all(hb.sector(t, 0, s) == b.sector(t, 0, s) for t in range(40) for s in range(16))
    check(same, 'drive B was changed')
    fsc = tosfs.TOS(hc)
    errs = fsc.check()
    check(not errs, 'drive C: %s' % errs[:4])

    def get(path):
        try:
            return fsc.read_file(fsc.lookup(path))
        except tosfs.TOSError as e:
            return str(e)

    check(get('MEMO.TXT') == b'hello, tos\n', 'MEMO.TXT: %r' % get('MEMO.TXT')[:40])
    check(get('BIG') == want[big], 'BIG: two parts')
    check(get('BIG2') == b'short\n', 'BIG2 truncated: %r' % get('BIG2')[:20])
    gap = get('GAP')
    motd = b'\n  Welcome to ZX-UX UNIX v1.\n\n'
    check(isinstance(gap, bytes) and gap == bytes(70 * 256) + motd,
          'GAP: %r' % (gap[-40:] if isinstance(gap, bytes) else gap))
    check(get('AFTER') == b'after\n', 'AFTER')
    for gone in ('NOTE.TXT', 'FILL', 'FILL2', 'OPEN', 'GONE'):
        check('not found' in str(get(gone)), '%s is still there' % gone)
    sid = [d for d, i in fsc.dirs().items() if fsc.name(fsc.ent(i))[0] == 'SUB']
    check(len(sid) == 1 and 'not found' in str(get('%d:F' % sid[0])), 'SUB, and F gone from it')
    hc.save(os.path.join(OUT, 'C.dsk'))

    # tomato, the collection's own TOS tool, reads what ZX-UX wrote
    if os.path.exists(TOMATO):
        ex = os.path.join(OUT, 'export')
        os.makedirs(ex, exist_ok=True)
        for f in os.listdir(ex):
            os.remove(os.path.join(ex, f))
        p = subprocess.run([TOMATO, '-open', os.path.join(OUT, 'C.dsk'), '-export', ex],
                           capture_output=True, text=True)
        check('E :' not in p.stdout, 'tomato: %s' % p.stdout[-200:])
        check(open(os.path.join(ex, 'memo.txt'), 'rb').read() == b'hello, tos\n'
              if os.path.exists(os.path.join(ex, 'memo.txt')) else False,
              'tomato export of memo.txt')
        check(os.path.exists(os.path.join(ex, 'big')) and
              open(os.path.join(ex, 'big'), 'rb').read() == want[big], 'tomato export of big')

    log = os.path.join(ROOT, 'build', 'test_tfs.log')
    with open(log, 'w') as f:
        f.write(m.screen().replace('\r', ''))
    print('drive B: %s; transcript: %s' % (what, os.path.relpath(log, ROOT)))
    for f in fails:
        print('FAIL:', f)
    print('test_tfs: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
