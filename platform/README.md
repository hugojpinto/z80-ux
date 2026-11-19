# ZX-UX platforms: the hardware seam

ZX-UX was written for one machine, the 48K ZX Spectrum. This directory is
where a build says which machine it is for. The kernel sources in
`zx-ux/src` no longer name a machine: they test **capabilities** and call
**hooks**, and each platform sets them in its `platform.inc`.

```
platform/
  README.md            this file: the contract
  hardware-notes.md    research on the future targets (TC3256, 128K, TC/TS2068)
  manual-notes.md      what the seam changes in the design book's guidelines
  spectrum48/          the 48K Spectrum: ZX-UX as shipped (byte for byte)
  fdd3000/             the Timex FDD3000; its machine layer is fdd3000/src
```

`fdd3000/tools/build.py` stages `platform/<name>/platform.inc` as
`platform.inc` beside the kernel sources (target `spectrum` →
`spectrum48`, `fdd3000` → `fdd3000`); `unix.asm` includes it before
anything else.

## The one rule, and its proof

**Kernel code does not name a machine.** A kernel source line that exists
for one machine is in a driver or the machine layer, or is a hook
(`HAL_IDLE`), and the machine's facts live in its `platform.inc`.

The proof that the seam changed nothing: `build.py spectrum` rebuilds the
Spectrum system from the seamed sources with `spectrum48/platform.inc` and
compares it **byte for byte** with the shipped `ZX-UX.tzx` (kernel, low
kernel, root file system). When the seam went in (branch `hal-seams`), the
FDD3000 system image also came out byte-identical to the one built before
it, and every FDD3000 test passed unchanged.

## Capabilities

Numbers (`equ`), tested with `IF`. Only **subsystems** are switched this
way — parts of ZX-UX a platform includes or not. What the hardware *is*
is not a flag: it is the platform's choice of drivers (below).

| Name | Meaning | spectrum48 | fdd3000 |
|---|---|---|---|
| `HAL_HZ` | ticks a second: the clock counts this many `ktick` calls to a second | 50 | 50 |
| `HAL_KMAX` | the kernel's budget, KBASE to `kend` (an `ASSERT`) | 8192 | 8192 |
| `HAL_BLKDEV` | disk block devices (`/dev/fdN`); device read/write go to the layer | 0 | 1 |
| `HAL_VFS` | mounts and file system types: sys mount (21), umount (22), i-numbers ≥ 1000h, the i-node cache | 0 | 1 |
| `HAL_SSXFILE` | SSX1 programs from files: exec of an SSX1 file runs `/etc/ldx` on it | 0 | 1 |
| `HAL_BOOTMNT` | `/etc/init` mounts `HAL_SYSDEV` on `HAL_SYSMNT` and runs its `etc/rc`; the shell also searches `HAL_SYSMNT/bin` | 0 | 1 |

Defines (`DEFINE`, strings): **`HAL_DRIVERS`**, the platform's driver
file, assembled right after the kernel's 8K (`platform/spectrum48/
drivers.asm`: `machine.asm`, `rom48.asm`, `screen64.asm`); **`HAL_LAYER`**,
a machine layer assembled at its own address (`fdd3000/src/hal.asm`,
1800h); `HAL_SYSDEV`, `HAL_SYSMNT` (with `HAL_BOOTMNT`).

## The memory map is the platform's

Only the program ABI is fixed (below). Within that, a platform places
its parts: its drivers right after the kernel (`HAL_DRIVERS`), its machine
layer at its own address (`HAL_LAYER`), and the resident programs —
`build.py` writes `userland.inc` (the programs assembled after the
kernel, as on the Spectrum) and `lowtext.inc` (those the platform puts
elsewhere: `LOWTEXT` in `build.py`). The FDD3000 puts `vi` and `zxpack`
at 0400h–0FFFh, where the 48 ROM's routines were, and keeps the ROM trap
zone to 0068h–03FFh: 2,358 bytes more arena. The kernel's size is
`HAL_KMAX`.

## Drivers

`drivers/` holds implementations shared by platforms with the same
hardware; a platform's driver file includes the ones it uses.

- **`drivers/rom48`** — what ZX-UX asks of the 48 BASIC ROM (48K; the
  128K's ROM1, the +2A/+3's ROM3 and the TC3256's BASIC page have the same
  entry points): `rom48.inc` (ROM entry points, system variables, `IM2I`;
  the kernel names no ROM address), `rom48.asm`: `rom_error` (RST 8),
  the tape (`tapwr`, `taprd`, `tclk`), `kclick`, `snd_beep`.
- **`drivers/screen64`** — the console as 64×24 4×8 characters on a
  Spectrum display file: `kputc`, `kcls`, `curon`, `curoff`, `cblnk`,
  the status line `stdraw`, the font; sys screen (`sysscreen`, `scrrel`,
  `cstrip`).

## Hooks

Macros, expanded where the kernel reaches that point. Empty on a machine
that has nothing to do there.

| Hook | Where (kernel) | spectrum48 | fdd3000 |
|---|---|---|---|
| `HAL_INIT` | boot, before the interrupt setup | — | `call hinit` (vectors, trap zone, IM 1, latch) |
| `HAL_START` | boot, before the first process | — | `call tinit` (the WD1770 clock, if drive D is absent) |
| `HAL_IDLE` | `swtch`: nothing runnable | `halt` | `call kidle` (poll, tick, mirror) |
| `HAL_ENTER` | `sysent`, after `kmode` | — | `call kpoll` (keys, BREAK, soft clock) |
| `HAL_LEAVE` | `sysx`, on the way out | — | `call vsync` (mounted i-nodes, disk flush) |
| `HAL_YIELD` | `sysrele` | — | `call myield` (mirror catch-up) |
| `HAL_ZPOLL` | the packer's checkpoint (`zpoll`) | — | `call hzpoll` |
| `HAL_SSXFIX` | `sysssxl`, after relocation | — | `call ssxfix` (defuse `OUT (FEh)`, beep's `HALT`) |
| `HAL_ITABALIGN` | before ITAB | — | `ALIGN 2` |
| `HAL_BANNER` | the boot banner's first lines | shipped text | FDD3000 text + attribution |

## The interfaces the kernel calls

Each platform provides these symbols, through its drivers or its machine
layer:

| Interface | Symbols | spectrum48 | fdd3000 |
|---|---|---|---|
| **Keys** | a key for the kernel: `ttrawin` (A = the key); BREAK: `ttintr` — from the tick | `r48keys` (rom48: KEYBOARD, KEY-INPUT, BREAK-KEY) | `hkeys` (the link) |
| **Time** | its interrupt handler calls the kernel's `ktick` once per tick, every register saved, interrupts off; `ktick` keeps the clock and sleepers, CPU accounting, a device's hold on the CPU, the time slice (switch now in user mode, at the call's way out in the kernel), signals for a program in user mode (may not return) | `isr` (machine.asm): `r48keys`, `s64tick` (status line, cursor), `ktick` | `tint` (WD1770), `stick` (soft clock) |
| **Console** | `kputc` (A; the kernel's AT/INVERSE codes), `kcls`, `curon`, `curoff`; keys come back through the kernel's `ttrawin`, BREAK through `ttintr`; `stdirty` marks the status line | screen64 | the VT52 terminal (hal.asm) |
| **Program screen** | `sysscreen`, `scrrel`, `cstrip` (sys screen, 39) | screen64 | the display mirror |
| **Key click, sound** | `kclick`; `snd_beep` (HL, DE as BEEPER) | rom48 | `kclick equ hret` |
| **Memory** | `mem_swapout` (A = slot: the window as it is becomes that slot's image), `mem_swapin` (A = slot: its image into the window) — the scheduler's lazy hand-over, fork, exec | `equ wsave`, `wload`: a copy to and from the slot's SAVE block in the arena | the same |
| **Boot** | `HAL_INIT` (vectors, interrupt mode, ...), `HAL_START` | `sp_init` (machine.asm): IM 2, ERR_SP, L mode | `hinit`, `tinit` |
| **Devices** | `devtab`: entries `db FIRST, LAST` / `dw read, write, open` (0: none), a 0 ends it; read/write: A = device number, the transfer in u_off, u_base, u_count; open: HL = the i-number, CF/A, keeps HL, DE, BC, IX. The kernel's `devfind`, `devread`, `devwrite`, `devopen` use it (iget, open) | tty, mem, tap (machine.asm) | tty, mem, fd0–3 with `hdopen` (hal.asm); seek in sectors (`hseek`, `fhclr`) with `HAL_BLKDEV` |
| **Subsystems** | with `HAL_VFS`: `vfs_iget`, `vfs_ialloc`, `vfs_ifree`, `vfs_trunc`, `vfs_readi`, `vfs_writei`, `vfsix`, `vfscross`, `vbusy`, `vsync`, `sysmnt`, `sysumnt`; with `HAL_SSXFILE`: `hssx`, `ssxrd`, `LDXFD` | — | `drivers/vfs`, `drivers/ssxfile` (shared), over the block interface |

The register conventions are the kernel's own (the routines' headers).
The kernel's IY is `KIY`: 5C3Ah with rom48 (its routines need it), 0 on
the FDD3000.

The optional subsystems are shared sources in `drivers/`, used by any
platform that switches them on: `drivers/vfs` (mounts, the type table and
module loader, `/etc/mount`, `/etc/umount`), `drivers/zxfs` (ZXFS,
`/etc/mkfs`), `drivers/tos` (TOS disks, a module), `drivers/ssxfile`
(SSX1 programs from files). Under them, the **block interface** a
platform with disks provides: `blkunit` (A = a device number → A = its
unit; CF if not a block device), `blkprobe` (A = a unit: what medium is
there), and the buffer cache by unit — `bget` (sector DE of unit A → HL,
B = the buffer), `bdirty` (buffer B written; NC), `bflush`, `binval`; the
FDD3000's are in `fd.asm` (units are its drives). Seeking a block device
in sectors (seek origins 3–5) is `hseek`, `fhclr`.

## The ABI: what binaries pin, and what they do not

**SDK programs (SSX1) are relocatable**: `rld` writes a relocation
stream, the kernel relocates the image wherever it loads it. What an SSX1
binary pins is only what its runtime (`sdk/bin/py/lib`) names as an
absolute address:

| Pin | Who | Note |
|---|---|---|
| **6003h** | every program (`SYS`) | the system-call entry: a `jp` there is enough |
| call numbers 0–40, the SSX1 format | every program | 21/22 = mount/umount where `HAL_VFS`, else EINVAL |
| **5BE4h** (`TTOP`) | programs that draw (`console.asm`) | the shared console rows; goes with a screen-page call |
| **4000h** screen | programs that draw, built without `rcc --ux`, and the fixed kind | `--ux` bitmap programs ask call 41 for the page (the FDD3000's is in the arena) |
| **5C3Dh–5C92h** (ERR_SP, STKBOT, STKEND, MEM, MEMBOT) | programs using floats (`float.asm`) | the ROM calculator: only with the 48 ROM (rom48) |
| port **FEh** keyboard rows | `sys.asm` (key reads) | the ULA's keyboard: only where the keyboard is the ULA's |

**Everything else is per build**: the kernel's place (6000h), its
variables (5B00h, but 5BE4h), the resident programs (rebuilt with the
kernel), ITAB, the arena, the window (F000h) and the u-area. They are
fixed on the Spectrum because the Spectrum build must equal the shipped
tape; another platform may lay memory out to suit its hardware, keeping
only the pins above (a 3-byte `jp` at 6003h, a byte at 5BE4h).

## The future targets, mapped

Details and sources: `hardware-notes.md`. In short:

### Timex TC3256
- **As a 48K Spectrum** (BASIC page in): `spectrum48` nearly as is. To
  check on the machine: RST 8 from ROM routines now enters the shadow ROM
  first (does `rom_error` still get control?); the IM 2 vector at 39FFh
  holds only if the bus reads FFh at interrupt acknowledge; `ROM_CLS`
  runs patched code that reads 5FFAh–5FFFh (the kernel stack area).
- **Native** (FIRMWARE: RAM at 0000h–3FFFh, like the FDD3000): no rom48,
  its own IM 2 table at 8000h+ and tick, screen64 with its own keyboard
  scan (no ROM: needs the
  keyboard seam below), block devices: the FDD3000 over the link (port
  EFh, the shadow ROM's TOS services or a native driver) and the 208 KB
  RAM disk. Never place code at 0000h, 0008h, 0066h (fetches there trap).
- **Exploit**: RAM-disk sectors are 4 KB, the size of the window: saved
  processes in sectors (window-swap seam below), more process slots, a
  RAM file system.
- Lost while the kernel is at 6000h: second screen, hi-colour, 512-dot
  mode (all use 6000h–7AFFh).

### ZX Spectrum 128K (+2, +2A/+3)
- ROM1 (48 BASIC) / ROM3 has the same entry points: rom48 serves it.
- **The window F000h is inside the paged bank (C000h)**, so are the
  u-area and the IM 2 trampoline: the IM 2 table must move to RAM below
  C000h (also required on the +2A/+3, whose ROM3 breaks the 39FFh vector).
- Natural model: **one 16 KB bank per process**; a switch becomes
  `OUT (7FFDh)` instead of a window copy (window-swap seam). The arena,
  which crosses C000h, splits into a fixed part and a per-process part.
- Boot from 128 BASIC (the paging lock bit), select ROM1 itself.
- Shadow screen (bank 7) as a second console; +3 floppy (µPD765) as a
  block device; spare banks as a RAM disk.

### Timex TC2068 / TS2068
- **No Spectrum ROM** (different bytes at the entry points): no rom48;
  keyboard, screen, tape, beeper drivers in the machine layer.
- **No RAM at 0000h** on a stock machine: the machine layer must fit in
  4000h–FFFFh, so less arena than on the Spectrum.
- `HAL_HZ` **60** on the TS2068 (50 on the TC2068); IM 2 table in RAM.
- SCLD second screen, hi-colour, 512-dot: unusable while the kernel is at
  6000h. Dock RAM cartridges (8 KB chunks, port F4h) as optional banking.
- The Timex FDD interface (port EFh → TOS) as a block device.

## Seams still to cut

What the future targets need that the code does not have yet, with the
kernel sites:

1. ~~Keyboard source~~ — done: the Spectrum's tick is `r48keys` (rom48),
   `s64tick` (screen64), `ktick`; a machine with screen64 but no 48 ROM
   (TC2068, native TC3256) writes its own keys routine for `ttrawin` and
   `ttintr` and keeps the rest.
2. **Interrupt vectors** — the Spectrum's IM 2 setup (`sp_init`) relies on
   the ROM's FFh bytes; a machine without them places a 257-byte vector
   table in RAM in its own `HAL_INIT`.
3. ~~A shared tick~~ — done: `ktick` (step 2 of `DESIGN.md`).
4. ~~Window swap~~ — done: `mem_swapout`, `mem_swapin` (step 6). A 128K
   port binds them to its banks (a switch is `OUT (7FFDh)`; fork copies to
   the child's bank) and can then stop reserving window room in each SAVE
   block (`savefit`); the TC3256 copies to and from RAM-disk sectors.
5. ~~Screen page, terminal console for SDK programs~~ — done
   (`screen-kinds.md`): kinds in the SSX1 flags, `rcc --ux`, call 41; the
   FDD3000 places display files in the arena and its resident text at
   4000h.
6. **Memory layout per platform** — `KBASE`, `KV`, `WINDOW`, `CORE` and
   the 8 KB kernel bound are Spectrum facts in `const.inc`; let a platform
   set them, keeping the pins (6003h, 5BE4h). On the FDD3000 that puts the
   kernel, resident programs and machine layer together low and the arena
   in one piece up to the window (memory-plan, §11). Then a low pool for
   fixed blocks, or, on the 128K, per-process banks.
7. ~~Block devices~~ — done: `devtab` (step 4); the mount layer and the
   file systems use the block interface (`blkunit`, `blkprobe`, the
   buffer cache) and live in `drivers/`, shared.

Each lands the same way: the Spectrum's `platform.inc` reproduces today's
bytes, the gate proves it.
