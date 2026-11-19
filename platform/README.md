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
for one machine sits behind a capability (`IF HAL_ROM`) or is a hook
(`HAL_IDLE`), and the machine's facts live in its `platform.inc`.

The proof that the seam changed nothing: `build.py spectrum` rebuilds the
Spectrum system from the seamed sources with `spectrum48/platform.inc` and
compares it **byte for byte** with the shipped `ZX-UX.tzx` (kernel, low
kernel, root file system). When the seam went in (branch `hal-seams`), the
FDD3000 system image also came out byte-identical to the one built before
it, and every FDD3000 test passed unchanged.

## Capabilities

Numbers (`equ`), tested with `IF`. *Machine* ones say what the hardware
is; *subsystem* ones switch on optional parts of the kernel that any
machine with the right hardware could use.

| Name | Meaning | spectrum48 | fdd3000 |
|---|---|---|---|
| `HAL_ROM` | the 48K Spectrum ROM is paged in and used: keyboard scan (KEYBOARD, KEY-INPUT, BREAK-KEY), BEEPER, tape (SA/LD-BYTES), CLS, and its RST 8 errors (caught through ERR_SP → `rom_error`) | 1 | 0 |
| `HAL_FRAMEIRQ` | the kernel's own frame ISR (`isr`): IM 2 with I = 39h, relying on the ROM's FFh bytes at 39FFh, trampoline at FFF4h; keys via the ROM. **Spectrum-specific**: a machine whose frame interrupt does not fit this says 0 and ticks through its machine layer (see *Time*) | 1 | 0 |
| `HAL_ULAFE` | `OUT (FEh)` is the ULA (border, beeper, key click) | 1 | 0 (the drive latch) |
| `HAL_TAPE` | the cassette: `/dev/tap`, `/dev/cassette`, SSX1 from tape, `tar` to tape, the tape clock (`tclk`) | 1 | 0 |
| `HAL_CONSOLE` | `CON_SCREEN`: the kernel draws its 64×24 console with its font, status line, cursor (`stdraw`, `FONT`, `sysscreen`); `CON_TERMINAL`: the machine layer is the console (below) | `CON_SCREEN` | `CON_TERMINAL` |
| `HAL_HZ` | ticks a second: the clock counts this many `clk1` calls to a second | 50 | 50 |
| `HAL_BLKDEV` | disk block devices (`/dev/fdN`); device read/write go to the layer | 0 | 1 |
| `HAL_VFS` | mounts and file system types: sys mount (21), umount (22), i-numbers ≥ 1000h, the i-node cache | 0 | 1 |
| `HAL_SSXFILE` | SSX1 programs from files: exec of an SSX1 file runs `/etc/ldx` on it | 0 | 1 |
| `HAL_BOOTMNT` | `/etc/init` mounts `HAL_SYSDEV` on `HAL_SYSMNT` and runs its `etc/rc`; the shell also searches `HAL_SYSMNT/bin` | 0 | 1 |

Defines (`DEFINE`, strings): `HAL_LAYER`, the machine layer's source,
assembled after the kernel image (none on the Spectrum: its ROM is its
machine layer); `HAL_SYSDEV`, `HAL_SYSMNT` (with `HAL_BOOTMNT`).

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

## What the machine layer provides

When a capability hands work to the machine layer, these are the symbols
the kernel expects from it (today all in `fdd3000/src`):

- **`HAL_CONSOLE = CON_TERMINAL`**: `hputc` (= `kputc`: A = character,
  with the kernel's AT/INVERSE codes), `hcls`, `hret` (cursor on/off: the
  terminal draws its own); `sysscreen`, `scrrel`, `cstrip` (sys screen 39
  for programs that draw: the FDD3000's display mirror).
- **`HAL_FRAMEIRQ = 0`** (time): something must call `clk1` `HAL_HZ` times a
  second, account CPU, run the time slice and deliver signals, as `isr`
  does on the Spectrum. On the FDD3000: `tint` (tmr.asm) on the WD1770's
  interrupt, else `kpoll`/`kidle`/`htime` counting T-states (the soft
  clock). *To do when a second such machine comes: lift that common body
  out of `tint` into a shared `ktick`.*
- **`HAL_BLKDEV`**: `fdread`, `fdwrite` (devread/devwrite), `hdevok`
  (iget: is this device number ours), `hdopen` (open: probe a disk),
  `hseek` (seek origins 3–5, in sectors), `fhclr`.
- **`HAL_VFS`**: `vfs_iget`, `vfs_ialloc`, `vfs_ifree`, `vfs_trunc`,
  `vfs_readi`, `vfs_writei`, `vfsix`, `vfscross`, `vbusy`, `vsync`,
  `sysmnt`, `sysumnt`; the programs `/etc/mount`, `/etc/umount`,
  `/etc/mkfs` (`t_fs.asm`, `t_mkfs.asm`).
- **`HAL_SSXFILE`**: `hssx`, `ssxrd`, `LDXFD`; `/etc/ldx`'s file part.

`fdd3000/src` mixes the FDD3000's own code (`hal.asm`, `fd.asm`,
`tmr.asm`, `mirror.asm`, `boot.asm`) with subsystems that are not
FDD3000-specific (`vfs.asm`, `fsmod.asm`, `zfs.asm`, `tfs.asm`, `ssx.asm`,
`t_fs.asm`, `t_mkfs.asm`). They move to a shared tree when a second
platform uses them; their couplings to the FDD3000 today: the drive
numbers (`DEV_FD0`, `NDRV`, `vdisk`), `fprobe` at mount, `bget(drive,
sector)` as the block interface, the buffer cache's place (1000h).

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
| **4000h** screen | programs that draw | until the relocatable screen page (memory-plan, Idea B) |
| **5C3Dh–5C92h** (ERR_SP, STKBOT, STKEND, MEM, MEMBOT) | programs using floats (`float.asm`) | the ROM calculator: only where `HAL_ROM` |
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
- **Native** (FIRMWARE: RAM at 0000h–3FFFh, like the FDD3000): `HAL_ROM`
  0, `HAL_FRAMEIRQ` 0 (own IM 2 table at 8000h+, own tick), screen console
  with its own keyboard scan (`CON_SCREEN` but no ROM: needs the
  keyboard seam below), block devices: the FDD3000 over the link (port
  EFh, the shadow ROM's TOS services or a native driver) and the 208 KB
  RAM disk. Never place code at 0000h, 0008h, 0066h (fetches there trap).
- **Exploit**: RAM-disk sectors are 4 KB, the size of the window: saved
  processes in sectors (window-swap seam below), more process slots, a
  RAM file system.
- Lost while the kernel is at 6000h: second screen, hi-colour, 512-dot
  mode (all use 6000h–7AFFh).

### ZX Spectrum 128K (+2, +2A/+3)
- ROM1 (48 BASIC) / ROM3 has the same entry points: `HAL_ROM` 1.
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
- **No Spectrum ROM** (different bytes at the entry points): `HAL_ROM` 0;
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

1. **Keyboard source** — `isr` calls `ROM_KEYBOARD`/`ROM_KEYINPUT`/
   `ROM_BREAKKEY` (unix.asm, the frame ISR). A screen machine without the
   ROM needs `HAL_KEYSCAN`.
2. **Interrupt vectors** — the IM 2 setup at boot assumes the ROM's FFh
   bytes; machines without them set `HAL_FRAMEIRQ` 0 today. Better: a
   257-byte vector table in RAM, placed by the platform.
3. **A shared tick** — the body of `isr` after the keyboard (clock, CPU
   accounting, quantum, signals) is duplicated in `tmr.asm`'s `tint`; a
   shared `ktick` for machine layers.
4. **Window swap** — `swtch`/`savead` copy the window to and from the
   arena (K_SAVE). Bank switching (128K) or sector swap (TC3256) replace
   that copy: `HAL_SAVEWIN` / `HAL_LOADWIN`, or "map process P".
5. **Screen page** — sys 41 and a relocatable screen in the SDK runtime
   (`fdd3000/docs/memory-plan.md`, Idea B); the 128K's bank 7 and the SCLD
   second screen fit the same call.
6. **Memory layout per platform** — `KBASE`, `KV`, `WINDOW`, `CORE` and
   the 8 KB kernel bound are Spectrum facts in `const.inc`; let a platform
   set them, keeping the pins (6003h, 5BE4h). On the FDD3000 that puts the
   kernel, resident programs and machine layer together low and the arena
   in one piece up to the window (memory-plan, §11). Then a low pool for
   fixed blocks, or, on the 128K, per-process banks.
7. **Block devices** — a device table instead of the FDD3000's names, so
   the FDD3000 link (EFh, for the Spectrum, 128K, TC2068, TC3256), the +3
   FDC and RAM disks can coexist.

Each lands the same way: the Spectrum's `platform.inc` reproduces today's
bytes, the gate proves it.
