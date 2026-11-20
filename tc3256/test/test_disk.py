#!/usr/bin/env python3
"""Phase 2 (platform/tc3256.md §7): the disks, through TOS.

    python3 tc3256/test/test_disk.py

The system disk (build.py tc3256) in Fuse's TC3256, started from disk.
Checked:
  - at boot /etc/init mounts the system volume - a ZXFS in the TOS file
    ZXFS on drive A (tosdisk.asm's blkvol finds it) - on /mnt/a and runs
    its etc/rc ("/dev/fd0 on /mnt/a");
  - /dev/fd0-3 are there (HAL_DEVFILES);
  - an SDK program from the volume's /bin (hello, C48, rcc --no-rom), by
    the shell's path;
  - a file written to the volume and read back, and - Fuse writing drive
    A back at the end - still there after a reboot;
  - keys typed while the disk is read (a background wc of BIG bytes) are
    all typed, in order: the frame interrupt, cut short while a link
    command is under way, queues the keyboard's changes (kbd.asm kbheld)
    and they are played when it is done.
(Fuse's TC3256 takes a disk in drive A only: the TOS module, which mounts
another disk, is not tried here.)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tc3256run  # noqa: E402

DISK = os.path.join(ROOT, 'build', 'tc3256', 'ZX-UX-TC3256.dsk')
LOGIN = 2600            # frames: the login prompt is up by then (the mount, rc)
BIG = 12000             # bytes of the file read in the background
TYPED = 'echo typed during the read'
WRITE = '~150'          # frames more for the write to end: keys typed while a
                        # program runs are flushed when it exits (sh, as upstream)


def session(disk, lines, keep=None):
    spec, f = tc3256run.keys(['root\r'] + lines, LOGIN)
    got = tc3256run.run_disk(disk, keys=spec, quit=f + 200, keep=keep)
    return tc3256run.screen_text(got[(0x4000, 0x1800)])


def main():
    with tempfile.TemporaryDirectory() as t:
        used = os.path.join(t, 'used.dsk')
        a = session(DISK, ['ls /dev\r', 'hello\r', 'echo kept > /mnt/a/note\r', WRITE,
                           'cat /mnt/a/note\r'], keep=used)
        b = session(used, ['cat /mnt/a/note\r'])
        big = tc3256run.with_files(DISK, {'/big': bytes(32 + i % 95 if i % 64 else 10 for i in range(BIG))},
                                   os.path.join(t, 'big.dsk'))
        c = session(big, ['wc /mnt/a/big &\r', TYPED + '\r', '~600'])
    print(a)
    print(b)
    print(c)
    fails = []

    def expect(text, what, why):
        if what not in text:
            fails.append(why)
    expect(a, '/dev/fd0 on /mnt/a', 'the system volume was not mounted at boot')
    expect(a, 'fd0\nfd1\nfd2\nfd3', '/dev/fd0-3 missing')
    expect(a, '# hello\nHello World!', 'hello from the volume did not run')
    expect(a, '# cat /mnt/a/note\nkept', 'a file written to the volume did not read back')
    expect(b, '# cat /mnt/a/note\nkept', 'the file was gone after a reboot')
    expect(c, '%d /mnt/a/big' % BIG, 'wc of the file did not end')
    expect(c, '\n' + TYPED[5:] + '\n', 'keys typed during the read were lost')
    for x in fails:
        print('FAIL:', x)
    print('test_disk: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
