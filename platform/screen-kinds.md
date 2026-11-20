# SDK programs and the screen: three declared kinds

For the SDK (`sdk/bin/py`) and the kernel, z80-ux branch `portable-hal`.

**Status.** Built: the kinds, `rcc --ux` (`sdk/bin/py/libux`: the
terminal runtime `libtty.ssa`, the relocatable bitmap runtime), the
console's colour codes, call 41, the FDD3000 system disk's programs
built this way, and on the FDD3000 the display file in the arena with
resident programs at 4000h-5AFFh (arena 13,724 → 20,614 bytes; 24,954
since the text places and no tar, memory-plan §13). Tests:
`test/spectrum/kinds.py`, `fdd3000/test/test_kinds.py`,
`fdd3000/test/test_ssx.py`. Where the building departed from this
sketch, the sections below say so ("as built").

## Why

Every SSX1 program claims the screen today: `crt0.asm` calls `@scrinit`
(system call 39) before `main`, and `console.asm` then draws its text
into the display file at 4000h. A program that only `printf`s is treated
like `mandel`. On the Spectrum that costs nothing (the display is fixed
RAM). On the FDD3000 it keeps 3F00h–5AFFh as a screen nobody sees, runs
the display mirror (row checksums, glyph hashing) for plain text, loses
redirection and pipes (`fortune > f` writes nothing), and blocks the
larger memory map (`fdd3000/docs/memory-plan.md` §11).

## The three kinds

| Kind | The program uses | It needs | Rendered by |
|---|---|---|---|
| **stream** | `putchar`, `puts`, `printf` (output as a stream) | nothing | `write(1, ...)`: the console, a file, a pipe |
| **console** | the above plus `print_at`, `cls`, `cursor_at`, `inverse`, `ink`, `paper`, `bright` | nothing in the program | the kernel's console, through `write(1)` with its control codes (below): screen64 on screen machines, the terminal on the FDD3000 |
| **bitmap** | `plot`, `point`, `draw`, UDGs, `over`, `flash`, attribute reads, `screen()`, its own writes to the display file | a display file, 6,912 bytes | the program, directly (a machine with no screen - the FDD3000 - refuses it) |

A program is the most demanding kind any routine it links needs. Most of
the examples are stream or console (`trek`, `advent`, `rogue`, `hangman`,
`quiz`, `wump`, `fortune`, `hello`, `arith`); bitmap ones are the
graphical demos and games (`mandel`, `3dpaint`, `invaders`, `orcattack`,
`colors`, `wire3d`, ...).

## 1. The declaration: two bits of the SSX1 flags byte

```
flags bit 0   (as today)
      bit 3      1: the kind below is declared (rcc --ux); 0: an older
                 binary, which claims the screen and draws at 4000h
      bits 2-1   00 stream   01 console   10 bitmap   11 bitmap, fixed at
                                                         4000h (the program
                                                         writes it itself)
      bit 4      with the console kind: its console is 32 columns wide
                 (rbc --ux, a BASIC program: see "A narrow console" below)
```

*As built:* bit 3 was added so that a declared stream program (00) and an
older binary (flags 0, but drawing at 4000h) can be told apart - which a
platform that uses 4000h-5AFFh for something else must do.

- **Old binaries** have bits 2–1 = 00 but do claim the screen through
  `@scrinit`: the kernel keeps treating call 39 as it does now, so they
  run unchanged. A new binary's kind is a promise; an old one's is
  unknown, and the kernel finds out at call 39 as today.
- **The SDK's loader check** (`rld.py`: `flags & ~1` is rejected) accepts
  bits 1–2. The kernel ignores the flags byte today; it starts reading
  bits 2–1 in `sysssxl`.

## 2. The linker decides (`rld`)

*As built:* the classification is done in `rcc --ux` from what the
program references (its own objects and the library members it pulls,
not the console's internals), not by kind marks in the runtime's members:
`lib/build.py` cuts the runtime into members at labels, and the screen's
start-up shares a member with `cls`, which would have marked every
program "console". The API sets are `BITMAP_API` and `CONSOLE_API` in
`rcc/driver.py`; a program with an assembly companion is `fixed`;
`--kind=` overrides. A stream or console program is then linked again
with `libtty.ssa` before `libc48.ssa`: it carries no glyph code at all
(`trek` 3,413 bytes instead of 3,645).

The sketch:

`rld` links only the archive members a program reaches. Each console
member carries a **kind mark**, a symbol it defines:

- `__kind_console` in the members of `print_at`, `cls`, `cursor_at`,
  `inverse`, `ink`, `paper`, `bright`;
- `__kind_bitmap` in `plot`, `point`, `draw`, the UDG routines, `over`,
  `flash`, `@attr` reads, `screen()`, `border`.

After linking, `rld` sets bits 2–1 to the highest mark present. Overrides:
`rcc --kind=stream|console|bitmap|fixed` (and `rld -k`), for programs
that touch the display file through pointers or assembly - `invaders` and
`orcattack` are `fixed`. `rld -v` prints the kind and the member that set
it, so a program that turns out bitmap because of one `point()` says why.

## 3. The runtime: three consoles in one archive

`crt0` stops calling `@scrinit`; each kind's first use initialises it:

- **stream**: `putchar` buffers and `write(1)`s (flushed at a newline, a
  full buffer, `getchar`, `sleep`, `yield`, exit). No screen, no claim.
  *As built:* a program that placed text (`cursor_at`, `print_at`) leaves
  the cursor below the lowest row it wrote at exit, so the shell's prompt
  does not land on its screen.
- **console**: `print_at`, `cls`, ... emit the kernel console's codes into
  the same buffer. It asks the console's size once (call 41, below): 64×24
  on the Spectrum, 80×24 on the TT3000; `print_at` keeps its 64-column
  arguments (layouts are written for 64), the extra 16 columns are free.
- **bitmap**: today's `console.asm`, with the display file's page from
  call 41 (`@scrhi`: `or 40h` → `add a,(@scrhi)`, `or 58h` → `+18h`) and
  the claim (39) as now. On a Spectrum, call 41 does not exist (EINVAL):
  the page is 40h.

So one binary runs on every machine: on a Spectrum, the console kind
prints through the kernel's screen console, which draws the same pixels
`console.asm` draws today.

## 4. The console protocol (kernel)

The codes `kputc` takes, with two additions (the Spectrum's own codes,
which every Spectrum program already knows):

| Code | Meaning | screen64 | FDD3000 terminal |
|---|---|---|---|
| 7, 8, 9, 10, 12 | bell, backspace, tab, newline, clear | as now | as now (VT52) |
| 16h r c | AT row, column | as now | `ESC Y r+32 c+32` |
| 14h n | INVERSE | as now | `ESC L` / `ESC M` |
| **10h n** | **INK** | attribute ink | dropped |
| **11h n** | **PAPER** | attribute paper | dropped (paper ≠ 7: reverse) |
| **13h n** | **BRIGHT** | attribute bright | dropped |

They reach the console through `write(1)` like any byte (`ttwrite` →
`kputc`). A stream written to a file keeps them; `cat` of that file shows
the picture again — as on a Spectrum with its ROM's codes.

## 5. Call 41: the screen, described

`sys 41` (new; `badsys` on an upstream kernel: EINVAL, carry):

```
in:   HL = 0: describe;  HL = 1: claim a display file (bitmap kind);
      HL = 40h: claim exactly 4000h (fixed kind)
out:  D = the display file's page, E = what the console is: 0 a screen
      the kernel draws, 1 a terminal; L = columns, H = rows of the console
      (as built: in DE and HL - the kernel's sysok clears A)
      CF, A = ENOMEM / EBUSY when no display file can be had
```

Per platform:

- **spectrum48** (and 128K, TC2068, TC3256 as Spectrums): page 40h always;
  64×24, a screen.
- **fdd3000**: the display file comes from the low pool (3F00h–5AFFh, at
  4000h when free), else the arena (page-aligned, 27 pages, fixed block),
  freed at exit; 80×24, a terminal. The mirror reads the owner's page.

  *As built, since 2026-11-19:* **no screen.** The console is a terminal;
  a program that draws (the bitmap or fixed kind, or an older undeclared
  one) is refused at load ("this program draws: it needs a screen":
  `ssx.asm`, `HAL_SCREEN equ 0`), call 39 refuses a claim, call 41 answers
  D = 0 (no display file), E = 1, 80 (or 32) x 24. The mirror and the
  display file in the arena are gone (`fdd3000/src/screen.asm`): about
  3.1 KB of the HAL, the arena's 6.9 KB never taken. The paragraph below
  is how it was.

  *As built:* no low pool - 4000h–5AFFh holds resident programs, so the
  display file always comes from the arena (kind `K_DISP` 7, fixed,
  6,912 + 255 bytes for the page alignment), allocated by the claim (call
  39, or 41 with HL = 1), one for all programs that draw, freed when the
  last owner lets go. HL = 40h is refused (EBUSY). The runtime claims with
  39 first, then asks 41 for the page, so the file cannot be freed between
  the two. A program that needs 4000h (flags bit 3 clear, or the fixed
  kind) is refused at load by the SSX1 loader (`HAL_SCR4000 equ 0`).
  The page is any page (B1h, say), not 8K-aligned like 40h: the bitmap
  runtime adds it last when it builds an address (`@pxad`) and takes it
  off before reading a pixel address's third (`@pxat`).

## A narrow console (flags bit 4)

*As built.* A console-kind program may declare its console 32 columns
wide (bit 4 with bits 3, 2-1 = 1, 01: flags 1Ah) - BASIC's screen.  The
SSX1 loader (call 40, `sysssxl`) keeps the bit for the process (`conar`
in `unix.asm`, a bit a slot as `scrown`; a child of fork has its
parent's, exec and exit clear it); call 41 answers L = 32 to it.  Its
output keeps the console's codes, in its own columns:

- **spectrum48** (`screen64`): its characters are 8x8, from the ROM's
  font (`HAL_FONT8`, 3D00h), each on a whole attribute cell (its colours
  exactly, not shared with a neighbour), at physical column 2c; AT takes
  columns 0-31; past the last column the next line comes with the next
  character, as PRINT's (no scroll at the bottom before it).  Narrow and
  wide output share the screen: the cursor is kept in 64 columns.
- **fdd3000** (a terminal): nothing changes - column c is the terminal's
  column c.

Older kernels ignore the bit (64 columns, the 4x8 font, all else works).

## Keys behind a terminal

`kbd_down`, `kbdmatrix`, `kbdpoll` read the Spectrum's keyboard rows
(port FEh). A terminal sends characters, not key states, so where call 41
says the console is a terminal (E = 1: the FDD3000) libux's versions
(`libux/sys.asm`) report no key down, without touching the port (the
FDD3000's drive latch). Programs read the terminal with `getchar`. On a
kernel without call 41 they read the rows as before.
  With no bitmap program running, the pool holds other fixed blocks
  (memory-plan Idea C) - and once no program draws at 4000h by default,
  the resident text can move low (§11): ~28 KB of arena.

## 6. The kernel at load and exit

- `sysssxl` reads the kind: **bitmap**/**fixed** - reserve the display
  file (call 41's path) before the image, fail with ENOMEM early rather
  than in the middle of `main`; **console**/**stream** - nothing.
- Exit (`release`) frees what was claimed (as `scrrel` does today).
- The "two programs, one screen" rows (`TTOP`, 5BE4h) stay for bitmap
  programs; console programs share the console line by line as resident
  programs do.

## 7. What it costs, what to watch

- Bitmap programs on the FDD3000 pay their display file (6.9 KB) from
  the pool or the arena instead of a fixed area: a large bitmap program
  plus a large module may not fit together.
- Console programs lose what only a bitmap has: reading the screen back,
  pixels, FLASH, OVER. The linker puts any program that uses them in the
  bitmap kind, so nothing silently breaks.
- The SDK changes are in upstream's tree (`sdk/bin/py`): kept side by side
  with the original runtime (`build.py` must still rebuild the shipped
  `.ssx` files byte for byte from it), and offered upstream with call 41.
- Tests: `test/spectrum/golden.py` with relinked programs (console kind on
  the Spectrum draws what it drew); FDD3000: `fortune > f`, a pipe,
  `trek` with no display file reserved, `mandel` with one, `invaders`
  fixed at 4000h.

## Order of work

1. Console codes 10h/11h/13h in screen64 and the FDD3000 terminal; call
   41 (describe only).
2. The runtime's stream and console kinds; kind marks; `rld` sets the
   bits; relink the system disk's programs.
3. Call 41's claims, the bitmap kind's `@scrhi`; the FDD3000 low pool;
   the mirror on any page.
4. The resident text low on the FDD3000 (memory-plan §11).
