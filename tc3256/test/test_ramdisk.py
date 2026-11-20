#!/usr/bin/env python3
"""Phase 3 (platform/tc3256.md §7): the RAM disk, /dev/rd - mounted if
wanted, or not.

    python3 tc3256/test/test_ramdisk.py

The system disk in Fuse's TC3256, a script put on its volume (typed keys
are few: tc3256run.with_files).  Checked, by the script:
  - /etc/mkfs /dev/rd: a ZXFS of the RAM disk's 52 sectors of 4 KB, 832
    blocks (tosdisk.asm's unit 4; rdsys.asm moves them in system mode);
  - mounted, a file copied there (trek, larger than the cache) and the
    same as the original (cmp);
  - unmounted and mounted again - the cache dropped - and still the same:
    read back from the RAM disk itself;
  - a file written, appended to and read back; copied from the RAM disk to
    the floppy volume and read there; overwritten; another removed (ls -l);
  - nothing mounts it otherwise: at boot /mnt/b is empty.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tc3256run  # noqa: E402

DISK = os.path.join(ROOT, 'build', 'tc3256', 'ZX-UX-TC3256.dsk')
LOGIN = 2600
BIG = '/mnt/a/bin/trek'         # a file larger than the cache (4 sectors)
SCRIPT = ('ls /mnt/b\n'
          'echo before\n'
          '/etc/mkfs /dev/rd\n'
          '/etc/mount /dev/rd /mnt/b\n'
          'echo line one > /mnt/b/f\n'          # written, then appended to
          'echo line two >> /mnt/b/f\n'
          'cat /mnt/b/f\n'
          'cp %s /mnt/b/t\n'                    # floppy -> RAM disk
          'cmp %s /mnt/b/t\n'
          'echo copied\n'
          '/etc/umount /dev/rd\n'
          '/etc/mount /dev/rd /mnt/b\n'
          'cmp %s /mnt/b/t\n'
          'echo again\n'
          'cp /mnt/b/f /mnt/a/f\n'              # RAM disk -> floppy
          'cat /mnt/a/f\n'
          'echo over > /mnt/b/f\n'              # overwritten
          'cat /mnt/b/f\n'
          'rm /mnt/b/t\n'
          'ls -l /mnt/b\n'
          'echo done\n' % (BIG, BIG, BIG)).encode()
RUN = 1500              # frames for the script


def main():
    with tempfile.TemporaryDirectory() as t:
        disk = tc3256run.with_files(DISK, {'/t': SCRIPT}, os.path.join(t, 'rd.dsk'))
        spec, f = tc3256run.keys(['root\r', 'sh /mnt/a/t\r', '~%d' % RUN], LOGIN)
        got = tc3256run.run_disk(disk, keys=spec, quit=f + 100)
    text = tc3256run.screen_text(got[(0x4000, 0x1800)])
    print(text)
    fails = []

    def expect(what, why):
        if what not in text:
            fails.append(why)
    expect('# sh /mnt/a/t\nbefore', '/mnt/b was not empty at boot')
    expect('832 blocks', 'mkfs /dev/rd: not the RAM disk\'s 832 blocks')
    expect('\ncopied', 'the copy on the RAM disk differs')
    expect('\nagain', 'after a remount the copy differs (the RAM disk itself)')
    expect('# sh /mnt/a/t\nbefore', '/mnt/b was not empty at boot')
    expect('line one\nline two\n', 'a file written and appended to did not read back')
    expect('again\nline one\nline two\n', 'copied back to the floppy volume: not the same')
    expect('\nover\n', 'an overwritten file did not read back')
    expect(' f\ndone', 'after rm only f should be left')
    if ' t\n' in text.split('again')[-1]:
        fails.append('rm did not remove t')
    for bad in ('differ', 'error', 'busy', 'not a disk'):
        if bad in text.lower():
            fails.append('on the way: %s' % bad)
    for x in fails:
        print('FAIL:', x)
    print('test_ramdisk: %s' % ('FAIL' if fails else 'ok'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
