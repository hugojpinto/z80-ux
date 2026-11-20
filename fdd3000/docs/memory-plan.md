# Memory for user programs on the FDD3000: notes and options

Status: **notes for a decision, nothing implemented.** Written 2026-11-17 on
branch `fdd3000-port` (after `03e3597`, the TOS module). Figures are from that
build and from runs on the emulated FDD3000 (`fdd3000/test/fddrun.py`).

The question that started it: TOS disks mounted cost ~3 KB of arena and then
the largest SDK program (`chess`) no longer fits. From there: where is RAM
actually free, can SDK programs stop drawing into a screen nobody sees, can the
screen move, and what would give user programs more room.

---

## 1. The memory map today

FDD3000 build (`build/fdd3000/kernel.json`):

| Range | Size | Contents | Movable? |
|---|---|---|---|
| 0000–0067h | 104 B | restart vectors; RST 38h = WD1770 INTRQ (`hint38`) | no |
| 0068–0FFFh | ~4 KB | ROM trap zone: Spectrum ROM calls land on RST 30h, the program is stopped; BEEP/BEEPER stubs | could shrink (see §8) |
| 1000–17FFh | 2 KB | buffer cache, 8 × 256 B (`fd.asm` NBUF, BUFMEM) | NBUF could drop to 4 |
| 1800–3EFFh | 9,983 B | hardware layer (HAL): console/VT52, keys, disk driver, vfs/inode cache, type table, built-in ZXFS, mirror (+ FONT at 305Ch), WD1770 clock, `dd`. **Full: 1 byte spare** | layout is ours |
| 3F00–5AFFh | 7,168 B | boot sector at power-on, then the old Spectrum display file (6,912 B at 4000h): SDK programs draw here, the mirror reads it back | ours (FDD only) |
| 5B00–5D97h | ~660 B | kernel variables (KV 5B00h, `fsp` 5B98h, MEMBOT 5C92h, KV2 5CEBh) | **no: ABI** |
| 5D98–5FFFh | ~620 B | low kernel (110 B) and kernel stack | no |
| 6000–7C1Bh | 7,196 B | kernel; `jp boot` 6000h, `jp sysent` **6003h** | **no: ABI** |
| 7C1C–B4C9h | ~14.5 KB | resident program text (shared, runs in place) + ulib | contents ours |
| B4CA–B609h | ~320 B | boot code (run once) | — |
| B60A–B909h | 768 B | RAM i-node table (24 × 32) | — |
| B90A–EFFFh | 14,070 B | **arena**: RAM files and dirs, saved process windows (K_SAVE), SSX1 images (K_IMG, fixed), fs modules (K_FSM, fixed) | — |
| F000–FFB8h | 4,025 B | **window**: running process's data + stack (UDATA = F000h) | **no: ABI** |
| FFB9–FFF3h | 59 B | u-area (CORE) | no |
| FFF4–FFFFh | 12 B | IM 2 trampoline (Spectrum; unused on the FDD3000, which runs IM 1) | — |

Fixed by the program ABI (compiled SSX1 programs and the SDK runtime depend on
them): **6003h** (system call entry), **5BE4h** (`TTOP`, console.asm), **F000h**
(UDATA / window). So the middle of memory cannot move, and the arena cannot be
made adjacent to the 3F00–5AFFh area (they are ~24 KB apart).

### Arena behaviour that matters here (`zx-ux/src/arena.asm`)
- Blocks: size word, kind byte. K_FILE, K_SAVE move (compaction slides them
  down); K_IMG (4), K_TEMP (5), K_FSM (6, ours) are fixed.
- `afind` places a fixed block at the bottom of the *highest* free block that
  fits, so the space above stays next to the window.
- When an SSX1 image does not fit, `lend` joins the window (F000h–CORE) to the
  arena for the program's life; resident-text processes wait meanwhile.
- Fixed blocks fragment the arena: compaction must flow around them.
- `aalloc` falls back to compressing a closed file (`zpress`) when full.

### Measured
| | Spectrum 48K (rebuilt from shipped sources) | FDD3000 |
|---|---|---|
| kernel | 8,192 B | 7,196 B (no tape, ROM ISR, key click) |
| resident text ends | B52Bh | B4C9h (+mkfs, mount, umount) |
| arena region | 14,006 B | 14,070 B |
| arena free at boot | 11,718 B | 11,552 B (bigger root fs: /mnt/a–d, fd0–fd3) |
| arena free after login (`df`) | not measured (~9.8 KB est.) | 9,616 – 9,656 B |
| window | 4,025 B | 4,025 B |
| largest SSX1 program | ~13.8 KB est. | ~13.6 KB measured |

FDD3000, `df` after login 9,616 B, four largest SDK examples from disk:

| | chess 13,055 | orcattack 10,577 | 3dpaint 10,366 | invaders 9,901 |
|---|---|---|---|---|
| nothing mounted but ZXFS | runs | runs | runs | runs |
| TOS mounted (`df` 6,658) | **not enough memory** | runs | runs | runs |

SDK examples: 101 SSX1 programs; need (image + bss + stack + heap) min 1,081 B,
median 5,076 B, max 13,055 B. `trek` 4,051, `mandel` 2,886, `hello` 1,081.

TOS module image: 2,953 B (+4 block header) in the arena while mounted.

---

## 2. The finding: SDK programs draw, ZX-UX programs do not

- ZX-UX's own resident programs (`sh`, `ls`, `cat`, `vi`, `ps`, ...) write to
  fd 1 with `write()`; the kernel's console is the VT52 link. Terminal-oriented,
  redirection and pipes work.
- SDK (SSX1) programs: `crt0.asm` calls `@scrinit` at every start, which claims
  the screen (sys 39) and gets the kernel's FONT address; `console.asm`
  implements `putchar`, `puts`, `print_at`, `cls`, ink/paper/bright/flash,
  plot/point, UDGs **by writing display RAM directly** ("No glass between us and
  the pixels"). Files go through the kernel (`io.asm`); console output does not.
- On the FDD3000 that is why the display mirror exists (`mirror.asm`: Fletcher
  row checksums, font-hash cell matching, VT52 output), why 3F00–5AFFh stays a
  screen nobody sees, and why `fortune > file` writes nothing to the file.

### The SDK source is complete and reproducible
- Compilers in Python: `rcc` (C48, ~5.2k lines), `rbc` (BASIC, ~20k), `rpc`
  (Pascal, ~8.9k), `rfortranc` (~5.6k), `rfc` (Forth), `rb2ct`; `ras.py`
  (assembler), `rld.py` (linker, SSX1), `rtap.py`, `rvm.py`/`zxmachine.py`
  (emulator). Wrappers in `sdk/bin/` are not executable in this checkout: run
  `python3 sdk/bin/rcc ...`.
- Runtime: `sdk/bin/py/lib/` (`crt0`, `console`, `io`, `sys`, `unix`, `arith`,
  `float`, `string`, `vm`, `xvm`, `forth_rt`, `frame`, `xheap`, `xudg`,
  `gfx.c`, `heap.c`), archived by `lib/build.py` into `libc48.ssa`.
- 399 example sources in `examples/*-src`; all 12 programs on our system
  disk's `/bin` have their C source.
- **Verified:** `rcc` rebuilds `trek`, `hangman`, `hello` byte-identical to the
  shipped `.ssx`. So a changed runtime can coexist with a proof that the
  original one still yields the shipped binaries.

### Who touches screen memory directly
- `console.asm`: screen and attribute addresses are built with `or 40h` /
  `or 58h` (lines ~330, 365, 469, 521, 584, 677, 716) and `ld hl,5800h` /
  `5820h` (lines ~51–52, 440–441); also check `ld b,40h` at ~101 (a count or
  a page?) and any `inc h`/page arithmetic around them. Nothing else in `lib/`
  matched a 40xxh/58xxh search.
- C, BASIC, Pascal, FORTRAN, Forth example sources: **none** (they go through
  the library).
- Two assembly games: `examples/c48-src/games/invaders.asm` (`ld hl,04000h`,
  `5800h`) and `orcattack.asm` (`5800h`, comment "5800h + y*32 + x").

---

## 3. Idea A: a terminal console for the SDK runtime

`putchar`/`puts` → buffered `write(1, ...)`; `print_at`/`cls`/cursor → VT52
(`ESC Y r+32 c+32`, `ESC H ESC J`, `ESC K`; the TT3000 also has `ESC L`/`ESC M`
reverse video); colour dropped (or bright/inverse → reverse video at most);
plot/point/UDG cannot be done on a text terminal.

**Pros**
- Text programs (most: `trek`, `advent`, `rogue`, `hangman`, `quiz`, ...)
  become ordinary UNIX programs: redirection, pipes, real scrolling.
- No mirror work for them (CPU), no screen claim, no shared console rows.
- With no graphical program running, 3F00–5AFFh is unused: the precondition
  for Ideas B and C.
- Possibly a smaller runtime per program (no glyph renderer).

**Cons / constraints**
- Programs must be relinked (the runtime is inside each SSX1 file).
- Graphical programs (`mandel`, `3dpaint`, `invaders`, `orcattack`, `colors`,
  demos) keep the screen runtime + mirror.
- Programs that mix text with colour lose the colour.
- 64 columns on Spectrum vs 80 on the terminal: `print_at` coordinates stay
  64-wide; nothing breaks, the right 16 columns stay unused.
- Key input already works through the kernel; unaffected.

**Selection, two ways**
1. Link time: two runtimes (`libc48.ssa` screen, a terminal variant), a flag
   to `rcc`/`rld`. Simple; the program author chooses.
2. Run time: one runtime with both consoles, chosen by what the kernel says
   (sys 41, below). One binary for every machine; costs the size of both.

---

## 4. Idea B: a relocatable screen, base decided by the kernel

The user's framing: on the Spectrum and similar machines the screen page is
40h; other ports decide.

### The obstacle on the Spectrum
`sys screen` (39) returns HL = FONT, E = previous owners. **DE is not
preserved**: `cxoff` → `cxor` reloads DE (`zx-ux/src/dev.asm` ~680). So the
base cannot come back through call 39 on an unmodified Spectrum kernel.

### The protocol: a new, optional call 41
`NSYS` is 41 (`const.inc`): call 41 on the Spectrum hits `badsys` → EINVAL,
carry set. So:

```
sys 39  claim       -> HL = font, E = other owners      (every machine, as now)
sys 41  screen page -> NC: A = page of the screen       (FDD3000, later ports)
          HL = 0: anywhere; HL = 40h: exactly 4000h or refuse (CF)
                    CF: no such call -> page 40h        (Spectrum, unchanged)
```

Optionally 41 also says "no screen: use the terminal" (Idea A at run time).

Runtime: keep the page in `@scrhi`; `or 40h` → `add a,(@scrhi)`, `or 58h` →
`add a,(@scrhi)` + 18h (attributes are 1800h above the bitmap);
`ld hl,5800h` → computed. Requires the screen to start on a 256-byte boundary
(Spectrum addressing puts only the high byte's top bits in the base).

**Pros**
- Spectrum kernel and system untouched (byte-identical gate holds, as it then
  stood); new SSX1 binaries still run there (call 41 fails → 40h).
- One SDK binary portable to any ZX-UX port; a natural thing to offer upstream
  together with the "platform seam" (see the email draft).
- On the FDD3000 the screen can live anywhere the kernel has room.

**Cons / constraints**
- A few bytes and cycles per address calculation, on every machine.
- `invaders.asm`, `orcattack.asm` hard-code 4000h/5800h: they must ask for the
  fixed page (HL = 40h) or be patched (sources are in `examples/`).
- The mirror (`mirror.asm`) must read rows from the owner's base: small change,
  but **the HAL is full** (§7).
- Screen needs 6,912 B (27 pages) contiguous and page-aligned.

---

## 5. Idea C: a low pool for fixed blocks (3F00–5AFFh)

7,168 B = 28 pages. Kernel-side allocator for **fixed** blocks only:
the screen (when claimed), fs modules, SSX1 images; each tries the pool first,
the arena second. Arena code (`arena.asm`) unchanged.

**Pros**
- Small SSX1 programs (≤ ~7 KB; median is 5 KB) run without touching the
  arena; TOS module out of the arena.
- The arena keeps only movable blocks → compacts into one free run → large
  programs and window loans succeed more reliably.
- Total RAM for programs + files with no graphics: ~9.6 KB → ~16.8 KB (+7 KB).
- `chess` with TOS mounted runs again (module in the pool, arena 9.6 KB +
  window 4 KB ≥ 13,055).

**Cons / constraints**
- **Not adjacent to the arena**: the largest single program stays ~13.6 KB.
- A graphical program's screen takes 27 of the 28 pages: conflicts with a
  module or small image already there. Policy needed: screen to the arena
  (costs 6.9 KB there), refuse, or make the graphical program wait.
- The boot sector is at 3F00h only during boot: harmless.
- Saved process images (K_SAVE) are movable: not in this pool (unless Idea D).

### Alternative D: one arena over two regions
Teach `arena.asm` (shared upstream code, IFDEF) to walk two regions in
`afind`, `acompact`, `afreeb`, `aend`. One `df` total; files and saved
processes can live low too. Cons: the allocator's core changes, every
allocation pays, more upstream divergence. Only worth it if the pool sits
idle while the arena is full.

---

## 6. Idea E: resident programs to disk (the lever for one bigger program)

Resident text, 7C1C–B4C9h, sits directly below the arena: every byte removed
from it moves ITAB/AR0 down and grows the arena contiguously (the build lays
this out by itself). Sizes (FDD3000 build, bytes):

| | | | |
|---|---|---|---|
| vi 1,918 | tar/tap 1,831 (one text) | sh 1,422 | mkfs 664 |
| ls 612 | glob 531 | zxpack 440 | top 388 |
| more 369 | date 326 | init 291 | cmp 291 |
| cp 246 | mount 243 | ldx 241 | pwd 224 |
| du 207 | stat 180 | mv 178 | rmdir 177 |
| login 165 | ps 164 | wc 157 | rm 135 |
| od 135 | getty 131 | forktest 125 | sum 111 |
| chmod 101 | ln 97 | cat 91 | mkdir 68 |
| df 65 | sleep 62 | umount 56 | echo, clock 41 |
| hello 28 | beep 13 | cls 11 | (dd 443: in the HAL) |

Programs ~12.6 KB; the rest of the area is ulib (shared library) and boot.
Moving e.g. vi, tar/tap, mkfs, zxpack, top, more, date, cmp, du, stat, od,
sum, forktest (~6.6 KB) → largest program ~20 KB.

**Pros**: the only option that raises the single-program limit; on the
FDD3000 the disk is there anyway; the shell already searches `/mnt/a/bin`.

**Cons / constraints**
- These are resident text in the kernel image, at fixed addresses, sharing
  ulib: each must be rebuilt as a relocatable SSX1 program (`ras`/`rld`), with
  its own copy of the ulib routines it uses (on disk only).
- Loading from disk costs time on every run; resident programs fork for free.
  Keep the ones used constantly or by scripts (`sh`, `ls`, `cat`, `cp`, `mv`,
  `rm`, `echo`, `mkdir`, `init`, `getty`, `login`, `glob`, `ldx`, `mount`).
- Must not be needed before `/mnt/a` is mounted (init path).
- Without the system disk, those commands are gone (on the Spectrum they are
  always there).
- `tap` is useless on the FDD3000 (no tape); `forktest` is a test program:
  cheap first candidates for removal from the FDD build.

---

## 7. Cross-cutting constraints

- **Spectrum byte-identical gate** (`build.py spectrum`): kernel, lowk, fs must
  stay identical to `ZX-UX.tzx`; every change in shared sources IFDEF FDD3000.
  *(As planned then. Since lifted (`platform/DESIGN.md`): upstream's own
  sources rebuild the tape byte for byte; this tree's Spectrum build is held
  to its behaviour, `test/spectrum/golden.py`.)*
- **SDK reproducibility**: keep the original runtime able to rebuild the
  shipped `.ssx` (proof that nothing changed for the Spectrum); new runtime
  side by side, not instead.
- **HAL is full** (1800–3EFEh of 3F00h). Anything new there needs room first:
  move `dd` to the kernel image (443 B), halve the buffer cache (1 KB, slower
  disk), shrink the trap zone, or put new kernel code in the pool area.
- **Kernel image is 7,196 of 8,192 B** (ASSERT): ~1 KB for kernel-side code,
  but any growth there also shifts resident text and costs arena.
- **ABI addresses** 6003h, 5BE4h (`TTOP`), F000h, and the SSX1 format must not
  change.
- **Fixed blocks fragment the arena**; window loans fail if a fixed block sits
  in the window (fsmod already refuses that case).
- **Shared screen rows** (`TTOP`, rows 21–22) exist because two programs may
  draw at once; with per-program screens they could become virtual consoles
  (mirror shows the foreground one) — memory rarely allows two screens.
- **Licence**: ZX-UX's non-commercial licence; the SDK is part of it. Changes
  live in the port's tree; upstream offer through the author.

---

## 8. Smaller, independent wins noted along the way

- Trap zone 0068–0FFFh (~4 KB) mostly filler; ROM calls above 0FFFh already
  hit buffers/HAL unprotected. Could keep only the known entry points (RST
  10h, BEEP 03B5h/03F8h, ...) trapped and use the rest. Risk: a C48 program
  calling an unlisted ROM routine runs into our data instead of a clean stop.
- Buffer cache 8 → 4 buffers: +1 KB, slower directory-heavy work.
- `dd` out of the HAL (443 B) to the kernel image next to mount/umount.
- `dd` reports ENOSPC as "I/O error" (its message table); cosmetic.
- TOS module could live in the pool (Idea C) or, with a pool-less design, in
  the old screen area whenever no program has claimed the screen.

---

## 9. Implementation avenues, in the order that pays best

1. **Terminal runtime (Idea A, link-time first).**
   - Copy of `console.asm` (and `crt0.asm` if `@scrinit` changes) under
     `fdd3000/sdk/` (name TBD); VT52 output via buffered `write`.
   - Build a second archive with `lib/build.py`'s logic; relink the system
     disk's text programs (`hello`, `arith`, `fortune`, `hangman`, `quiz`,
     `advent`, `wump`, `trek`, `rogue`, `snake`; `hanoi`, `queens8` check).
   - fddimage.py builds them from `examples/c48-src` instead of copying
     `examples/c48-bin/ssx`.
   - Tests: test_ssx.py rewritten for terminal output; `fortune > /tmp/f`;
     a pipe.
2. **Call 41 + relocatable screen page (Idea B).**
   - Runtime: `@scrhi`, ~12 sites, call 41 with fallback; the fixed-page form
     for the two assembly games.
   - Kernel (FDD3000): `sys41` in systab (IFDEF); page chosen; mirror reads
     from the owner's page.
   - Check: the Spectrum emulator in the SDK (`rvm`) runs a relinked program
     (call 41 fails → 40h).
3. **Low pool (Idea C).**
   - Allocator for 28 pages (bitmap of pages, or first fit with headers);
     SSX1 load (`sysssxl`), fsmod (`fmload`), screen claim use it first.
   - Policy for screen vs residents of the pool.
   - Tests: chess with TOS mounted; df before/after; a graphical program
     while the pool is busy.
4. **Resident programs to disk (Idea E)**, if a bigger single program is
   wanted: drop `tap` and `forktest` from the FDD build first, then rebuild
   chosen programs as SSX1 into `/mnt/a/bin`.
5. **Two-region arena (Idea D)** only if measurements show the pool idle while
   the arena is full.

## 10. Open questions

- Link-time or run-time choice of console (size vs one portable binary)?
- What should a graphical program do when the pool is busy: screen in the
  arena, wait, or fail? *Settled (§12): no program draws on the FDD3000.*
- Does chess draw (attributes, board graphics) or only print text? Decides
  whether it gains from Idea A.
- Keep 64-column `print_at` semantics on an 80-column terminal, or widen?
  *Settled: call 41 gives the console's width (80, or 32 for a program
  that asks for the narrow console); the program lays out to it.*
- Which resident programs are "always needed" on the FDD3000?
- Offer call 41 + the portable runtime to upstream (with the email), or keep
  it in the port?

---

## 11. Added 2026-11-19: a memory map per platform ("defragmenting")

Found while cutting the platform seam (`platform/README.md`): **SSX1
binaries are relocatable** (`rld` relocation stream; the kernel relocates
at load), and resident programs are rebuilt with every kernel. What a
binary pins is only what the SDK runtime names absolutely:

- **6003h** (`SYS`, every program), the call numbers, the SSX1 format;
- **5BE4h** (`TTOP`) and **4000h** (the screen), for programs that draw;
- **5C3Dh–5C92h** (ERR_SP, STKBOT, STKEND, MEM, MEMBOT) for float users:
  the ROM calculator (so only on `HAL_ROM` machines anyway);
- port **FEh** keyboard rows (`sys.asm`).

The rest — the kernel's place, its variables (except 5BE4h), the resident
text, ITAB, the arena, the window, the 8 KB kernel bound — is the
Spectrum's layout, fixed there because that build must equal the shipped
tape. **Another platform may lay memory out differently**, keeping a
3-byte `jp sysent` at 6003h and the byte at 5BE4h.

What that buys on the FDD3000: the arena is squeezed between the resident
text (7C1C–B4C9h) and the window, while 0000–5AFFh holds the trap zone
(4K), buffers (2K), the HAL (9.8K) and the old screen (7K). Moving the
**resident text (~14.5K) below 5B00h** — into what the screen and most of
the trap zone use today, once text programs no longer draw (Idea A) — lets
the arena start right after the kernel:

| | arena (one piece) | largest SSX1 (+ window) |
|---|---|---|
| today | ~14 KB | ~13.6 KB |
| resident text low, no screen, trap zone kept to its entry points | **~28–29 KB** | **~32 KB** |
| same, keeping a 7K screen for graphical programs | ~21 KB | ~25 KB |

(Estimates from today's sizes: kernel 7.2K, kernel variables ~1.3K, ITAB
0.75K, window + u-area 4K, HAL 9.8K, buffers 2K, resident text ~14.5K.)

Costs: `const.inc`'s `KBASE`, `KV`, `WINDOW`, `CORE` and the 8 KB `ASSERT`
become platform settings (the Spectrum's keep today's values: gate); the
kernel and kernel variables keep their pinned spots (6003h, 5BE4h) inside
the low block; programs that draw keep needing a screen somewhere (Idea
B makes that "anywhere"). This is a bigger lever than the low pool (Idea
C) and needs no change to arena code: the arena is simply one larger run.

**As built (2026-11-19, branch `portable-hal`).** The kernel stays at
6000h; what moved is the resident text. 0400h–0FFFh holds `vi`, `zxpack`,
`dd`; 4000h–5AFFh (the display file's old place) holds t_file, t_misc,
t_tar, t_proc, t_tap, t_ldx (6,890 of 6,912 bytes). A program that draws
gets its display file from the arena at its claim (`platform/screen-kinds.md`
§5); programs pinned to 4000h are refused at load. Arena free at boot:
**13,724 → 20,614 bytes**; the boot image shrank from 183 to 156 sectors.

## 12. Added 2026-11-19 (later): no screen

The console is a terminal, so programs that draw are refused at load and
the mirror is gone (`screen.asm`): the HAL is 1800h-31EBh (was -3E3Eh),
about 3.3 KB free below 3F00h; no display file is ever taken from the
arena. The rows above that mention the mirror, its FONT or a display
file for SDK programs describe the earlier build.

## 13. Added 2026-11-20: text places, packed by the build

The HAL's 3.3 KB left by the mirror (§12) is a third place for resident
text. Rather than a third hand-made list, the machine layer now declares
its free places and the build fills them:

- `hal.asm` declares `TXn` .. `TXn_LIM` (n from 0) and includes
  `textn.inc` at each: TX0 0400h-0FFFh (above the trap zone, below the
  buffer cache), TX1 `halend`-3EFFh (the rest of the layer's page), TX2
  4000h-5AFFh (the old display file).
- `build.py place()` assembles once with every resident source after the
  kernel and a label before each (`txsizeK`), so it has their sizes and
  the places' room; it packs them, largest first, each into the place
  with the least room it fits (best-fit decreasing); what does not fit
  stays after the kernel (`userland.inc`). (`ulib.asm` stayed there at
  first: it defined the `SC` macro the others use. That macro is now in
  `usys.inc`, assembled before them all, and ulib is packed like the rest.)
- `fddimage.py` takes the places from the symbols (`text0.bin`...); the
  image starts at the lowest one. A machine that declares no `TXn` (the
  Spectrum) gets everything after the kernel, as before.

Result (the build prints it): TX0 holds t_sys (init, getty, login, sh,
glob) and dd, 89 bytes left; TX1 t_file (cat ... ls, df), t_tap (du),
t_zx (zxpack), t_mkfs, 3 bytes left; TX2 t_misc (date ... more), t_proc
(ps, top), t_vi, t_tar (tar, tap), t_fs (mount, umount), 30 bytes left. Only ulib,
ldx and PTAB remain after the kernel (resident text ends at 8425h, was
91E4h). **Arena free at boot: 20,486 → 24,004 bytes**; the boot image
went from 156 to 143 sectors. A source that grows or shrinks is packed
again by the next build: no list to keep by hand.

**Then (2026-11-20): no sequential device, no `tar`.** Tape support is
a capability now, `HAL_SEQDEV` (sequential devices: one record a
transfer, no seeking, programs found by name - the cassette, a
Microdrive), beside `HAL_BLKDEV`; `build.py` chooses programs, sources,
`/dev` and `/mnt` from the platform's settings (`NEEDS`, `HAL_DEVFILES`),
not the target's name. The FDD3000 has none: `tar`/`tap` (1,831 bytes)
and the kernel's cassette redirect and device hold go. Other programs'
cross-jumps into tar's code (shared tails: exit 1, `jp sc_write`...)
now land in code every build has (`/etc/ldx`, `t_misc`, or the target
itself). `ldx` moved low as well: TX1 holds t_file, t_proc, t_mkfs (54
bytes left); TX2 t_misc, t_tap (du), t_vi, t_zx, t_ldx, t_fs (1,656
left). After the kernel: ulib only. **Arena: 24,954 bytes** at boot;
image 139 sectors. (The Spectrum, which keeps its cassette, pays 94
bytes of arena for the general redirect and the loader's one path.)

**Then: ulib packed too.** `SC` moved to `usys.inc` (assembled before every
resident program), so nothing is pinned: TX1 holds ulib and t_file (114
bytes left), TX2 t_misc, t_tap (du), t_proc, t_vi, t_zx, t_ldx, t_mkfs,
t_fs (305 left). After the kernel there is no resident text at all, only
PTAB and the boot code. **Arena: 26,244 bytes** at boot; image 134 sectors.
The Spectrum, with no text places, builds as before.

## 14. A clean-memory platform: the broad view

What a machine like the FDD3000 (64K of RAM, nothing of the Spectrum's
left) can do with its memory inside the framework as it is: the platform
settings (`platform.inc`, the `memmap48.inc` names: `KBASE`, `KV`,
`KSTACK`, `TTYBUF`, `KARGS`, `MEMBOT`, `WINDOW`, `HAL_TOP`; `HAL_KMAX`),
its own layer at its own address (`HAL_LAYER`), its text places (`TXn`),
the seams `mem_swapout`/`mem_swapin`.

**Three kinds of memory.**

1. *Pinned by the program ABI*: `jp sysent` at 6003h (so the kernel
   starts at 6000h), `TTOP` at 5BE4h (so the kernel variables stay round
   5B00h-5FFFh), the window at F000h (`UDATA`; programs are linked to
   run there) and the u-area under `HAL_TOP`. A platform keeps these or
   breaks every SSX1 program.
2. *Fixed size, fixed after boot*: vectors, the layer, the buffer cache,
   the kernel, resident text, PTAB, the i-node table. They can be
   anywhere; resident text is assembled to whatever address the build
   gives it, so it is the natural filler for odd-shaped holes.
3. *Dynamic*: the arena (files, saved processes, SSX1 images, modules).
   It wants **one run, as long as possible, ending at the window**: the
   largest program is that run plus the window's loan, and a run in two
   pieces is two smaller limits (§5 Alternative D).

**The rule that follows**: fixed things fill the space the pinned
addresses leave below 5B00h; the kernel's image (kernel, the text that
did not fit, the boot code, ITAB) is kept as short as possible; the
arena is everything from there to F000h. That is where the FDD3000 now
is: below 5B00h, 0000h-5AFFh is used but for 122 bytes in the places,
the boot sector's page (256 bytes) and the trap zone's filler.

**What is left, by gain and cost:**

| Lever | Gain | Cost |
|---|---|---|
| ~~Drop `tar`/`tap` from the FDD build~~ | done (`HAL_SEQDEV`, above): ldx went low | — |
| ~~`ulib` packable~~ | done (`usys.inc`): the kernel's image ends after the kernel, PTAB and the boot code | — |
| The boot sector moves itself (to the window: free while booting) before loading, so the image may cover 3F00h | +256 B; TX1 and TX2 become one place 31ECh-5AFFh (better packing) | boot.asm: a copy and a jump |
| Trap zone 0068h-03FFh down to the entry points used (RSTs, BEEP, BEEPER) | ~0.9 KB of place | a program calling an unlisted ROM routine runs into text, not a clean stop (§8) |
| Buffer cache 8 → 4 sectors (`NBUF`) | +1 KB of place | slower directory-heavy work |
| Cold parts of the layer as loadable modules (as the float engine and the TOS file system are): measure first | ? | a load on first use |
| Resident programs to disk (Idea E) | anything beyond the above | load time; commands need the system disk |
| One arena over two runs (Idea D) | uses free place below 5B00h as arena | the allocator's core; only once the places have room to spare |

Room in the places was only arena while text after the kernel could move
into it; none is left there now. So the levers above that add room in the
places (the boot sector's page, the trap zone, the buffer cache) no
longer grow the arena by themselves: the next byte of arena comes from
Idea E (programs to disk) or Idea D (an arena over two runs, which would
put the places' spare bytes to use).

**For the next clean machine** (a CP/M-class Z80 with 64K, or the TC3256
on its own): copy `memmap48.inc`'s values (the pinned ones decide the
rest), put the layer and its buffers at the bottom after the vectors,
declare a `TXn` for every hole below 5B00h, set `HAL_TOP` under whatever
the machine keeps at the top. With banked RAM (the 128K, the TC3256's
RAM disk), `mem_swapout`/`mem_swapin` switch a bank instead of copying
the window, and the saved processes leave the arena altogether: that,
not packing, is the next big step in memory.
