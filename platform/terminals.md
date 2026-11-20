# More than one terminal: RS-232 on the TC3256 and the FDD3000

Design agreed 2026-11-20; being built in this order:

1. **`NPROC` configurable** - done: a platform setting (4 if unset, at most
   8), the process table laid out from it (`kvars.inc`): at 5B00h for four
   (the Spectrum, unchanged), in the layer's own page-aligned block
   (`HAL_PTAB`, `proctab`) for more; the scheduler steps round any count;
   the status line's cells narrow to fit (`screen64`: `STCELL`); `ps` and
   `top` read the table by its size. The FDD3000 and the TC3256 run six.
2. **Several terminals in the kernel**: the tty line discipline (`dev.asm`:
   ring, mode, BREAK) per terminal (`HAL_NTTY`), a controlling terminal per
   process - BREAK on one signals only its processes; system call 41
   describes the process's own terminal; `/dev/tty1`. `init` starts a
   `getty` on each terminal. Proved first on the FDD3000 against a WD2123
   model in `fdd3000/test/fddrun.py`.
3. **VT52 on `tty1`**: the FDD3000's console-code-to-VT52 translation
   moved out of its layer into a shared driver.
4. **Programs that draw, started from `tty1`, are refused** (the screen
   refusal per terminal, not per machine).
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
