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
3. **VT52 on `tty1`** - done: the FDD3000 console's translation of the
   kernel's console codes (AT, INVERSE, clear, new line, TAB, wrapping
   at column 64) moved out of its layer into `drivers/vt52` (`vtputc`;
   its keys, `vtkey`: ^C the BREAK, CR/LF ENTER, BS/DEL DELETE, ESC/^D
   EDIT). It writes to whichever terminal is in use through the
   platform's `ttput` (A, as it is, to terminal C); each terminal's
   position is the driver's own (`vtpos`) - `trow` and `tcol` stay a
   screen console's, whose cursor blinks from the frame interrupt
   whatever terminal is loaded. The
   kernel's `ttout` sends every terminal but the console through it; the
   FDD3000's console is the same driver (`kputc equ vtputc`, its bytes
   over the link). The serial line's time goes on the FDD3000's soft
   clock (`SERCOST`, from the baud rate). The layer's unused shared
   bottom rows (`clbuf`: nothing sets `ttop` on a machine without a
   screen) went with it: 200 bytes back. `test_tty` checks `top` on
   `tty1` (ESC H ESC J, ESC Y, no Spectrum codes on the line) and a long
   line wrapping at its own terminal's column 64 while the console types
   in the middle of it.
4. **Programs that draw, started from `tty1`, are refused** - done with
   step 2 (`drivers/ssxfile/ssx.asm`: a process whose terminal is not the
   console is refused a program that declares no kind or a drawing one).
5. **The serial lines** - done: a machine's `ttput` and its keys to
   `vtkey`:
   - TC3256 (`tc3256/src/rs232.asm`): bit-banged on port FDh (out D0 the
     line, inverted by its driver; D7 our handshake, RTS on CN5's DTR pin;
     in D0 the line, D7 CTS), 1200 baud, every timing derived from the
     Z80's clock and the baud rate. The frame interrupt is never missed
     for it - a bit-banged byte runs with interrupts off, so the line is
     worked around the frame: `ttput` queues (32 bytes); the interrupt,
     first thing, sends up to two (8-N-1) while CTS is up (`RS_TXFR`,
     from the frame's 69,888 T-states less a budget for the rest of the
     interrupt, measured at ~4,600); a full queue waits for the frame,
     or drops with CTS down - no terminal there never hangs the system.
     It listens only when idle (`HAL_IDLE`: `rsidle`), after a frame that
     sent nothing: the line idle with RTS down (an unconnected line
     reads SPACE: no listening), RTS up, the first SPACE a start bit, for
     as long as a byte still ends before the next frame; then RTS down -
     a terminal honouring CTS per character holds its next byte. Typing
     comes in at ~12 characters a second (one a frame, the echo the
     next); output at ~100. 1,168 bytes of arena (17,926 left). Tested
     in Fuse (`tc3256/test/test_tty.py`, `tc3256run.run_serial`: the
     fork's `FUSE_RS232_OUT`, `_IN`, `_TRACE`; a line sent once the
     prompt is out): login, echo, `hello`, ^C, `top` in VT52, and the
     clock against Fuse's frames while `top` keeps the line busy. The
     far end in Fuse was fixed to start a byte no earlier than it is
     in its input file (it began one when RTS last rose, the receiver
     joining it mid-byte).
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
