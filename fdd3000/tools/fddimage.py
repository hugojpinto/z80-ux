"""The FDD3000 system disk (build.py fdd3000).

Memory image, loaded by the boot sector from track IMGTRK on:

    0400h  low.bin    resident programs placed low (build.py LOWTEXT)
    1800h  hal.bin    the hardware layer (Spectrum: the ROM's place)
    3F00h             (not loaded: the boot sector, the old display file)
    5B00h             kernel globals (KV, MEMBOT, KV2: zero, boot clears)
    LOWK   lowk.bin   the low kernel
    6000h  unix.bin   the kernel, the resident programs, the boot code
    ITAB   fs.bin     the root file system, up to the free block's header

Disk: track 0 sector 0 is the boot sector; the image follows from track
IMGTRK, sector 0, in sector-ID order.  The rest of the disk is left
formatted and empty (E5h) for the file systems still to come.
"""
import hashlib
import json
import os
import sys

import dsk
import zxdfs

SYSTEM_README = b'''ZX-UX on the Timex FDD3000

This file system is on the system disk, after the tracks
that hold ZX-UX itself.  /etc/init mounts it on /mnt/a at
boot: it is a ZXFS - files of up to 64K, directories and
links, as in RAM, but they stay when the power goes.
/mnt/a to /mnt/d are there for drives A to D.

/mnt/a/bin holds programs made with the ZX-UX SDK (SSX1
files): the shell looks there too, so hello runs
/mnt/a/bin/hello.  Any SSX1 file with execute permission
runs, wherever it is: chmod 36 prog, then ./prog.

/mnt/a/etc/rc is run by sh at every boot, after the mount
and before the login.  The RAM /etc is made anew at each
boot; this one is kept.  To have drive B mounted too:

    echo /etc/mount /dev/fd1 /mnt/b >> /mnt/a/etc/rc

/dev/fd0 to /dev/fd3 are drives A to D.  /etc/mkfs makes a
ZXFS on a disk, /etc/mount and /etc/umount put one on a
directory and take it off, /bin/dd copies sectors.
Other file system types are modules in /mnt/a/etc/fs:
mount -t NAME /dev/fdN dir loads /mnt/a/etc/fs/NAME.
/etc/fs/tos reads and writes TOS disks:

    /etc/mount -t tos /dev/fd1 /mnt/b
Unmount a disk before you take it out of its drive.
'''

SYSTEM_RC = b'echo /dev/fd0 on /mnt/a\n'

# SDK programs on the system disk's /bin (/mnt/a/bin once mounted), built
# from their sources with rcc --ux: each declares its screen kind - here
# only the stream and console kinds, which write to the terminal; one that
# draws would be refused (platform/screen-kinds.md)
SYSTEM_PROGRAMS = ['hello', 'arith', 'fortune', 'hangman', 'quiz',
                   'advent', 'wump', 'trek', 'rogue', 'snake']
UX_SOURCES = {'hello': 'examples'}  # else games


def ux_program(b, name, out):
    """examples/c48-src/.../NAME.c built with rcc --ux into OUT (kept while
    neither the source nor the z80-ux runtime is newer)."""
    import subprocess
    src = os.path.join(b.ROOT, 'examples', 'c48-src', UX_SOURCES.get(name, 'games'), name + '.c')
    lib = os.path.join(b.ROOT, 'sdk', 'bin', 'py', 'libux')
    dst = os.path.join(out, name + '.ssx')
    newest = max(os.path.getmtime(p) for p in [src] + [os.path.join(lib, f) for f in
                                                      ('libc48.ssa', 'libtty.ssa')])
    if not os.path.exists(dst) or os.path.getmtime(dst) < newest:
        r = subprocess.run([sys.executable, os.path.join(b.ROOT, 'sdk', 'bin', 'rcc'), '--ux',
                            '-o', dst, src], capture_output=True, text=True)
        if r.returncode:
            raise b.BuildError('rcc --ux %s: %s%s' % (name, r.stdout, r.stderr))
    with open(dst, 'rb') as f:
        data = f.read()
    flags = data[4]
    if flags & 0x0C != 0x08:            # declared, stream or console
        raise b.BuildError('%s draws: no screen on the FDD3000 (flags %02Xh)' % (name, flags))
    return data

# File system modules on the system disk's /etc/fs (mount -t NAME)
FS_MODULES = [('tos', 'drivers/tos/tfs.asm')]   # TOS's disks

# IMGBASE: the image starts with the resident programs placed low
# (hal.asm LOWTEXT, 0400h), then a gap (the buffer cache), the hardware
# layer at 1800h, ...
IMGTRK = 1


def build(b):
    import fsmod
    # Twice: the kernel carries the checksum of its own ABI (fsmod.py),
    # which a first pass gives; the second must not move a thing.
    top, src, sym, fsimg, free = b.kernel('fdd3000')
    vals, stamp = fsmod.abi(sym)
    top, src, sym, fsimg, free = b.kernel('fdd3000', defines=['KABI=0%04Xh' % stamp])
    if fsmod.abi(sym) != (vals, stamp) or sym['kabi'] != stamp:
        raise b.BuildError('the kernel ABI moved between passes')
    fsmod.write_kabi(os.path.join(top, 'kabi.inc'), sym)
    parts = [('low', sym['LOWTEXT'], b.read(os.path.join(src, 'low.bin'))),
             ('low2', sym['LOWTEXT2'], b.read(os.path.join(src, 'low2.bin'))),
             ('hal', sym['HALBASE'], b.read(os.path.join(src, 'hal.bin'))),
             ('lowk', sym['LOWK'], b.read(os.path.join(src, 'lowk.bin'))),
             ('unix', sym['KBASE'], b.read(os.path.join(src, 'unix.bin'))),
             ('fs', sym['ITAB'], fsimg)]
    IMGBASE = sym['LOWTEXT']                  # the low resident programs first
    end = max(a + len(d) for _, a, d in parts)
    mem = bytearray(end - IMGBASE)
    used = []
    for name, addr, data in parts:
        lo, hi = addr, addr + len(data)
        for other, olo, ohi in used:
            if lo < ohi and olo < hi:
                raise b.BuildError('%s overlaps %s' % (name, other))
        used.append((name, lo, hi))
        mem[lo - IMGBASE:hi - IMGBASE] = data
    nsec = (len(mem) + 255) // 256
    if nsec > 240:
        raise b.BuildError('system image too big: %d sectors' % nsec)
    with open(os.path.join(src, 'bootparm.inc'), 'w') as f:
        f.write('; generated by fdd3000/tools/fddimage.py\n')
        f.write('IMGBASE equ 0%04Xh\nIMGSECS equ %d\nIMGTRK  equ %d\n'
                'ENTRY   equ 0%04Xh\n' % (IMGBASE, nsec, IMGTRK, sym['boot']))
    b.assemble(src, 'boot.asm')
    boot = b.read(os.path.join(src, 'boot.bin'))

    disk = dsk.Disk()
    disk.put(0, 0, 0, boot)
    disk.put_linear(IMGTRK, bytes(mem))

    # The rest of the disk: a ZXFS (mount /dev/fd0 /mnt), from the first
    # track after the system; the boot sector says where ("FS", base,
    # blocks at F8h), as zxdfs.py and zfs.asm expect.
    fsbase = (IMGTRK + (nsec + dsk.SPT - 1) // dsk.SPT) * dsk.SPT
    dev = zxdfs.Device(disk)
    fsblocks = dev.nsectors - fsbase
    zfs = zxdfs.mkfs(dev, fsbase, fsblocks, label='ZX-UX system', when=0x17268310)
    for name in ('README', 'zxpack.doc', 'tar.doc', 'more.doc'):
        if name == 'README':
            data = SYSTEM_README
        else:
            with open(os.path.join(b.SRC, name), 'rb') as f:
                data = f.read()
        zfs.put('/doc/' + name.split('.')[0], data)     # names: 8 at most
    zfs.put('/etc/rc', SYSTEM_RC)
    zfs.mkdir('/etc/fs')                      # file system modules (mount -t)
    for name, source in FS_MODULES:
        zfs.put('/etc/fs/' + name,
                fsmod.build(b.SJASMPLUS, os.path.join(top, 'kabi.inc'),
                            os.path.join(b.ROOT, source), name,
                            os.path.join(top, 'mod')))
    zfs.mkdir('/lib')                         # the float engine (sys 42)
    zfs.put('/lib/fp', fsmod.build(b.SJASMPLUS, os.path.join(top, 'kabi.inc'),
                                   os.path.join(b.ROOT, 'drivers', 'fp', 'fp.asm'), 'fp',
                                   os.path.join(top, 'mod')))
    import subprocess
    subprocess.run([sys.executable, os.path.join(b.ROOT, 'sdk', 'bin', 'py', 'libux', 'build.py')],
                   check=True, capture_output=True)   # the z80-ux runtime
    uxdir = os.path.join(b.BUILD, 'ux')
    os.makedirs(uxdir, exist_ok=True)
    for name in SYSTEM_PROGRAMS:              # SSX1 programs of the SDK
        zfs.put('/bin/' + name, ux_program(b, name, uxdir))
    if zfs.check():
        raise b.BuildError('system disk file system: %s' % zfs.check())
    s0 = bytearray(disk.sector(0, 0, 0))
    s0[0xF8:0x100] = b'FS' + bytes([fsbase & 255, fsbase >> 8,
                                    fsblocks & 255, fsblocks >> 8, 0, 0])
    disk.put(0, 0, 0, bytes(s0))
    out = os.path.join(top, 'ZX-UX-FDD3000.dsk')
    disk.save(out)
    with open(os.path.join(top, 'system.bin'), 'wb') as f:
        f.write(mem)

    info = {'format': 'zx-ux-fdd3000/1',
            'image_base': IMGBASE, 'image_sectors': nsec, 'image_track': IMGTRK,
            'image_sha256': hashlib.sha256(mem).hexdigest(),
            'parts': {n: [lo, hi - lo] for n, lo, hi in used},
            'arena_free': free, 'kabi': stamp,
            'symbols': {k: sym[k] for k in sorted(sym)
                        if not k.startswith(('.', '_')) and '.' not in k}}
    with open(os.path.join(top, 'kernel.json'), 'w') as f:
        json.dump(info, f, indent=1, sort_keys=True)
    kern = sym['kend'] - sym['KBASE']
    print('fdd3000:  hal %04X-%04X  lowk %04X  kernel %d bytes  user text to %04X'
          % (sym['HALBASE'], sym['halend'] - 1, sym['LOWK'], kern,
             sym['utext_end']))
    print('fdd3000:  root fs %04X, %d bytes free in the arena; image %d sectors'
          % (sym['ITAB'], free, nsec))
    print('fdd3000:  ZXFS on the system disk: sectors %d-%d, %d blocks free'
          % (fsbase, fsbase + fsblocks - 1, zfs.nfree))
    print('fdd3000:  %s' % os.path.relpath(out, b.ROOT))
    return out
