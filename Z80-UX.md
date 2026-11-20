# z80-ux and ZX-UX

**z80-ux** (github.com/hugojpinto/z80-ux) is a fork of **ZX-UX**,
*the ZX Spectrum 48K Unix project* by Supratim Sanyal of SANYALnet Labs
(github.com/tuklusan/ZX-UX-The-ZX-Spectrum-48K-Unix-Project). It takes
ZX-UX to other Z80 machines: first the **Timex FDD3000**, a disk unit with
its own Z80 and 64K, used through a Timex computer as a terminal; and,
along the way, a portable hardware layer for more of them (the 128K
Spectrum, the TC3256, the TC/TS2068: `platform/hardware-notes.md`).

`README.md`, the book in `docs/` and the licence are upstream's and
describe ZX-UX; this file says where the fork stands against it.

## Branches

| | |
|---|---|
| upstream `main` | ZX-UX. The fork follows it; its sources at **`f302288`** (2026-11-17) are the ones that make the shipped `zx-ux/tzx/ZX-UX.tzx` |
| `main` | the FDD3000 port, upstream merged (to `f302288`) |
| `portable-hal` | the hardware layer (`platform/DESIGN.md`), the SDK's portable runtime, BASIC without the ROM, memory per platform; ahead of `main` |

## What is upstream's, unchanged

Byte for byte as upstream has them: `README.md`, `LICENSE`,
`THIRD-PARTY`, `docs/` (the book), `examples/` (the programs and their
built `.ssx`), `sdk/bin/py/lib` (the SDK's runtime) and the shipped tape
`zx-ux/tzx/`. The SDK's tools keep their upstream behaviour by default:
what the fork adds to them is behind an option (`rcc --ux`, `rbc --ux`)
or beside them (`sdk/bin/py/libux`).

**Upstream stays reproducible**: `fdd3000/tools/build.py upstream` takes
upstream's own kernel sources at `f302288` from git and rebuilds them byte
for byte into the shipped tape's kernel, low kernel and root file system
(upstream ships no builder; the generated includes are reconstructed).
Every build runs this gate.

## What the fork changes

**The kernel sources (`zx-ux/src`)** are shared by every machine and no
longer name one: what a machine does differently is a capability or a
hook its `platform/<machine>/platform.inc` sets (`platform/README.md`).
Fourteen files differ from upstream's. The changes:
- the machine out of the kernel: the Spectrum's keyboard, screen, ROM and
  tape into drivers (`drivers/rom48`, `drivers/screen64`); a device table
  (`devtab`) for the devices, with their kinds (sector devices
  `HAL_BLKDEV`, sequential ones `HAL_SEQDEV`); the clock as `ktick`, the
  memory map and the window's swapping (`mem_swapout`/`mem_swapin`) per
  platform;
- disks: mounts and file system types (`HAL_VFS`: system calls 21 and 22,
  which upstream leaves unused; `drivers/vfs`,
  `drivers/zxfs`, modules such as TOS's), SSX1 programs run from files
  (`HAL_SSXFILE`);
- for programs: system calls 41 (where the display is, and its size) and
  42 (floats, from the platform's engine); SSX1 flags that declare a
  program's kind (stream, console, bitmap, fixed) and a 32-column console;
  a raw terminal read that does not wait (`TT_NOWAIT`);
- the resident programs: placed in whatever free places the machine has
  (`build.py place()`), and the few lines they share with programs a
  machine leaves out (`tar` without a cassette) made independent of them.

**The Spectrum build of this tree is no longer the shipped tape byte for
byte** (kernel 7,523 bytes, 10,736 free in the arena). It is held to
**behaving** as the shipped tape does: `test/spectrum/golden.py` replays
sessions recorded on `ZX-UX.tzx` (shell, files, processes, `zxpack`,
`vi`, `tar` on the cassette, SDK programs from the cassette) and compares
the screen, masking only what may differ without a change of behaviour
(clock, free memory, code sizes).

**Programs**: an SSX1 program built by upstream's SDK runs on this
Spectrum kernel unchanged (the golden sessions run the shipped `.ssx`
files). Programs built with `rcc --ux` also run on upstream's kernel: they
ask for calls 41 and 42 and fall back to the Spectrum's own places when
the kernel does not have them (`test/spectrum/kinds.py` runs them on the
shipped tape too). On a machine without a screen (the FDD3000) a program
that draws is refused at load; one that only writes text runs on the
terminal.

**Added**, beside upstream's tree: `platform/` (the machines and the
designs: `README.md` the contract, `DESIGN.md` the plan, `screen-kinds.md`,
`float.md`, `basic.md`), `drivers/`, `fdd3000/` (the FDD3000's layer,
tools and tests), `sdk/bin/py/libux` (the portable runtime; `rbc/` a
clean-room replacement for the ROM routines BASIC programs call),
`test/` (the Spectrum's golden sessions, the float engine's, BASIC's).
`python3 test/all.py` runs every check, the upstream gate included.

## Clean room

The 48K ROM is never a source of code. Where the fork replaces what
programs took from it (the floating-point calculator, `drivers/fp`; the
BASIC runtime's ROM routines, `sdk/bin/py/libux/rbc`), the replacement is
written from what the routines do and tested against the ROM as an
oracle (`test/fp`, `test/basic/romdiff.py`).

## Licence and credit

ZX-UX's non-commercial licence (`LICENSE`) covers the fork too; the
fork's files say *Based on original work by Supratim Sanyal of SANYALnet
Labs (ZX-UX)*. What could be useful upstream - the hardware seam, calls
41 and 42 with the portable runtime - is for its author to take or leave
(`platform/manual-notes.md`: what the seam would mean for the book).
