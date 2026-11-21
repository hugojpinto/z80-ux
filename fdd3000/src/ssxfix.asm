; =====================================================================
; ZX-UX on the Timex FDD3000: SSX1 programs made safe for the machine.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
; HAL_SSXFIX (platform.inc) calls this after sys ssxload relocates an
; SSX1 program (unix.asm): the FDD3000's port FEh is its drive latch, and
; it has no frame interrupt.
; =====================================================================

; ssxfix: ssxload, the image relocated (KC_IMG, u_tmp2 bytes): what in
; it would stop the FDD3000 is made harmless.
;   OUT (FEh),A -> two NOPs.  Port FEh is the Spectrum's border and
;     beeper, and the FDD3000's drive latch: a C48 border() would page the
;     boot ROM in over the restart vectors (latch bit 6).
;   EI / HALT / LD HL,0 (the end of C48's beep(): "one interrupt frame
;     between notes") -> its HALT a NOP: no frame interrupt ever comes.
; The patterns are matched as bytes; data that happened to hold them
; would be changed too - a small risk against a certain one.
ssxfix: ld hl,(KC_IMG)
        ld bc,(u_tmp2)
.l:     ld a,b
        or c
        ret z
        dec bc
        ld a,(hl)
        inc hl
        cp 0D3h
        jr z,.out
        cp 0FBh
        jr nz,.l
        push hl                 ; EI: then 76 21 00 00?
        push bc
        ld de,ssxhlt
        ld b,4
.h:     ld a,(de)
        cp (hl)
        jr nz,.hn
        inc hl
        inc de
        djnz .h
        pop bc
        pop hl
        ld (hl),0               ; HALT -> NOP
        jr .l
.hn:    pop bc
        pop hl
        jr .l
.out:   ld a,b
        or c
        ret z
        ld a,(hl)
        cp 0FEh
        jr nz,.l
        xor a
        ld (hl),a
        dec hl
        ld (hl),a
        inc hl
        jr .l
ssxhlt: db 76h,21h,0,0
