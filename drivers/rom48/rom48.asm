; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  rom48: what ZX-UX asks of the 48 BASIC ROM, behind the kernel's
;  interfaces (platform/README.md):
;    rom_error        RST 8 from a ROM routine (ERR_SP points here)
;    tapwr, taprd     /dev/tap, /dev/cassette: a block (SA/LD-BYTES)
;    tclk             the tape's time onto the clock
;    kclick           the key click (the ULA's beeper)
;    r48keys          the frame ISR's keyboard: scan, decode, BREAK
;    snd_beep         BEEPER
; =====================================================================

snd_beep equ ROM_BEEPER         ; HL, DE as the ROM's BEEPER.

; rom_error: 21 bytes. The ROM complained. We listen.
rom_error:                      ; RST 8 from a ROM routine.
        ld iy,05C3Ah
        ld a,(tapbusy)
        or a
        jr z,.p
        jp tapend               ; BREAK aborts tape I/O. Rewinding is somebody else's job.
.p:     ld sp,KSTACK
        ld hl,msg_romerr
        jp panic

; ---------------------------------------------------------------------
; ---------------------------------------------------------------------
; tape - one write = one block, one read = one block. A transfer of exactly 17 bytes is a standard Spectrum
; header (flag 00), any other size a data block (flag FF). Tape never offered a fast lane.
; ---------------------------------------------------------------------
; tapwr: 9 bytes. Write one tape block. The motor sets the pace.
tapwr:
        call tapset
        call rom_save_short
        scf
        jr tapend
; rom_save_short: 10 bytes. Use the verified 48K ROM SA-BYTES shortcut at 0C98h, not the 1F80h header pilot.
; The build checks the ROM fingerprint. Wrong ROM, wrong landing.
rom_save_short:
        ld hl,053Fh             ; normal SA-BYTES cleanup return. One extra byte can ruin everyone’s day.
        push hl
        ld hl,0C98h             ; shorter but standard ROM pilot. Tape remains gloriously allergic to
                                ; shortcuts.
        jp 04D0h                ; resumes the unmodified ROM SAVE routine. 1982 called; it wants its
                                ; loading time back.

; taprd: 7 bytes. Read one tape block. No fast-forward button.
taprd:
        call tapset
        scf
        call ROM_LDBYTES
; tapend: 38 bytes. NC = tape failure, including ROM errors and BREAK; restore state and time. The reel is
; picky.
tapend: ld sp,(tapsp)           ; drop the error trap (flags kept). The exit is marked for a reason.
        ld hl,kerrsp
        ld (SV_ERRSP),hl
        di
        ld a,250                ; Give this tape user five quiet seconds. Preemption can wait.
        ld (tapq),a             ; Count down the hold. The next tape block will not wait.
        ld a,(cur)              ; Remember the slot that owns the hold. No passing the baton.
        ld (tapqp),a
        ld a,0
        ld (tapbusy),a
        call c,tclk             ; the time it took onto the clock (CF kept). Even 50 Hz can feel impatient.
        ei
        jp c,ttwrite.xj0_33  
        ld a,EIO
        scf
        ret

; tapset: 41 bytes. IX = buffer, DE = count, A = block flag; prepare the ROM tape call. No fast lane.
tapset: ld a,0FFh
        ld (tapbusy),a
        ld ix,(u_base)
        ld de,(u_count)
        ld a,d
        or a
        ld a,0FFh
        jr nz,.s
        ld a,e
        cp 17
        ld a,0FFh
        jr nz,.s
        xor a
.s:     pop hl                  ; Restore the ROM entry. BREAK still needs a safe way home.
        ld (tapsp),sp           ; Save the caller stack for an orderly tape-error escape.
        ld bc,rom_error         ; Point ROM errors at our trap. Lost returns are expensive.
        push bc                 ; Put that trap on the stack before the ROM wakes interrupts.
        ld (SV_ERRSP),sp        ; ROM RST 8 will use this stack. Leave it actual room.
        jp (hl)                 ; Enter the ROM. The trap is packed and ready.

tapbusy equ MEMBOT+5
tapsp   equ MEMBOT+6

; tclk: 67 bytes. Account for ROM tape pulses while interrupts were off; return CF. The clock missed the show.
tclk:   ei                      ; its own time is counted by the ISR.
        ld ix,100               ; frames: the pilot tone.
        ld bc,(u_count)
        ld a,c
        sub 17                  ; a header is 17 bytes.
        or b
        jr nz,.d
        ld ix,250
.d:     ld hl,(u_base)          ; ... and the bits.
        ld e,0                  ; units into the frame.
.b:     ld a,b
        or c
        jr z,.t
        dec bc
        ld a,(hl)
        inc hl
        scf
        adc a,a                 ; bit 7 into CF, a marker into bit 0.
.i:     ld d,a
        ld a,e
        adc a,1                 ; one unit, two for a 1.
        cp 41
        jr c,.k
        sub 41
        inc ix
.k:     ld e,a
        ld a,d
        add a,a                 ; the next bit; the marker leaves A = 0. The jump does not stop for
                                ; directions.
        jr nz,.i
        jr .b
.t:     di
        call clk1               ; it leaves IX alone.
        ei
        dec ix
        ld a,ixh
        or ixl
        jr nz,.t
        scf
        ret

; kclick: the key click.  (A key arrived: ttrawin.)
kclick:
; key click. The keyboard does not send an apology.
        ld a,(SV_BORDCR)
        rrca
        rrca
        rrca
        and 7
        or 010h
        out (0FEh),a
        ld b,40
.c:     djnz .c
        and 7
        out (0FEh),a
        ret
