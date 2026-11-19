; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: the line INPUT types, shown in the lower screen, in place of
; the 48K ROM's ED-COPY, CLEAR-SP and the end of INPUT (20A0h).  The line:
; from WORKSP to its ENTER (E_LINE when not INPUT: FLAGX), K_CUR in it.
; ED-COPY prints it from the lower screen's position (S_POSNL), the cursor
; (a flashing L, or C, E, G) at K_CUR, spaces to where the last copy ended
; (ECHO_E), which becomes its end; S_POSNL back at its start.  Clean room:
; checked against the ROM's (test/basic/romdiff.py).
        section text
        global @r111D,@r1097,@r20A0

; @rline: DE = the line's first character.
@rline: ld de,(ELINE)
        ld a,(FLAGX)
        bit FX_IN,a
        ret z
        ld de,(WORKSP)
        ret

; ED-COPY
@r111D: call @r0D4D
        ld hl,TVFLAG
        res TVF_MOD,(hl)
        res TVF_ED,(hl)
        ld hl,(SPOSNL)
        ld (@restart),hl
        ld hl,(ECHOE)           ; the last copy's end (printing moves ECHO_E)
        ld (@reold),hl
        ld a,(@rwait)           ; a code's operands still to come: not
        ld (@rewait),a          ; these characters (the ROM prints them
        xor a                   ; past the channel), but the next ones
        ld (@rwait),a
        call @rline
        ex de,hl
.l:     ld de,(KCUR)
        or a
        sbc hl,de
        add hl,de
        call z,.cur
        ld a,(hl)
        cp C_CR
        j z,.end
        push hl
        call @rpo
        pop hl
        inc hl
        j .l
.end:   ld de,(@reold)          ; spaces to the old end (D its line, E column)
.bl:    ld hl,(SPOSNL)
        ld a,h                  ; (counters: higher further up, further left)
        sub d
        j c,.done
        j nz,.sp
        ld a,e
        sub l
        j nc,.done
.sp:    push de
        ld a,' '
        call @rpo
        pop de
        j .bl
.done:  ld a,(@rewait)
        ld (@rwait),a
        ld hl,(SPOSNL)          ; ECHO_E: the new end; S_POSNL: the start
        push hl
        ld bc,(@restart)
        call @rcset
        ld (SPOSNL),bc
        ld (DFCCL),hl
        pop hl
        ld (ECHOE),hl
        ret
; .cur: the cursor, flashing
.cur:   push hl
        ld hl,(ATTRT)
        push hl
        ld a,(ATTRT)
        or A_FLASH
        ld (ATTRT),a
        ld a,(MASKT)
        and ~A_FLASH & 0FFh
        ld (MASKT),a
        ld a,(MODE)
        ld c,CUR_E
        dec a
        j z,.ch
        ld c,CUR_G
        dec a
        j z,.ch
        ld c,CUR_L
        ld a,(FLAGS2)
        bit FL2_CAPS,a
        j z,.ch
        ld c,CUR_C
.ch:    ld a,c
        call @rpo
        pop hl
        ld (ATTRT),hl
        pop hl
        ret

; CLEAR-SP: the line emptied (its ENTER kept), K_CUR at its start, mode L.
@r1097: push hl
        call @rline             ; DE = the start
        ld hl,(STKBOT)          ; INPUT: its ENTER at STKBOT - 1
        ld a,(FLAGX)
        bit FX_IN,a
        j nz,.in
        ld hl,(WORKSP)          ; (else at WORKSP - 2)
        dec hl
.in:    dec hl
        or a
        sbc hl,de               ; the characters
        ld b,h
        ld c,l
        ex de,hl
        ld a,b
        or c
        call nz,@r19E8
        ld (KCUR),hl
        xor a
        ld (MODE),a
        pop hl
        ret

; The end of INPUT: the upper screen's position above the lower screen,
; SCR_CT for the lines left, the upper screen's again, CLS-LOWER.
@r20A0: ld bc,(SPOSN)
        ld a,(DFSZ)
        cp b
        j c,.ok
        ld c,CCOL
        ld b,a
.ok:    ld (SPOSN),bc
        ld a,CLINE+1
        sub b
        ld (SCRCT),a
        ld hl,TVFLAG
        res TVF_LOW,(hl)
        call @r0DD9
        j @r0D6E

        section bss
@restart: ds 2
@reold: ds 2
@rewait: ds 1
