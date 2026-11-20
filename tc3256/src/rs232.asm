; =====================================================================
; ZX-UX on the Timex TC3256: the second terminal, on the RS-232 port.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; TC3256 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; /dev/tty1 (terminal 1, platform/terminals.md): CN5, the MMU's port FDh
; - a bare latch, no UART (TC3256 SIM/DOCS/tc3256_serial_port.md §4):
;   out D0: the line, inverted by its driver (1 SPACE, 0 MARK: idle);
;   out D7: our handshake (RTS, on CN5's DTR pin): "you may send";
;   in  D0: the line, inverted again (1 while SPACE); D7: CTS.
; Every bit is the Z80's, timed in T-states, with interrupts off - and a
; frame interrupt missed is a tick lost.  So the line is worked around
; the frame:
;  - sending: ttput queues a byte (rsq); the frame interrupt, first
;    thing, sends up to RS_TXFR of them, 8-N-1, while CTS is up - the
;    rest of its work still done before the next frame.  A full queue
;    waits for the frame; with CTS down (no terminal there) it drops.
;  - receiving: only when nothing runs (HAL_IDLE: rsidle), after a frame
;    in which nothing was sent, the line idle (MARK) with RTS down - an
;    unconnected line reads SPACE: RTS up, the first SPACE a start bit
;    (a terminal may begin as RTS rises), watched for as long as
;    a byte would still end before the next frame; then RTS down, which
;    a terminal honouring CTS takes as "hold" - its next byte waits for
;    the next idle frame.  A byte with a SPACE stop bit is dropped.
; At 1200 baud: two bytes out a frame, one in.  The keys go through
; drivers/vt52's vtkey, as the FDD3000's.
; =====================================================================

RS_PORT  equ 0FDh
RS_SPACE equ 01h                ; out D0: the line SPACE (the driver inverts)
RS_RTS   equ 80h                ; out D7: we may receive
RS_CTS   equ 80h                ; in D7: the far end may take a byte
                                ; (in D0: 1 while the line is SPACE)
RS_BAUD  equ 1200
TC_HZ    equ 3500000            ; the Z80's clock
TC_FRAME equ 224*312            ; T-states a frame (the SCLD: 312 lines of 224)
RS_BIT   equ TC_HZ/RS_BAUD      ; a bit, in T-states
RS_DLYT  equ 16                 ; rsdly: T-states a pass ...
RS_DLY0  equ 29                 ; ... and its call, set-up and return
RS_LOOPT equ 43                 ; rssend's own T-states a bit
RS_DJ    equ (RS_BIT-RS_LOOPT-RS_DLY0+RS_DLYT/2)/RS_DLYT  ; rsdly's passes a bit
        ASSERT RS_DJ > 1 && RS_DJ < 256
RS_TXBITS equ 10                ; 8-N-1: start, 8 data, stop
RS_BYTE  equ RS_BIT*RS_TXBITS
RS_ISRT  equ 10000              ; the rest of the frame interrupt (keys,
                                ; console, kernel), at most: a budget
RS_TXFR  equ (TC_FRAME-RS_ISRT)/RS_BYTE  ; bytes the interrupt sends a frame
        ASSERT RS_TXFR >= 1
RS_RXT   equ RS_BIT*10+2000     ; a byte in, from its start bit to the
                                ; kernel's ring (the stop bit sampled at 9.5)
RS_POLLT equ 48                 ; rsidle's watch: T-states a poll
RS_WIN   equ (TC_FRAME-RS_ISRT-RS_RXT)/RS_POLLT  ; polls a frame
        ASSERT RS_WIN > 0
RS_GRACE equ RS_BIT*3/2/35      ; after RTS falls: polls (35 T) for a byte
                                ; the far end began just then
        ASSERT RS_GRACE < 256
RS_TXQ   equ 32                 ; the send queue (a power of 2)

; rsinit: the boot (HAL_START): the line idle (MARK), RTS down.
rsinit: xor a
        out (RS_PORT),a
        ret

; ttput: A to terminal C (1: this port), queued.  Keeps BC, DE, HL.
ttput:  push bc
        push de
        push hl
        ld e,a
.w:     ld a,(rshd)
        inc a
        and RS_TXQ-1
        ld hl,rstl
        cp (hl)
        jr nz,.put
        in a,(RS_PORT)          ; full: a terminal there?
        and RS_CTS
        jr z,.x                 ; no: dropped
        ld a,i                  ; P/V: interrupts on
        jp po,.now
        halt                    ; the frame sends some
        jr .w
.now:   call rsnext             ; (interrupts off: the oldest now)
        jr .w
.put:   ld hl,rsq
        ld a,(rshd)
        ld b,a
        call addhla
        ld (hl),e
        ld a,b
        inc a
        and RS_TXQ-1
        ld (rshd),a             ; (the byte first, then the head)
.x:     pop hl
        pop de
        pop bc
        ret

; rstx: the frame interrupt's part, first thing: up to RS_TXFR bytes
; out.  rssent: how many.  Uses A, BC, D, HL.
rstx:   xor a
        ld (rssent),a
        ld b,RS_TXFR
.l:     push bc
        call rsnext
        pop bc
        ret c
        ld hl,rssent
        inc (hl)
        djnz .l
        ret

; rsnext: the oldest queued byte out -> CF: none, or CTS down (held).
; Uses A, BC, D, HL.
rsnext: ld a,(rstl)
        ld hl,rshd
        cp (hl)
        scf
        ret z
        in a,(RS_PORT)
        and RS_CTS
        scf
        ret z
        ld a,(rstl)
        ld hl,rsq
        call addhla
        ld c,(hl)
        ld a,(rstl)
        inc a
        and RS_TXQ-1
        ld (rstl),a
        ld a,c
; rssend: A out, 8-N-1, interrupts off (the caller's).  Uses A, BC, D.
rssend: cpl                     ; a 1 is MARK: D0 0
        ld c,a
        ld a,RS_SPACE           ; the start bit (RTS down)
        out (RS_PORT),a
        call rsdly
        ld b,8
.b:     ld a,c                  ; (RS_LOOPT: these and the DJNZ)
        and RS_SPACE
        out (RS_PORT),a
        rrc c
        call rsdly
        djnz .b
        xor a                   ; the stop bit: MARK
        out (RS_PORT),a
        call rsdly
        or a
        ret

; rsdly: a bit's time, less the loop's around it.  Uses D.
rsdly:  ld d,RS_DJ
rsdlyd: dec d
        jr nz,rsdlyd
        ret

; rsidle: HAL_IDLE - wait for the frame; then, if the interrupt sent
; nothing (the frame mostly left), listen.  A byte -> terminal 1's ring
; (vtkey).  Returns with interrupts off when it listened.
rsidle: halt
        ld a,(rssent)
        or a
        ret nz
        di
        in a,(RS_PORT)          ; the line idle (MARK) while RTS is down?
        rra                     ; (SPACE: nothing there, or a break)
        ret c
        ld a,RS_RTS             ; RTS up, the line MARK: send
        out (RS_PORT),a
        ld bc,RS_WIN
.w:     in a,(RS_PORT)          ; (RS_POLLT: a pass)
        rra
        jr c,.start             ; SPACE after MARK: a start bit
        dec bc
        ld a,b
        or c
        jr nz,.w
.shut:  xor a
        out (RS_PORT),a         ; RTS down: hold
        ld b,RS_GRACE
.g:     in a,(RS_PORT)
        rra
        jr c,.start
        djnz .g
        ret
.start: ld d,RS_DJ/2            ; to the start bit's middle ...
        call rsdlyd
        ld b,8
.r:     call rsdly              ; ... and each data bit's
        in a,(RS_PORT)
        rra
        rr c
        djnz .r
        call rsdly              ; the stop bit's
        in a,(RS_PORT)
        ld b,a
        xor a
        out (RS_PORT),a         ; RTS down: the next one waits
        rr b
        ret c                   ; a SPACE stop bit: dropped
        ld a,c
        cpl                     ; (read inverted)
        ld e,1                  ; terminal 1's
        jp vtkey

rshd:   db 0                    ; the send queue: its head (ttput's) ...
rstl:   db 0                    ; ... its tail (the interrupt's)
rssent: db 0                    ; bytes the last frame sent
rsq:    ds RS_TXQ
