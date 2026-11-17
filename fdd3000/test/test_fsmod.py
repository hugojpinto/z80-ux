#!/usr/bin/env python3
"""File system types loaded at mount time (fsmod.asm), on the emulated
FDD3000.

ZXFS is built in.  For the test it is also built as two modules,
"zxfsm" and "zxfsn" (fdd3000/tools/fsmod.py on zfs.asm: the same code,
relocated wherever the arena puts it), put in the system disk's
/etc/fs; drives B and C carry ZXFS disks with a file each.  Checked:
  - mount -t zxfsm (by name: /mnt/a/etc/fs/zxfsm is loaded) and
    mount -t zxfsn: two loaded types at once, in the type table with a
    mount each, in fixed arena blocks; files read and written through them;
  - umount unloads a type with its last mount: the type table and the
    arena's free bytes (df) are as before;
  - -t by path, -t of the built-in zxfs, mount without -t (the table's
    types in turn);
  - refused: a module made for another kernel (its ABI), a file that is
    no module, a type with no module; a mount that fails after its type
    was loaded leaves nothing loaded;
  - the disks written through the modules are consistent (zxdfs check).

    python3 fdd3000/test/test_fsmod.py
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'fdd3000', 'tools'))
import fddrun  # noqa: E402
import zxdfs  # noqa: E402
import dsk  # noqa: E402
import fsmod  # noqa: E402

BUILD = os.path.join(ROOT, 'build', 'fdd3000')
SJASMPLUS = os.environ.get('SJASMPLUS', os.path.join(ROOT, 'fdd3000', 'tools', 'bin', 'sjasmplus'))


def to_host(d):
    out = dsk.Disk(cyls=d.cyls, sides=d.sides, spt=d.spt)
    for c in range(d.cyls):
        for h in range(d.sides):
            for r in range(d.spt):
                out.put(c, h, r, d.sector(c, h, r))
    return out


def to_model(d):
    out = fddrun.fdd.Disk(cyls=d.cyls, sides=d.sides)
    for c in range(d.cyls):
        for h in range(d.sides):
            for r in range(d.spt):
                out.set_sector(c, h, r, d.sector(c, h, r))
    return out


def modules():
    kabi = os.path.join(BUILD, 'kabi.inc')
    src = os.path.join(ROOT, 'fdd3000', 'src', 'zfs.asm')
    work = os.path.join(BUILD, 'mod')
    m = fsmod.build(SJASMPLUS, kabi, src, 'zxfsm', work)
    n = fsmod.build(SJASMPLUS, kabi, src, 'zxfsn', work)
    bad = bytearray(fsmod.build(SJASMPLUS, kabi, src, 'badabi', work))
    bad[4] ^= 0xFF                              # another kernel's ABI
    return m, n, bytes(bad)


class Run:
    def __init__(self, disks):
        self.m = fddrun.FDDUX(disks)
        self.m.boot()
        self.m.run_for(25, quiet=3.0)
        self.sh('root')

    def sh(self, cmd, limit=120):
        n = len(self.m.link.out)
        self.m.link.keys.extend((cmd + '\r').encode())
        t0 = self.m.tstates
        while self.m.tstates - t0 < limit * 4e6:
            self.m.run_for(0.5)
            out = self.m.link.out[n:]
            if not self.m.link.keys and out.endswith(b'# '):
                self.m.run_for(0.5)
                if self.m.link.out[n:] == out:
                    break
        return self.m.link.out[n:].decode('latin-1').replace('\r', '')


def main():
    sym = json.load(open(os.path.join(BUILD, 'kernel.json')))['symbols']
    zm, zn, bad = modules()
    # the system disk: the modules in /etc/fs
    a = to_host(fddrun.fdd.Disk.load(fddrun.DEFAULT_DISK))
    fsa = zxdfs.FS(zxdfs.Device(a))
    fsa.put('/etc/fs/zxfsm', zm)
    fsa.put('/etc/fs/zxfsn', zn)
    fsa.put('/etc/fs/badabi', bad)
    fsa.put('/etc/fs/junk', b'this is no module\n' * 4)
    # drives B and C: ZXFS disks
    disks = []
    for text in (b'on b\n', b'on c\n'):
        d = dsk.Disk(cyls=40, sides=1)
        zxdfs.mkfs(zxdfs.Device(d)).put('/hello', text)
        disks.append(d)
    drives = [to_model(a), to_model(disks[0]), to_model(disks[1])]
    r = Run(drives)
    m = r.m
    fails = []

    def check(cond, why):
        if not cond:
            fails.append(why)

    def table():
        """The type table: [(type, name, ops, blk, refs)] of used entries."""
        out = []
        for k in range(sym['NFST']):
            e = sym['fstab'] + k * sym['FTSZ']
            ops = m.m[e] | m.m[e + 1] << 8
            if ops:
                name = bytes(m.m[e + 5:e + 13]).rstrip(b'\0').decode()
                out.append((k + 1, name, ops, m.m[e + 2] | m.m[e + 3] << 8, m.m[e + 4]))
        return out

    def arena():
        return [int(w) for w in r.sh('df').split() if w.isdigit()]

    t0 = table()
    f0 = arena()
    check([e[1] for e in t0] == ['zxfs'], 'at boot: only zxfs in the table: %s' % t0)

    # two loaded types at once
    out = r.sh('/etc/mount -t zxfsm /dev/fd1 /mnt/b')
    check('# ' in out and 'error' not in out and ':' not in out.split('\n', 1)[-1],
          'mount -t zxfsm: %r' % out)
    out = r.sh('/etc/mount -t zxfsn /dev/fd2 /mnt/c')
    check(':' not in out.split('\n', 1)[-1], 'mount -t zxfsn: %r' % out)
    t1 = table()
    names = {e[1]: e for e in t1}
    check(set(names) == {'zxfs', 'zxfsm', 'zxfsn'}, 'two modules loaded: %s' % t1)
    for nm in ('zxfsm', 'zxfsn'):
        if nm in names:
            _, _, ops, blk, refs = names[nm]
            check(ops == blk and blk > sym['AR0'] and refs == 1,
                  '%s: ops %04X block %04X refs %d' % (nm, ops, blk, refs))
            check(m.m[blk - 2] == sym['K_FSM'], '%s: arena kind %d' % (nm, m.m[blk - 2]))
    mt = [m.m[sym['mtab'] + k * sym['MNTSZ']] for k in range(sym['NMOUNT'])]
    check(sorted(t for t in mt if t) == sorted([1, names.get('zxfsm', (0,))[0],
                                                names.get('zxfsn', (0,))[0]]),
          'mount types %s' % mt)
    out = r.sh('cat /mnt/b/hello /mnt/c/hello')
    check('on b\non c\n' in out, 'read through the modules: %r' % out)
    r.sh('echo written by zxfsm > /mnt/b/new')
    r.sh('cp /etc/motd /mnt/c/motd')
    r.sh('mkdir /mnt/c/d')
    out = r.sh('ls /mnt/b /mnt/c')
    check('new' in out and 'motd' in out, 'ls: %r' % out)
    f1 = arena()

    # the last mount unloads its type; the arena gets it back
    r.sh('/etc/umount /dev/fd1')
    r.sh('/etc/umount /dev/fd2')
    t2 = table()
    check([e[1] for e in t2] == ['zxfs'], 'after umount: %s' % t2)
    f2 = arena()
    check(f2 == f0, 'df before %s, loaded %s, after %s' % (f0, f1, f2))

    # by path; the built-in by name; without -t
    out = r.sh('/etc/mount -t /mnt/a/etc/fs/zxfsn /dev/fd1 /mnt/b')
    check([e[1] for e in table()][-1:] == ['zxfsn'], '-t by path: %r %s' % (out, table()))
    r.sh('/etc/umount /dev/fd1')
    out = r.sh('/etc/mount -t zxfs /dev/fd1 /mnt/b')
    check(':' not in out.split('\n', 1)[-1] and [e[1] for e in table()] == ['zxfs'],
          '-t zxfs: %r' % out)
    r.sh('/etc/umount /dev/fd1')
    out = r.sh('/etc/mount /dev/fd2 /mnt/c')
    check(':' not in out.split('\n', 1)[-1], 'without -t: %r' % out)
    r.sh('/etc/umount /dev/fd2')

    # refused
    out = r.sh('/etc/mount -t badabi /dev/fd1 /mnt/b')
    check('not a file system module for this kernel' in out, 'another ABI: %r' % out)
    out = r.sh('/etc/mount -t junk /dev/fd1 /mnt/b')
    check('not a file system module' in out, 'junk: %r' % out)
    out = r.sh('/etc/mount -t nosuch /dev/fd1 /mnt/b')
    check('/mnt/a/etc/fs/nosuch: not found' in out, 'no module: %r' % out)
    out = r.sh('/etc/mount -t zxfsm /dev/fd1 /nowhere')
    check('/nowhere: not found' in out, 'a bad directory: %r' % out)
    check([e[1] for e in table()] == ['zxfs'], 'failed mounts left %s' % table())
    check(arena() == f0, 'failed mounts kept memory: %s %s' % (f0, arena()))
    out = r.sh('ls /mnt/b')
    check('hello' not in out, 'a refused mount mounted: %r' % out)

    out = r.sh('echo the end')
    check('the end' in out and m.stopped is None, 'the machine did not survive')

    # the disks written through the modules, on the host
    for k, want in ((1, [('/hello', b'on b\n'), ('/new', b'written by zxfsm\n')]),
                    (2, [('/hello', b'on c\n')])):
        fs = zxdfs.FS(zxdfs.Device(to_host(drives[k])))
        errs = fs.check()
        check(not errs, 'drive %d: zxdfs check: %s' % (k, errs[:3]))
        for path, data in want:
            try:
                got = fs.read_file(fs.lookup(path))
            except zxdfs.FSError as e:
                got = str(e)
            check(got == data, 'drive %d %s: %r' % (k, path, got))
        if k == 2:
            check(fs.lookup('/d') and fs.read_file(fs.lookup('/motd')).startswith(b'\n  Welcome'),
                  'drive 2: /d, /motd')

    log = os.path.join(ROOT, 'build', 'test_fsmod.log')
    with open(log, 'w') as f:
        f.write(m.screen().replace('\r', ''))
    print('transcript: %s' % os.path.relpath(log, ROOT))
    for f in fails:
        print('FAIL:', f)
    print('test_fsmod: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
