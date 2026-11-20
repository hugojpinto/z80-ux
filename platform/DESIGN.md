# ZX-UX+: a portable ZX-UX

Branch `portable-hal` of github.com/hugojpinto/zx-ux (a fork of
tuklusan/ZX-UX-The-ZX-Spectrum-48K-Unix-Project; `main` there is the
Timex FDD3000 port). Where the fork stands against upstream:
`../ZX-UX+.md`.

The capability seam (`platform/README.md`, `platform.inc`) took the
machines' names out of the kernel while keeping the Spectrum build equal
to the shipped tape. This plan lifts that constraint: the hardware
boundary becomes routines with contracts, and each platform composes the
kernel, its drivers and its memory map. Upstream's tape stays
reproducible from upstream's tree; this tree is checked by behaviour.

## Layers

```
kernel/              portable: processes, scheduler, ktick, system calls,
                     RAM file system, arena, packer, tty discipline, exec
drivers/             shared implementations behind one interface each:
  rom48/             keyboard, BREAK, beeper, tape through the 48 BASIC ROM
                     (48K; 128K/+3 ROM1/ROM3; TC3256 BASIC page)
  screen64/          the 64x24 console in 4x8 glyphs on a bitmap page
  vt52link/          the FDD3000's terminal over the link
  vfs/ zxfs/ tos/    mounts and file systems, over a block interface
  ssxfile/           SSX1 programs from files
                     (the FDD3000's own drivers - WD1770, link, clock,
                     no screen - are its machine layer, fdd3000/src)
platform/<machine>/  memory map, boot, vectors and tick source, paging, the
                     choice of drivers; its system.asm is the top-level
                     assembly: it places and includes everything
```

## Interfaces (entry points with register contracts)

| Interface | Entry points |
|---|---|
| Time | the platform's interrupt acknowledges its hardware and calls `ktick`; `HZ`; `hal_idle` |
| Console | `con_init`, `con_putc` (A), `con_cls`, `con_cursor`; input reaches the kernel through `tty_in`, `tty_intr` |
| Program screen | system calls 39 (claim/release) and 41 (page): `scr_claim`, `scr_release`, `scr_page` |
| Sound | `snd_beep` (HL, DE as the ROM's BEEPER) |
| Devices | a table: major → open, read, write, seek, probe |
| Memory | the map (kernel, KV, window, arena regions); `mem_swapout`, `mem_swapin` for a process window |
| Boot | platform `boot` → `kmain` |

The program ABI stays: `jp sysent` at 6003h on every platform, the call
numbers, SSX1; 5BE4h and the 4000h screen where a screen exists, until the
SDK runtime uses call 41.

## Checks

1. **Golden behaviour, Spectrum.** Sessions scripted on the SDK's
   headless Spectrum (`sdk/bin/py`), run against the shipped tape, recorded,
   and replayed against every build of this tree (`test/spectrum`).
2. **Upstream reproducible.** `build.py upstream` rebuilds upstream's
   own sources (`UPSTREAM_REF`) and must equal the shipped tape.
3. **FDD3000**: `fdd3000/test`, all of it, every step.
4. **Sizes**: per-platform region budgets reported by the build.

## Steps (each one reviewed before the next)

1. Golden Spectrum behaviour tests from the shipped tape. Nothing else
   changes. **Done.**
2. `ktick`: the clock, CPU accounting, quantum and signals, once; the
   Spectrum's frame ISR and the FDD3000's `tint` call it. **Done.**
3. rom48 and screen64 out of the kernel; console and sound interfaces;
   the `ROM_*` addresses leave `const.inc`. **Done.**
4. A device table instead of `devread`/`devwrite` and `hdevok`. **Done.**
5. The platform as the top-level assembly; a memory map per platform (the
   FDD3000's larger arena: `fdd3000/docs/memory-plan.md` §11). **Done**,
   as include points the platform owns (`HAL_DRIVERS`, `HAL_LAYER`, the
   generated `userland.inc`, the layer's text places `TXn` packed by the
   build, `HAL_KMAX`) rather than by splitting `unix.asm`: the same
   freedom, a smaller change to upstream's file. On the FDD3000 all
   resident text is below 5B00h: arena 26,244 bytes free at boot
   (memory-plan §13-14).
6. `mem_swapout`/`mem_swapin`: the seam the 128K (bank switch) and the
   TC3256 (RAM-disk sectors) need. **Done**: the four places that move a
   window (the scheduler's hand-over, fork, exec) call them; both
   platforms bind them to the arena copy (`wsave`, `wload`) with `equ`,
   so their code is byte for byte step 5's.

Rule for every commit in this repository: no AI attribution, no
`Co-Authored-By`.
