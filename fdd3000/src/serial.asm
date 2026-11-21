; =====================================================================
; ZX-UX on the Timex FDD3000: the second terminal, on the WD2123.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; /dev/tty1 (terminal 1, platform/terminals.md): channel A of the WD2123
; dual UART, an 8251 as TOS drives it (its channel descriptors, TOS image
; 251Dh: data 80h, control and status 81h, rate generator 10h; channel B,
; 40h/41h/11h, is left for a printer).  Set up as TOS sets a channel up:
; a dummy control write, an internal reset, the mode byte, a command,
; the rate.  Polled where the console's link is (kpoll, kidle, hzpoll):
; nothing interrupts on the FDD3000 but the floppy controller.  RTS is
; kept up; a byte not read before the next arrives is lost (overrun:
; the error cleared and the byte dropped) - fine for typing, not for a
; paste at full speed.
; No terminal on the line (its CTS off: the UART never ready to send) must
; not hold the system up - nothing else runs while a byte waits: a byte
; waits SER_HOLD at most, then the line is down (serup) and bytes go
; unsent at once - one look each - until the UART is ready again.  No
; UART at all (the ports an empty bus, FFh): the channel is left alone
; (serhw).
; =====================================================================

SER_DATA equ 80h                ; channel A
SER_CTL  equ 81h
SER_RGEN equ 10h                ; its rate generator
SER_MODE equ 4Eh                ; 8 bits, no parity, 1 stop bit, x16 clock
SER_RATE equ 0Eh                ; 9600 baud: the WD1943 ladder's code (TOS page 3)
SER_BAUD equ 9600               ; ... the speed it is
SERCOST  equ FDDHZ*10/SER_BAUD/16 ; a byte's time on the line (10 bits), in
                                ; the soft clock's units (hal.asm)
SER_IRES equ 47h                ; an internal reset (the mode byte next)
SER_ON   equ 37h                ; transmit, receive, DTR, RTS on; errors cleared
SER_TXRDY equ 01h               ; status: a byte may be sent ...
SER_RXRDY equ 02h               ; ... one has come
SER_ERR  equ 38h                ; ... parity, overrun, framing
SER_POLLT equ 51                ; serout's wait: T-states a status poll
SER_HOLD equ FDDHZ/10/SER_POLLT ; ... polls a byte waits at most (0.1 s)
SER_NONE equ 0FFh               ; status of an empty bus: no UART
                                ; (no terminal there: 256 x 256)

; serinit: the boot (HAL_START): the channel set up.
serinit: xor a
        out (SER_CTL),a         ; (wakes the chip: TOS does the same)
        ld a,SER_IRES
        out (SER_CTL),a
        ld a,SER_MODE
        out (SER_CTL),a
        ld a,SER_ON
        out (SER_CTL),a
        ld a,SER_RATE
        out (SER_RGEN),a
        in a,(SER_DATA)         ; a stale byte
        in a,(SER_CTL)
        cp SER_NONE
        ret z                   ; no UART: serhw, serup stay 0
        ld a,1
        ld (serhw),a
        ld (serup),a
        ret

; serpoll: a byte from the terminal, if one has come: to terminal 1's
; ring (vtkey: mapped as the console's, ^C its BREAK); kgot set, so that
; kidle returns.  Uses A, BC, DE, HL.
serpoll: ld a,(serhw)
        or a
        ret z
        in a,(SER_CTL)
        bit 1,a                 ; SER_RXRDY
        ret z
        and SER_ERR
        jr z,.ok
        ld a,SER_ON             ; an error: cleared, the byte dropped
        out (SER_CTL),a
        in a,(SER_DATA)
        ret
.ok:    in a,(SER_DATA)
        ld hl,kgot
        ld (hl),h
        ld e,1
        jp vtkey

; serout: A to the terminal (hal.asm's ttput, vt52.asm's bytes); waits
; while the UART cannot take a byte (the terminal's CTS), SER_HOLD at
; most - then the line is down, and while it is a byte is sent only if the
; UART is ready at once.  The byte's time goes on the clock.  Keeps BC,
; DE, HL.
serout: push bc
        push af
        ld bc,SER_HOLD          ; the line up: wait for it
        ld a,(serup)
        or a
        jr nz,.w
        ld bc,1                 ; down: one look
.w:     in a,(SER_CTL)          ; (SER_POLLT: a pass)
        and SER_TXRDY
        jr nz,.go
        dec bc
        ld a,b
        or c
        jr nz,.w
        ld (serup),a            ; (A = 0) nobody takes it: the line down,
        pop af                  ; the byte dropped
        pop bc
        ret
.go:    ld a,(serhw)            ; ready: the line up (if there is a UART)
        ld (serup),a
        pop af
        out (SER_DATA),a
        pop bc
        push de
        push hl
        ld hl,SERCOST
        call htime
        pop hl
        pop de
        ret

serhw:  db 0                    ; a UART answers (serinit)
serup:  db 0                    ; ... and the line takes bytes (serout)
