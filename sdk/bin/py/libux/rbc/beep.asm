; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: BEEP, in place of the 48K ROM's: the duration and the pitch on
; the stack (the pitch on top): semitones from middle C (@cmidc), -@cblo
; to below @cbhi, 0 to @cbmax seconds (libux/build.py's BEEP_ limits);
; else B Integer out of range.  On a
; screen console the tone itself (the speaker's bit of port KPORT, the
; border's colour kept; @chalfp: the delay loop's passes a second, over
; two); behind a terminal its bell, and the time it lasts.
        section text
        global @r03F8

@r03F8: ld hl,@rbp              ; the pitch, the duration
        call .pop
        ld hl,@rbd
        call .pop
        ld hl,@rbd              ; 0 <= duration <= BEEP_MAX
        call .mag
        j nz,.errb
        ld de,@cbmax
        call .le
        j c,.errb
        ld hl,@rbp              ; BEEP_LO <= pitch < BEEP_HI + 1
        call .mag
        ld de,@cblo
        j nz,.neg
        ld de,@cbhi
        call .le
        j c,.errb               ; (not below BEEP_HI + 1)
        j z,.errb
        j .pok
.neg:   call .le
        j c,.errb
.pok:   ld a,(@rterm)
        or a
        j nz,.bell
        ld a,(@rbp)             ; a whole pitch (the small form): its
        or a                    ; semitone's frequency and half cycle from
        j z,.whole              ; the tables, the octave on their exponents
        ld hl,@rbp              ; f = middle C * e^(pitch * ln 2 / 12)
        ld de,@csemi
        ld bc,@rbt
        ld a,F_MUL
        call @rfcall
        ld hl,@rbt
        ld b,h
        ld c,l
        ld a,F_EXP
        call @rfcall
        ld hl,@rbt
        ld de,@cmidc
        ld b,h
        ld c,l
        ld a,F_MUL
        call @rfcall
        ld hl,@rbt              ; the cycles: f * duration
        ld de,@rbd
        ld bc,@rbn
        ld a,F_MUL
        call @rfcall
        ld hl,@rbn
        call .int
        ld (@rbcyc),bc
        ld a,b
        or c
        ret z
        ld hl,@chalfp           ; a half cycle: the loop's passes
        ld de,@rbt
        ld bc,@rbt
        ld a,F_DIV
        call @rfcall
.tone:  ld hl,@rbt
        call .int
        ld a,b
        or c
        j z,.errb
        ld (@rbhalf),bc
        ld a,(BORDCR)           ; the port's byte: the border, MIC
        rrca
        rrca
        rrca
        and A_BORD
        or MIC
        ld e,a
        ld bc,(@rbcyc)
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
        ret
; .whole: the pitch a whole number: octave k, semitone r (pitch = 12k + r)
.whole: ld hl,(@rbp+2)          ; the pitch: -60 .. 69
        ld b,0                  ; k: from the octave below, up
        ld de,SEMITONES
        ld a,h
        or a
        j z,.wk
.wn:    add hl,de               ; negative: up an octave at a time
        dec b
        bit 7,h
        j nz,.wn
.wk:    ld a,l                  ; r = what is left, k up while it is 12+
        cp SEMITONES
        j c,.wr
        sub SEMITONES
        ld l,a
        inc b
        j .wk
.wr:    ld a,b
        ld (@rbo),a
        ld a,l                  ; FNUM * r: the semitone's entries
        add a,a
        add a,a
        add a,l
        ld e,a
        ld d,0
        ld hl,@cbfreq
        add hl,de
        push de
        ld de,@rbt              ; f, its octave
        ld bc,FNUM
        ldir
        ld a,(@rbo)
        ld hl,@rbt
        add a,(hl)
        ld (hl),a
        ld hl,@rbt              ; the cycles: f * duration
        ld de,@rbd
        ld bc,@rbn
        ld a,F_MUL
        call @rfcall
        ld hl,@rbn
        call .int
        ld (@rbcyc),bc
        pop de
        ld a,b
        or c
        ret z
        ld hl,@cbhalf           ; the half cycle, its octave
        add hl,de
        ld de,@rbt
        ld bc,FNUM
        ldir
        ld a,(@rbo)
        neg
        ld hl,@rbt
        add a,(hl)
        ld (hl),a
        j .tone
.half:  ld hl,(@rbhalf)
.dl:    dec hl                  ; (LOOP_T T-states a pass)
        ld a,h
        or l
        jr nz,.dl
        ret
; .mag: @rbk = the number at HL's magnitude in the full form -> NZ: it was
; negative
.mag:   ld de,@rbk
        ld bc,FNUM
        ldir
        ld hl,@rbk
        call @r3297             ; (RE-STACK: the full form)
        ld a,(@rbk+1)
        ld b,a
        and ~N_SIGN & 0FFh
        ld (@rbk+1),a
        ld a,(@rbk)             ; (0: not negative)
        or a
        ret z
        ld a,b
        and N_SIGN
        ret
; .le: @rbk against the full-form constant at DE: CF if above it, Z if
; equal (the bytes in order: the exponent, then the mantissa)
.le:    ld hl,@rbk
        ld b,FNUM
.lc:    ld a,(de)
        cp (hl)
        ret nz
        inc hl
        inc de
        djnz .lc
        ret
; a terminal: its bell, then the duration slept
.bell:  ld hl,1
        ld de,@cbell
        ld bc,1
        ld a,SYS_WRITE
        call SYS
        ld hl,@rbd
        ld de,@cticks
        ld bc,@rbt
        ld a,F_MUL
        call @rfcall
        ld hl,@rbt
        call .int
        ld h,b
        ld l,c
        ld a,h
        or l
        ret z
        ld a,SYS_SLEEP
        jp SYS
.errb:  ld a,R_RANGE
        jp @rerr
; .int: BC = the number at HL rounded (0 - 65535); else B Integer out of range
.int:   call @r33B4
        call @r2DA2
        j c,.errb
        ret z
        j .errb
.pop:   push hl
        call @r35BF
        ld (STKEND),hl
        pop de
        ld bc,FNUM
        ldir
        ret

@cbell: db C_BELL

        section bss
@rbp:   ds FNUM
@rbd:   ds FNUM
@rbt:   ds FNUM
@rbn:   ds FNUM
@rbk:   ds FNUM
@rbcyc: ds 2
@rbhalf: ds 2
@rbo:   ds 1
