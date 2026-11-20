# Floating point: one interface, a binding per platform

For the kernel, the SDK (`sdk/bin/py/libux`) and the platforms, z80-ux
branch `portable-hal`.

## The interface

Programs call the platform's **float engine** directly — no system call
per operation. System call 42 gives its address once:

```
sys 42 (sysfp):  HL = 0  ->  HL = the engine's address; CF: none
                 (an upstream kernel: EINVAL - the runtime uses its own
                 ROM adapter, as the screen code falls back to 40h)

the engine:  A  = the operation   1 add   2 sub   3 mul   4 div   5 pow
                                  6 abs   7 neg   8 trunc 9 exp  10 ln
                                 11 sin  12 cos  13 tan  14 asin 15 acos
                                 16 atan 17 sqrt
                                 18 to integer: BC = |trunc x|,
                                    A = 0 (Z) or FFh (NZ: x < 0)
             HL = x, DE = y (1-5), BC = the result (5 bytes; may be x)
             IX = the caller's workspace, 112 bytes
         ->  CF: no result (too big, outside the domain, / 0)
             keeps IX, IY
```

Numbers are the Spectrum's five-byte format (small integers, and exponent
plus 32-bit mantissa), so compiled constants (`rcc` folds them with the
real ROM), the C48 runtime and existing binaries' data all stay as they
are. The engine keeps no state of its own: the caller lends it the
workspace, so any number of processes use one copy at once, and a process
swapped out mid-operation loses nothing.

Which inputs have no result follows the Spectrum: `x^y` with x < 0
(even `(-8)^0`), `0^y` with y < 0, `ln x` with x ≤ 0, `sqrt` of a
negative, `asin`/`acos` beyond ±1, `/ 0`, overflow (`exp 89`, `tan
(pi/2)`); underflow gives 0. Whole results up to 65,535 come back as small
integers.

## The bindings

| Platform | The engine | Cost |
|---|---|---|
| spectrum48 (and any with the 48 ROM paged in) | `romfpe` in `drivers/rom48/rom48.asm`: the ROM's calculator (`RST 28h`), its pointers moved into the workspace while it runs, interrupts off | 244 bytes of kernel; 0 per program |
| fdd3000 (any machine without the ROM) | `drivers/fp/fp.asm`, a clean-room engine, a module on the system disk (`/mnt/a/lib/fp`, `HAL_FPMOD`), loaded at the first call 42 into a fixed arena block (`K_FPM`), shared, freed when the last process holding it ends or execs (`drivers/fp/fpload.asm`) | 3,314 bytes of arena while a float program runs; 0 otherwise |
| upstream kernel | `@romfp` in the program (`libux/float.asm`) | ~250 bytes per float program |

The kernel's part (`unix.asm`): `sysfp` calls the platform's `fpget`;
`release` and `exec` call `fprel`; `fork` calls `fpfork` (the child holds
the engine if the parent does: it has its address).

## The clean-room engine

`drivers/fp/fp.asm`, written from the format's definition and standard
numerical methods — none of the ROM's code or coefficients:

- **Inside:** sign, 16-bit exponent, 40-bit mantissa (8 guard bits);
  `add`/`sub` aligned and normalised, `mul` 32×32→64 shift-and-add, `div`
  40-bit restoring division; rounding to nearest when packed.
- **Functions** as steps of those (`calc`, a four-byte step list) with
  Taylor series (`mkfpk.py` writes `fpk.inc`):
  - `exp`: `2^n · e^r`, `r = x − n·ln 2` (ln 2 in two parts), 12 terms;
  - `ln`: `x = m·2^e`, m in [0.7, 1.4), `2·atanh((m−1)/(m+1))`, 8 terms;
  - `sin`, `cos`: `x = q·π/2 + r` (π/2 in three parts: exact for q up to
    65,535), the quadrant from q, series in r²;
  - `atan`: `1/x` above 1, then `π/6 + atan((x√3−1)/(x+√3))` above
    tan 15°, then 9 terms; `asin x = atan(x/√((1−x)(1+x)))`, `acos = π/2 −
    asin`; `tan = sin/cos`;
  - `sqrt`: 6 Newton steps from the exponent halved;
  - `pow`: whole y up to 255 by squaring (exact where it can be), else
    `e^(y·ln x)`.
- **Tested** (`test/fp/fptest.py`): every operation on 300 random inputs
  and edge cases, run on the SDK's Z80, against the true value (double
  precision) — and against the ROM (`sdk/bin/py/rcc/romfp.py`) for which
  inputs have no result, which must match:

| | engine, worst | the ROM, worst |
|---|---|---|
| add, sub, mul, div | 0.5 ulp | 0.5–4 ulp |
| sqrt | 0.7 ulp | 83.5 ulp |
| exp, ln | 0.8, 0.5 ulp | 80, 1.2 ulp |
| sin, cos | 1e-9 absolute | 6,844, 152 ulp |
| tan, asin, acos, atan | 2.4 ulp or 1e-9 | 12, 29, 1.2, 0 ulp |
| pow | 40 ulp | 51 ulp |

Speed is about the ROM's: 3–40k T-states for arithmetic, 0.25–0.67M for
the functions.

## Numbers as text: in the program

`libux/fstr.asm` (C48 `ftoa`, `atof`; the BASIC compiler's PRINT, STR$
and VAL next). Library members, linked only into programs that use them:
nothing on the platform. Clean room, with exact integer arithmetic on a
208-bit number, so the engine's rounding never reaches the digits:

- `@fstr`: a number to text as the Spectrum's PRINT writes it: 8
  significant digits, correctly rounded, trailing zeros dropped; `0.5`,
  `.05`, `.00001`, then `1E-6`; up to `99999999`, then `1E+8`. Whole
  numbers in the small-integer form go straight to their digits.
- `@fval`: text to a number: digits, a point, digits, `E`, a sign,
  digits; 9 significant digits read; rounded to nearest; whole numbers
  below 65,536 in the small-integer form.

Tested (`test/fp/strtest.py`) against the exact value and the 48K ROM's
own PRINT-FP (`test/fp/romtext.py`): the same text on every number,
except where the ROM's eighth digit is itself wrong (about 1 in 1,000).
1,468 bytes for both with their working space (`ftoa` alone needs
`@fstr`); 36k T-states for a typical number, under 2k for a whole one up
to 65,535, 180k at worst (`1E+38`).

## Who uses it

`libc48` (`libux/float.asm`): C48, and the Pascal and Fortran compilers,
which link it. `rcc` emits `@fop`, `@ftoi`/`@ftou`, `@itof`/`@utof`,
`@fcmp`, `@ftst`; only `@fop` and the integer conversion reach the engine.
`beep()` still borrows the ROM's BEEP (the FDD3000 rings the terminal's
bell). The BASIC compiler, with `rbc --ux` (`platform/basic.md`): its
runtime's calculator calls (RST 28h) go to libux's clean-room calculator,
which reaches the engine through this call (`@rfcall`).
