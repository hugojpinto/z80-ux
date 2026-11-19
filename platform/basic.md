# BASIC without the ROM: rbc --ux

For the SDK (`sdk/bin/py/rbc`, `sdk/bin/py/libux`) and the kernel, z80-ux
branch `portable-hal`.

`rbc` compiles a 48K Spectrum BASIC program with the HiSoft compiler's
runtime, which calls the 48K ROM for its arithmetic, its screen, its
keys, BEEP and INPUT's line.  `rbc --ux` links the same program with
clean-room routines in place of every one of those (`libux/rbc/*.asm`),
so it runs where there is no ROM - the FDD3000 - as on a Spectrum.  All
100 compiled examples link with no routine of the ROM.

## How

`rbc/ux.py`, after the checked HiSoft source is made:

- each `CALL`/`JP` to the ROM and each `RST n` becomes `@rNNNN` (`@rNN`),
  linked from `libux/librbc.ssa`; the bytes the runtime's own calls carry
  after them (a number, a string) stay bytes (`inline_data`);
- the system variables (5C00h-5CB5h, as `$5Cnn`, `0x5cnn` or decimal) are
  the program's own block, `@rsv` (`sv.asm`), IY = `@rsv+3Ah`; `@rinit`
  sets them up as a Spectrum has them after CLS;
- the display file's page comes from system call 41 (the runtime's ATTR,
  rbc's PEEK and POKE of the screen through `@rattrh`, `@rmap`);
- arithmetic is the platform's float engine (call 42: `platform/
  float.md`) - the results in the forms the ROM gives (the runtime's RND
  reads them so); numbers as text are libux's `@fstr`, `@fval`.

## Two kinds

A program that draws no pixels (no PLOT, DRAW, CIRCLE, POINT, SCREEN$,
ATTR, nor POKE/PEEK of the screen written as a number) is of the
**console** kind (`libux/rbc/con`): PRINT goes to the kernel's console
as its codes (AT, INK, PAPER, BRIGHT, INVERSE, clear), declared 32
columns wide (SSX1 flags bit 4: `platform/screen-kinds.md`) - on a
Spectrum the ROM's 8x8 characters, on a terminal its text.  It claims no
screen, has no display file, and shares the console as any console
program.  The upper screen is the console's rows 0-21, the lower one
its row 22.  FLASH and OVER have no console code; UDGs and block graphics
show as `#`.  The others are of the **bitmap** kind: their own display
file (call 41), PRINT drawn into it as the ROM does - where there is a
screen; a machine whose console is a terminal (the FDD3000) refuses them
at load.  `rbc --ux --bitmap` makes any program bitmap.

## Tested

- `test/basic/romdiff.py`: each routine beside the ROM's own on the
  same random state (registers, the calculator stack, the system
  variables, the screen): character streams on both screens, colours,
  AT and TAB and scrolling, PLOT and DRAW pixel by pixel, SCREEN$,
  INKEY$ on every key and shift, BEEP's tone, INPUT's line, the
  workspace, strings, numbers.  All match (58 groups).
  `ROMDIFF_ENGINE=clean` runs them on the clean-room engine.
- `test/basic/uxsame.py`: both builds of whole programs side by side on
  a Spectrum, the screen compared at every 40th character printed.
- `fdd3000/test/test_basic.py`: console-kind programs on the FDD3000 -
  their text on the terminal, INPUT typed there, the arena whole after.

## Where it differs from the ROM

- VAL reads a number, not an expression (`VAL "2+3"` stops the program).
- CIRCLE draws as many sides as the ROM's, on the true circle (the
  ROM's sits a little off its centre).
- RANDOMIZE with no number seeds from the kernel's clock.
- Numbers as text are correctly rounded (the ROM's eighth digit is
  wrong about once in a thousand).

## What it costs

A program carries the routines it uses: about 2.5-4 KB more than its
ROM build (the ROM did that work for nothing) - the calculator (0.8 KB),
numbers as text (0.9 KB), the screen (bitmap kind 1.5 KB, console kind
0.6 KB), and the rest by use.  The kernel: 22 bytes for the terminal read
without waiting (INKEY$), about 90 for the narrow console.
