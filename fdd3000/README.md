# ZX-UX on the Timex FDD3000

ZX-UX — *based on original work by Supratim Sanyal of SANYALnet Labs* — ported
from the 48K ZX Spectrum to the **Timex FDD3000**, the disk unit with its own
Z80, 64K of RAM and a WD1770. It runs the way TOS and the FDD3000's CP/M do:
on the disk unit's Z80, with a Timex computer (TT3000, TC3256 or TC2068
running the Terminal 3000 software) as a VT52 terminal on the link.

![boot](docs/screenshots/01-boot-login.png) ![trek](docs/screenshots/05-trek.png)

## What runs

- The ZX-UX kernel, shell and its 38 resident programs, unchanged in
  behaviour: four processes, the RAM file system, `vi`, `ps`, `top`, `tar`...
- **Disks**: `/dev/fd0` – `/dev/fd3` (drives A–D, 40/80 tracks, one or two
  sides, probed when opened); `/bin/dd` copies sectors.
- **ZXFS**, a disk file system mounted into the RAM tree (`/etc/mkfs`,
  `/etc/mount`, `/etc/umount`), with a file system layer ready for more
  types (TOS's format could be the next).
- At boot `/etc/init` mounts the system disk on **`/usr`** and runs
  `/usr/etc/rc` from it (persistent: add `/etc/mount /dev/fd1 /mnt` there).
- **SDK programs** (SSX1: C48, BASIC, Pascal, FORTRAN, Forth) run from any
  file with execute permission; the system disk's `/usr/bin` carries eleven
  C48 ones (`trek`, `advent`, `rogue`, `hangman`...). Programs that draw
  into the Spectrum's display file are shown on the terminal through a
  mirror that reads it back as text.

## Build and run

```sh
fdd3000/tools/fetch-sjasmplus.sh     # sjasmplus v1.21.0 into fdd3000/tools/bin
python3 fdd3000/tools/build.py       # spectrum gate + build/fdd3000/ZX-UX-FDD3000.dsk
```

`build.py spectrum` rebuilds the shipped Spectrum system from `zx-ux/src` and
checks it **byte for byte** against `zx-ux/tzx/ZX-UX.tzx` (upstream ships no
builder). Every FDD3000 change to the shared sources sits behind
`IFDEF FDD3000`; this gate proves the Spectrum system untouched.

In Fuse (the LoadZX fork, `TC3256/EMUL`): machine **TT3000**, the disk in
Timex FDD drive A (`--timex_fdddisk`); Machine › Timex FDD Reset if the
terminal came up first. On a real FDD3000: write the image to a disk, drive
A, reset.

Tests (Python, on the FDD3000-MSDOS project's FDD3000 model — Z80, WD177x,
boot ROM — with a model of the terminal's end of the link):

```sh
python3 fdd3000/test/test_fd.py      # the driver: three drives, sector-exact
python3 fdd3000/test/test_zfs.py     # ZXFS through the shell, checked on the host
python3 fdd3000/test/test_boot.py    # init's mount and rc, across reboots
python3 fdd3000/test/test_ssx.py     # SDK programs from disk, the mirror
python3 fdd3000/test/fuse_shot.py OUT.png 'root\r' 'trek\r' '~300'   # a Fuse screenshot
```

`tools/zxdfs.py` makes, fills, lists and checks ZXFS file systems in disk
images on the host (its docstring is the format's specification).

## How it is put together

| | |
|---|---|
| `src/boot.asm` | the boot sector: the FDD3000 boot ROM loads it to 3F00h; it loads the system from track 1 |
| `src/hal.asm` | the hardware layer: vectors, the console on the link (CBIOS A1.1's protocol) as a VT52, keys, the soft clock |
| `src/fd.asm` | the WD1770 driver, the buffer cache, `/dev/fd0-3` |
| `src/vfs.asm`, `src/zfs.asm` | mounts, file system types, the i-node cache; ZXFS |
| `src/ssx.asm`, `src/t_dd.asm`, `src/t_fs.asm` | SSX1 from files; `dd`; `mount`, `umount`, `mkfs` |
| `src/mirror.asm` | the display file read back to the terminal |
| `tools/` | `build.py`, `fddimage.py` (the disk), `zxfs.py` (the RAM file system image), `zxdfs.py` (ZXFS), `dsk.py` |

Memory of the FDD3000 while ZX-UX runs:

| | |
|---|---|
| 0000h–0067h | restart vectors; RST 38h = the WD1770's INTRQ |
| 0068h–0FFFh | the Spectrum ROM's place: RST 30h traps (BEEP/BEEPER: RET) |
| 1000h–17FFh | the buffer cache (8 sectors) |
| 1800h–3EFFh | the hardware layer |
| 3F00h–5AFFh | the boot sector, then the old display file: programs draw here |
| 5B00h–FFFFh | ZX-UX as on the Spectrum: kernel data, kernel at 6000h, arena, window at F000h |

### What the FDD3000 does not have, and what replaces it

- **A timer.** The only interrupt is the WD1770's INTRQ (the schematic:
  `/INT` from PAL IC9, whose one interrupt input is the FDC's IRQ; the WD2123
  is not wired to it). Time is counted in software — each system call, each
  character to the terminal, each turn of the idle loop adds its cost — and
  processes are switched at system calls. The clock keeps time while the
  machine waits (24 s measured as 24 s in Fuse) and runs slow while a
  program computes without system calls; such a program also cannot be
  interrupted with ^C until it makes one.
- **A ROM.** Programs that call the Spectrum ROM (the floating-point
  calculator, `RST 10h`) are stopped with a message; BEEP is silent.
- **Port FEh.** On the FDD3000 it is the drive latch: border colour or
  beeper writes would page the boot ROM in. `OUT (FEh),A` in a program is
  made harmless when it is loaded.
- **A display.** The terminal: 80 × 24, VT52. ZX-UX keeps its 64-column
  text; programs' pixels show as `#`, colours are not shown.

## Licence

ZX-UX is © 2026 Supratim Sanyal, SANYALnet Labs, under its own
**non-commercial** licence (`../LICENSE`), which requires the attribution
above in source and in the user interface (the boot banner carries it). Note
that the licence counts use "by or on behalf of" an organisation — a
nonprofit included — as commercial: publishing this port under an
organisation's name may need the author's written permission.
