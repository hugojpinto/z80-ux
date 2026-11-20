; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; zx-ux (libux, rcc --no-rom): what rom48k.asm does with the 48K ROM,
; without it.  The float engine is the platform's or none: a kernel with
; no call 42 ends the program ("no float engine").  beep() is clean room,
; as BASIC's BEEP (libux/rbc/beep.asm): on a screen, the tone on the
; speaker's bit of the keyboard port, its half cycle in delay-loop passes
; (@chalfp, libux/build.py) over the pitch's frequency (middle C, @cmidc,
; times 2 ^ (pitch / 12): e ^ (pitch * @csemi)); behind a terminal
; (system call 41: E = 1), its bell and the duration slept.  The numbers
; come from libux/build.py's consts (linked with this archive).
SYS     equ 6003h
SYS_WRITE equ 4
SYS_SLEEP equ 34
SYS_DISP equ 41
SYS_FP  equ 42
KPORT   equ 0FEh                ; the keyboard port: the speaker, the MIC, the border
SPK     equ 10h
MIC     equ 08h
A_BORD  equ 07h
BORDCR  equ 5C48h               ; the border's colour, as console.asm keeps it
C_BELL  equ 07h
F_MUL   equ 3                   ; @fop's operations (C48 order: float.asm)
F_DIV   equ 4
F_EXP   equ 9
        section text
        global @fpget,_beep

; @fpget: system call 42 -> HL = the engine.  Keeps BC, DE.  None: the
; program ends, saying so.
@fpget: push bc
        push de
        ld hl,0
        ld a,SYS_FP
        call SYS
        j c,.none
        ld (@fpe),hl
        pop de
        pop bc
        ret
.none:  ld hl,2
        ld de,.msg
        ld bc,.end-.msg
        ld a,SYS_WRITE
        call SYS
        j @ferr
.msg:   db "no float engine",10
.end:

; _beep: beep(duration, pitch): seconds 0 .. @cbmax, semitones from middle
; C @cblo .. @cbhi (as the ROM's BEEP) -> 0; else 1, nothing played.
_beep:  ex de,hl                ; DE = the pitch
        pop bc
        pop hl                  ; HL = the duration (the callee takes it off)
        push bc
        push de
        ld de,@bd
        call @fmov
        pop hl
        ld de,@bp
        call @fmov
        ld hl,@bd               ; 0 <= duration <= max
        call .neg
        j c,.bad
        ld hl,@cbmax
        ld de,@bd
        call @fcmp              ; max < duration?
        j c,.bad
        ld hl,@bp               ; lo <= pitch < hi
        ld de,@cbhi
        call @fcmp
        j nc,.bad
        ld hl,@cblo
        ld de,@bt
        call @fmov
        ld hl,@bt+1             ; -lo (the full form: the sign, the mantissa's top bit)
        ld a,(hl)
        xor 80h
        ld (hl),a
        ld hl,@bp
        ld de,@bt
        call @fcmp              ; pitch < -lo?
        j c,.bad
        ld hl,@bp               ; f = middle C * e ^ (pitch * ln 2 / 12)
        ld de,@csemi
        ld a,F_MUL
        call @fop
        ld a,F_EXP
        ld hl,@bp
        ld de,@bp
        call @fop
        ld hl,@bp
        ld de,@cmidc
        ld a,F_MUL
        call @fop
        call @term
        j z,.bell
        ld hl,@chalfp           ; the half cycle: passes a second / 2 / f
        ld de,@bt
        call @fmov
        ld hl,@bt
        ld de,@bp
        ld a,F_DIV
        call @fop
        ld hl,@bt
        call @fbc               ; BC: the integer part; CF: too big
        j c,.bad
        ld a,b
        or c
        j z,.bad
        ld (@bh),bc
        ld hl,@bd               ; the cycles: f * duration
        ld de,@bp
        ld a,F_MUL
        call @fop
        ld hl,@bd
        call @fbc
        j c,.bad
        ld a,b
        or c
        j z,.ok
        ld a,(BORDCR)           ; the port's byte: the border, MIC
        rrca
        rrca
        rrca
        and A_BORD
        or MIC
        ld e,a
        di
.cyc:   push bc
        ld a,e
        xor SPK
        out (KPORT),a
        call .half
        ld a,e
        out (KPORT),a
        call .half
        pop bc
        dec bc
        ld a,b
        or c
        j nz,.cyc
        ei
.ok:    ld hl,0
        ret
.bad:   ld hl,1
        ret
.half:  ld hl,(@bh)
.dl:    dec hl                  ; (LOOP_T T-states a pass: libux/build.py)
        ld a,h
        or l
        jr nz,.dl
        ret
; .neg: CF if the float at HL is negative (and not zero)
.neg:   ld a,(hl)
        or a
        inc hl
        j nz,.nb
        ld a,(hl)               ; small integer: its sign byte
        rla
        ret
.nb:    ld a,(hl)               ; full form: the mantissa's top bit
        rla
        ret
; a terminal: its bell, then the duration slept (in ticks)
.bell:  ld hl,1
        ld de,@bell
        ld bc,1
        ld a,SYS_WRITE
        call SYS
        ld hl,@bd
        ld de,@cticks
        ld a,F_MUL
        call @fop
        ld hl,@bd
        call @fbc
        j c,.ok
        ld h,b
        ld l,c
        ld a,h
        or l
        j z,.ok
        ld a,SYS_SLEEP
        call SYS
        j .ok

; @term: Z behind a terminal (system call 41: E = 1); asked once.
@term:  ld a,(@bterm)
        or a
        j nz,.k
        ld hl,0
        ld a,SYS_DISP
        call SYS
        ld a,1                  ; no call 41: a Spectrum's screen
        j c,.s
        add a,e
.s:     ld (@bterm),a
.k:     cp 2
        ret
@bell:  db C_BELL

        section bss
@bd:    ds 5                    ; the duration
@bp:    ds 5                    ; the pitch, then its frequency
@bt:    ds 5
@bh:    ds 2                    ; the half cycle, in delay-loop passes
@bterm: ds 1                    ; 0: not asked; 1: a screen; 2: a terminal
