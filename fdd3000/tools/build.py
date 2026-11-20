#!/usr/bin/env python3
"""Build ZX-UX from zx-ux/src for the 48K Spectrum and for the FDD3000.

    python3 fdd3000/tools/build.py              all three targets
    python3 fdd3000/tools/build.py upstream     the reproduction gate only
    python3 fdd3000/tools/build.py spectrum     this tree, for the Spectrum
    python3 fdd3000/tools/build.py fdd3000      the disk only

upstream  Rebuilds upstream's own, untouched sources (zx-ux/src as of
          UPSTREAM_REF, exported from git) and checks the kernel ("lowk",
          "unix") and the root file system ("fs") byte for byte against the
          shipped system tape, zx-ux/tzx/ZX-UX.tzx.  (Upstream ships no
          kernel builder; the generated includes are reconstructed here.)

spectrum  This tree's kernel for platform/spectrum48.  It is no longer the
          shipped tape byte for byte (platform/DESIGN.md); its behaviour is
          checked by test/spectrum/golden.py.  The build says whether it
          still equals the tape.

Each target's machine is described by platform/<name>/platform.inc
(capabilities and hooks; platform/README.md), staged as platform.inc.

fdd3000   Assembles the same sources for platform/fdd3000, the hardware
          layer (fdd3000/src/hal.asm) and the boot sector
          (fdd3000/src/boot.asm), builds the FDD3000 root file system and
          writes build/fdd3000/ZX-UX-FDD3000.dsk, a bootable 40-track disk.

The assembler is sjasmplus v1.21.0: fdd3000/tools/fetch-sjasmplus.sh, or
SJASMPLUS=/path/to/sjasmplus.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
ROOT = os.path.dirname(PORT)
SRC = os.path.join(ROOT, 'zx-ux', 'src')
UPSTREAM_REF = 'f302288'        # upstream's sources that make ZX-UX.tzx
PLATFORMS = os.path.join(ROOT, 'platform')     # platform/<name>/platform.inc
DRIVERS = os.path.join(ROOT, 'drivers')        # drivers/<name>/*.asm, *.inc
PLATFORM = {'spectrum': 'spectrum48', 'fdd3000': 'fdd3000'}  # target -> name
TAPE = os.path.join(ROOT, 'zx-ux', 'tzx', 'ZX-UX.tzx')
BUILD = os.path.join(ROOT, 'build')
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'sdk', 'bin', 'py'))
import zxfs  # noqa: E402
import dsk  # noqa: E402

SJASMPLUS = os.environ.get('SJASMPLUS', os.path.join(HERE, 'bin', 'sjasmplus'))

# The resident programs, in the order of the shipped PTAB (read back from
# the tape): the system programs, then zx-ux/src/programs.txt.  A
# program's i-number is TXINO + its index here.
SYSTEM_PROGRAMS = [('/etc/init', 'init', 0), ('/etc/getty', 'getty', 0),
                   ('/etc/glob', 'glob', 0), ('/bin/login', 'login', 0),
                   ('/bin/sh', 'sh', 0), ('/etc/ldx', 'ldx', 0)]


class BuildError(Exception):
    pass


# Programs beyond programs.txt, after it (drivers/, a machine layer's).
MORE_PROGRAMS = [('/bin/dd', 'dd', 0), ('/etc/mount', 'mount', 0),
                 ('/etc/umount', 'umount', 0), ('/etc/mkfs', 'mkfs', 0)]


# Resident program sources, in the order they are assembled.  A platform
# whose machine layer declares free places for text (TX0, TX0_LIM, TX1...:
# fdd3000/src/hal.asm) gets them packed there (place(): textN.inc); the
# rest is assembled after the kernel, as on the Spectrum (userland.inc).
# ulib.asm stays there, first: it defines the macro the others use.
USERLAND = ['ulib.asm', 't_sys.asm', 't_file.asm', 't_misc.asm', 't_tap.asm',
            't_proc.asm', 't_vi.asm', 't_zx.asm', 't_tar.asm', 't_ldx.asm',
            't_mkfs.asm', 't_fs.asm', 't_dd.asm']
PINNED = ['ulib.asm']

# What a program, its source, a document or a directory needs of the
# machine (its platform.inc): left out where that is 0.
NEEDS = {'tar': 'HAL_SEQDEV', 't_tar.asm': 'HAL_SEQDEV',     # the cassette's
         'mount': 'HAL_VFS', 'umount': 'HAL_VFS', 'mkfs': 'HAL_VFS',
         't_fs.asm': 'HAL_VFS', 't_mkfs.asm': 'HAL_VFS', '/mnt': 'HAL_VFS',
         'dd': 'HAL_BLKDEV', 't_dd.asm': 'HAL_BLKDEV'}


def platform(target):
    """The machine's settings (platform/<name>/platform.inc): the HAL_*
    numbers, and the DEFINEd strings.  upstream: the Spectrum's."""
    name = PLATFORM.get(target, PLATFORM['spectrum'])
    caps = {}
    with open(os.path.join(PLATFORMS, name, 'platform.inc')) as f:
        for line in f:
            m = re.match(r'^(HAL_\w+)\s+equ\s+(\d+)', line)
            if m:
                caps[m.group(1)] = int(m.group(2))
            m = re.match(r'^\s+DEFINE\s+(HAL_\w+)\s+"([^"]*)"', line)
            if m:
                caps[m.group(1)] = m.group(2)
    return caps


def wanted(target, name):
    """Whether this machine has what name (a program, a source...) needs."""
    need = NEEDS.get(name)
    return need is None or bool(platform(target).get(need))


def sources(target):
    return [x for x in USERLAND if wanted(target, x)]


def devfiles(target):
    """/dev's entries: name, device number (HAL_DEVFILES)."""
    return [(n, int(d)) for n, d in
            (x.split(':') for x in platform(target)['HAL_DEVFILES'].split())]


def programs(target='spectrum'):
    out = list(SYSTEM_PROGRAMS)
    with open(os.path.join(SRC, 'programs.txt')) as f:
        for line in f:
            line = line.split('#')[0].split()
            if line:
                mode = int(line[2], 8) if len(line) > 2 else 0
                out.append((line[0], line[1], mode))
    out += MORE_PROGRAMS
    return [p for p in out if wanted(target, p[1])]


def upstream_src():
    """Upstream's zx-ux/src at UPSTREAM_REF, exported from git."""
    out = os.path.join(BUILD, 'upstream-tree')
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    arch = subprocess.run(['git', '-C', ROOT, 'archive', UPSTREAM_REF, 'zx-ux/src'],
                          capture_output=True)
    if arch.returncode:
        raise BuildError('git archive %s: %s' % (UPSTREAM_REF, arch.stderr.decode()))
    subprocess.run(['tar', '-x', '-C', out], input=arch.stdout, check=True)
    return os.path.join(out, 'zx-ux', 'src')


TEXTMAX = 8                     # text places a machine layer may declare (TXn)


def stage(target, placed=None, measure=False):
    """A private copy of the sources with the generated includes: placed,
    {n: [source...]} the resident sources in place TXn (place()); measure,
    a label before each of the others (txsizeK), for their sizes."""
    top = os.path.join(BUILD, target)
    src = os.path.join(top, 'src')
    if os.path.isdir(top):
        shutil.rmtree(top)
    os.makedirs(os.path.join(top, 'out'))
    if target == 'upstream':
        shutil.copytree(upstream_src(), src, ignore=shutil.ignore_patterns('rom', '*.doc'))
    else:
        shutil.copytree(SRC, src, ignore=shutil.ignore_patterns('rom', '*.doc'))
        for d in [os.path.join(PLATFORMS, PLATFORM[target])] + \
                 [os.path.join(DRIVERS, n) for n in sorted(os.listdir(DRIVERS))]:
            for name in os.listdir(d):          # platform and driver sources
                if name.endswith(('.asm', '.inc')):
                    shutil.copy(os.path.join(d, name), src)
    if target == 'fdd3000':
        for name in os.listdir(os.path.join(PORT, 'src')):
            if name.endswith(('.asm', '.inc')):
                shutil.copy(os.path.join(PORT, 'src', name), src)
    progs = programs(target)
    files = sources(target)
    placed = placed or {}
    low = [x for lst in placed.values() for x in lst]
    with open(os.path.join(src, 'userland.inc'), 'w') as f:
        f.write('; generated by fdd3000/tools/build.py\n')
        for k, x in enumerate(x for x in files if x not in low):
            if measure:
                f.write('txsize%d:\n' % k)      # (place(): where each begins)
            f.write('        include "%s"\n' % x)
        if measure:
            f.write('txsize%d:\n' % len(files))
    for n in range(TEXTMAX):
        with open(os.path.join(src, 'text%d.inc' % n), 'w') as f:
            f.write('; generated by fdd3000/tools/build.py\n')
            f.writelines('        include "%s"\n' % x for x in placed.get(n, []))
    with open(os.path.join(src, 'ptab.inc'), 'w') as f:
        f.write('; generated by fdd3000/tools/build.py: text, size, mode bits\n')
        f.write('NPROG   equ %d\n' % len(progs))
        for path, label, mode in progs:
            f.write('        dw t_%s, e_%s-t_%s\n        db %03Xh\t\t; %s\n'
                    % (label, label, label, mode, path))
    return top, src


def bootinfo(top, kbytes, free):
    with open(os.path.join(top, 'out', 'bootinfo.inc'), 'w') as f:
        f.write('        db "%dB free=%dB procs=4 ",0\n' % (kbytes, free))


def assemble(src, main, defines=()):
    cmd = [SJASMPLUS, '--nologo', '--msg=war', '--fullpath=off',
           '--sym=%s.sym' % main[:-4], '--lst=%s.lst' % main[:-4]]
    cmd += ['-D%s' % d for d in defines] + [main]
    if not os.path.exists(SJASMPLUS):
        raise BuildError('no sjasmplus: run fdd3000/tools/fetch-sjasmplus.sh')
    r = subprocess.run(cmd, cwd=src, capture_output=True, text=True)
    if r.returncode or 'error' in (r.stdout + r.stderr).lower():
        raise BuildError('%s:\n%s%s' % (main, r.stdout, r.stderr))
    sym = {}
    with open(os.path.join(src, main[:-4] + '.sym')) as f:
        for line in f:
            m = re.match(r'^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)', line)
            if m:
                sym[m.group(1)] = int(m.group(2), 16)
    return sym


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def shipped():
    """The shipped tape's merged image, split as the boot loader loads it."""
    import zxux
    _, raw = zxux.system_tzx(TAPE)
    low = zxux.EXPECTED_LOW_ADDR
    return {name: raw[a - low:a - low + n]
            for name, a, n in zxux.EXPECTED_SYSTEM_LOADS}


def shipped_docs():
    """/usr/doc from the shipped tape: zxpack'ed payloads and their sizes
    (the packer is the kernel's; the build does not reimplement it)."""
    import zxux
    itab = dict((n, a) for n, a, _ in zxux.EXPECTED_SYSTEM_LOADS)['fs']
    tree = zxfs.read_image(shipped()['fs'], itab)
    docs = []
    for path in ('/usr/doc/zxpack', '/usr/doc/tar', '/usr/doc/more'):
        ino, flags, size, payload, _ = tree[path]
        docs.append((path.rsplit('/', 1)[1], payload, size))
    return docs


MOTD = b'\n  Welcome to ZX-UX UNIX v1.\n\n'


def root_fs(target):
    """The root file system of each target, built as the shipped one."""
    fs = zxfs.FileSystem()
    R, W, O = zxfs.IROWN, zxfs.IWOWN, zxfs.IROTH
    a = zxfs.IWOTH
    bin_ = fs.mkdir(zxfs.ROOTINO, 'bin')
    dev = fs.mkdir(zxfs.ROOTINO, 'dev')
    etc = fs.mkdir(zxfs.ROOTINO, 'etc')
    fs.mkdir(zxfs.ROOTINO, 'tmp', R | W | O | a)
    usr = fs.mkdir(zxfs.ROOTINO, 'usr', R | W | O | a)
    if wanted(target, '/mnt'):
        mnt = fs.mkdir(zxfs.ROOTINO, 'mnt', R | W | O | a)
        for drive in 'abcd':                    # /mnt/a - /mnt/d: drives A-D
            fs.mkdir(mnt, drive, R | W | O | a)
    for i, (path, _label, _mode) in enumerate(programs(target)):
        d, name = path.rsplit('/', 1)
        fs.link(bin_ if d == '/bin' else etc, name, zxfs.TXINO + i)
    for name, ino in devfiles(target):
        fs.link(dev, name, ino)
    fs.create(etc, 'motd', MOTD)
    doc = fs.mkdir(usr, 'doc', R | W | O | a)
    for name, payload, size in shipped_docs():
        if wanted(target, name):
            fs.create(doc, name, None, packed=(payload, size))
    # The shipped /bin lists login and sh first, then programs.txt, and
    # /etc lists motd last: reorder to match (names, not numbers, differ).
    order = [p for p, _, _ in programs(target)]
    first = ['/bin/login', '/bin/sh']
    rank = {p: k for k, p in enumerate(first + [p for p in order if p not in first])}
    b = fs.nodes[bin_].entries
    b[2:] = sorted(b[2:], key=lambda e: rank['/bin/' + e[1]])
    return fs


def place(target, defines=()):
    """The resident sources packed into the machine layer's free places
    (TXn .. TXn_LIM, from an assembly with all of them after the kernel):
    the largest first, each into the place with the least room it fits.
    -> {n: [source...]} in source order, {} for a machine with none."""
    top, src = stage(target, measure=True)
    bootinfo(top, 8192, 0)
    sym = assemble(src, 'unix.asm', defines)
    room = {n: sym['TX%d_LIM' % n] - sym['TX%d' % n] for n in range(TEXTMAX)
            if 'TX%d' % n in sym}
    if not room:
        return {}
    files = sources(target)
    size = {x: sym['txsize%d' % (k + 1)] - sym['txsize%d' % k] for k, x in enumerate(files)}
    placed = {n: [] for n in room}
    for x in sorted((x for x in files if x not in PINNED), key=lambda x: -size[x]):
        fits = [n for n in room if room[n] >= size[x]]
        if fits:
            n = min(fits, key=lambda n: room[n])
            room[n] -= size[x]
            placed[n].append(x)
    return {n: sorted(lst, key=files.index) for n, lst in placed.items()}


def kernel(target, defines=(), placed=None):
    """Assemble unix.asm; the boot banner reports the free arena, which
    depends on where ITAB lands, which depends on the banner's length (the
    boot area may outgrow ZXWSZ): iterate to the fixed point."""
    top, src = stage(target, placed)
    fs = root_fs(target)
    state, seen = (8192, 0), set()
    while True:
        bootinfo(top, *state)
        sym = assemble(src, 'unix.asm', defines)
        img, free = fs.image(sym['ITAB'], sym['WINDOW'])
        now = (sym['kend'] - sym['KBASE'], free)
        if now == state:
            break
        if now in seen:
            raise BuildError('the boot banner does not settle')
        seen.add(now)
        state = now
    with open(os.path.join(top, 'fs.bin'), 'wb') as f:
        f.write(img)
    return top, src, sym, img, free


def compare_tape(target):
    top, src, sym, img, free = kernel(target)
    ref = shipped()
    ok = True
    for name, data in (('lowk', read(os.path.join(src, 'lowk.bin'))),
                       ('unix', read(os.path.join(src, 'unix.bin'))),
                       ('fs', img)):
        same = data == ref[name]
        ok &= same
        print('%-9s %-4s %5d bytes  %s' % (target + ':', name, len(data),
              'identical to ZX-UX.tzx' if same else 'differs from ZX-UX.tzx'))
    return ok, sym, free


def build_upstream():
    ok, _, _ = compare_tape('upstream')
    if not ok:
        raise BuildError('upstream\'s sources no longer rebuild the shipped tape')


def build_spectrum():
    ok, sym, free = compare_tape('spectrum')
    print('spectrum: kernel %d bytes, %d bytes free in the arena%s'
          % (sym['kend'] - sym['KBASE'], free,
             '' if ok else ' (behaviour: test/spectrum/golden.py)'))


def build_fdd3000():
    import fddimage
    return fddimage.build(sys.modules[__name__])


def main():
    targets = sys.argv[1:] or ['upstream', 'spectrum', 'fdd3000']
    try:
        for t in targets:
            {'upstream': build_upstream, 'spectrum': build_spectrum,
             'fdd3000': build_fdd3000}[t]()
    except BuildError as e:
        print('build: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
