# More than one terminal: RS-232 on the TC3256 and the FDD3000

Design agreed 2026-11-20; being built in this order:

1. **`NPROC` configurable** - done: a platform setting (4 if unset, at most
   8), the process table laid out from it (`kvars.inc`): at 5B00h for four
   (the Spectrum, unchanged), in the layer's own page-aligned block
   (`HAL_PTAB`, `proctab`) for more; the scheduler steps round any count;
   the status line's cells narrow to fit (`screen64`: `STCELL`); `ps` and
   `top` read the table by its size. The FDD3000 and the TC3256 run six.
2. **Several terminals in the kernel** - done: `HAL_NTTY` terminals (1 if
   unset, at most 8; the console is 0), each its own key ring
   (`ttyhd`/`ttytl`/`ttyring`) and line state - mode, AT state, the line
   being typed - which `ttsel` swaps into the kernel's variables for the
   terminal in use (`ttyc`). A process has a controlling terminal
   (`p_tty`: inherited at fork, set by opening `/dev/ttyN`) and the one
   it reads (`p_ttr`); `/dev/tty` is a process's own terminal,
   `/dev/tty1` (`DEV_TTY1`) and up the others. BREAK on a terminal
   (`ttintn`) signals only its processes. Output goes through `ttout`:
   the console's `kputc`, or the platform's `ttput` (A, C = the
   terminal); keys come in through `ttrawn` (A, E = the terminal). System
   call 41 (`ttdisp`) tells a process on a terminal it has no display
   file: 80 x 24 (32 columns for a narrow console). `init` starts and
   restarts a `getty` on each terminal. One terminal costs 18 bytes over
   the old kernel; the second, on the FDD3000, ~1 KB with its UART
   driver. Tested on the FDD3000 against a WD2123 model in
   `fdd3000/test/fddrun.py` (`fdd3000/test/test_tty.py`: a login on each
   terminal, echo, BREAK on one leaving the other's processes, a drawing
   program refused on `tty1`).
3. **VT52 on `tty1`**: the FDD3000's console-code-to-VT52 translation
   moved out of its layer into a shared driver.
4. **Programs that draw, started from `tty1`, are refused** - done with
   step 2 (`drivers/ssxfile/ssx.asm`: a process whose terminal is not the
   console is refused a program that declares no kind or a drawing one).
5. **The serial lines**, a machine's `serput` / `serpoll` / `serlisten`:
   - TC3256: bit-banged on port FDh (D0 TX/RX, D7 the handshake out / CTS
     in), 1200 baud; it listens only when idle - the handshake raised, a
     start bit awaited, the byte read with interrupts off - so a terminal
     honouring CTS per character holds its bytes while programs run.
     Tested in Fuse: `FUSE_RS232_OUT`, `FUSE_RS232_IN`, `FUSE_RS232_BAUD`
     (the fork's `peripherals/tc3256_rs232.c`).
   - FDD3000: the WD2123 dual UART, polled where the console link is
     (`kpoll`, `kidle`), 9600 baud, RTS/CTS. Its ports, as TOS - which ran
     on the machine - uses them (its channel descriptors, TOS image 251Dh:
     `80 81 81 10 4E 08 00 40 41 41 11 4E 0A 00`, read by its send,
     receive, close and rate code through `out (c)` / `in a,(c)`):
     channel A data 80h, control/status 81h, rate generator 10h; channel B
     40h, 41h, 11h. The FDD3000 decodes ports by A7-A5 (32-port groups):
     the service manual's 18h rate generator agrees (10h's group); its 30h
     for channel A is the link's group (2Fh), a slip; Fuse's notes (A at
     40h) are wrong for A, and it does not emulate the UART. `tty1` takes
     channel A, leaving B (a printer).
