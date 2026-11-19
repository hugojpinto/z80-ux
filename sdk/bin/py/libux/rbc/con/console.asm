; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux, the console kind: a BASIC program with no pixels (no PLOT,
; DRAW, CIRCLE, POINT, SCREEN$, ATTR) prints through the kernel's console,
; 32 columns wide (SSX1 flags bit 4: platform/screen-kinds.md) - a
; Spectrum's screen in the ROM's 8x8 characters, a terminal's text.
;
; PRINT's positions, AT, TAB, comma, scrolling and colours are kept in
; the system variables as for the bitmap kind (libux/rbc/print.asm's
; CHAN-OPEN, TEMPS, CO-TEMP-5 serve both); what is printed goes to the
; console as its codes (16h AT, 10h INK, 11h PAPER, 13h BRIGHT, 14h
; INVERSE, 0Ch clear, 0Ah newline) through write(1).  The upper screen
; is the console's rows 0 .. CON_UP, the lower screen its row CON_LOW.
; FLASH and OVER have no console code; UDGs and block graphics show as
; C_STAND.  Linked before libux/rbc's own (librbccon.ssa).
        section text
        global @rpo,@r0D6B,@r0D6E,@r0DD9,@rinit,@r111D,@rcexit

; @rpo: A on the screen (upper or lower: TV_FLAG bit 0).
@rpo:   ld e,a
        ld a,(@rwait)
        or a
        j nz,.parm
        ld a,e
        cp ' '
        j nc,.able
        cp C_COMMA
        j z,.comma
        cp C_BACK
        j z,.back
        cp C_ENTER
        j z,.enter
        cp C_RIGHT
        ret z
        cp C_INK
        j c,.quest
        cp C_TAB+1
        j nc,.quest
        ld (TVDATA),a           ; a code with operands: wait for them
        cp C_AT
        ld a,1
        j c,.w1
        inc a
.w1:    ld (@rwait),a
        ret
.parm:  dec a
        ld (@rwait),a
        j z,.go
        ld a,e
        ld (TVDATA+1),a
        ret
.go:    ld a,(TVDATA)
        cp C_AT
        j z,.at
        j nc,.tab
        ld d,e                  ; INK ... OVER: the colours' state
        j @r2211
.quest: ld a,'?'
.able:  cp C_TOKEN
        j nc,@rtok
        push af
        call @rcfet
        call @rcwrap
        pop af
        cp C_GRAPH              ; no glyphs here for graphics, UDGs
        j c,.ch
        cp C_GRAPH              ; (80h, the empty block: a space)
        ld a,' '
        j z,.ch
        ld a,C_STAND
.ch:    push bc
        push af
        call @rcsync
        pop af
        call @rcput
        call @rcflush
        pop bc
        ld hl,@rccol
        inc (hl)
        dec c
        ld a,(FLAGS)            ; (@rtok's spacing: was it a space)
        res FL_SP,a
        ld e,a
        ld a,(@rclast)
        cp ' '
        ld a,e
        j nz,.ns
        set FL_SP,a
.ns:    ld (FLAGS),a
        j @rcsto
.enter: call @rcfet
        call @rcscr
        ld c,CCOL
        dec b
        j @rcsto
.comma: call @rcfet
        ld a,c
        dec a
        dec a
        and COLS/2
        j .fill
.tab:   ld a,(TVDATA+1)
        and COLS-1
        push af
        call @rcfet
        pop af
.fill:  add a,c                 ; spaces to column A
        dec a
        and COLS-1
        ret z
        ld b,a
        ld hl,FLAGS
        set FL_SP,(hl)
.sp:    push bc
        ld a,' '
        call @rpo
        pop bc
        djnz .sp
        ret
.at:    call @rcfet
        ld a,e                  ; the column
        cp COLS
        j nc,.errb
        ld a,CCOL
        sub e
        ld c,a
        ld a,(TVDATA+1)         ; the line
        ld e,a
        cp LINES-1
        j nc,.errb
        ld a,(TVFLAG)
        rra
        ld a,(DFSZ)
        j c,.atl
        neg
        add a,LINES-1
        cp e
        j c,.err5
        j .ok
.atl:   cp e
        j c,.err5
        j z,.err5
.ok:    ld a,CLINE
        sub e
        ld b,a
        j @rcsto
.errb:  ld a,R_RANGE
        jp @rerr
.err5:  ld a,R_SCR
        jp @rerr
.back:  call @rcfet
        ld a,c
        cp CCOL
        ret z                   ; (at column 0: no line above, here)
        inc c
        j @rcsto

; @rcfet: BC = the position (S_POSN, or the lower screen's S_POSNL).
@rcfet: ld a,(TVFLAG)
        rra
        ld bc,(SPOSN)
        ret nc
        ld bc,(SPOSNL)
        ret
; @rcsto: the position BC kept (the lower screen's on channel K as ECHO_E too).
@rcsto: ld a,(TVFLAG)
        rra
        j c,.l
        ld (SPOSN),bc
        ret
.l:     ld (SPOSNL),bc
        ld a,(FLAGS2)
        bit FL2_K,a
        ret z
        ld (ECHOE),bc
        ret

; @rcwrap: BC for a character: past the last column, the next line
; (the lower screen: its line again, from its start); then scrolled to.
@rcwrap:
        ld a,c
        dec a
        j nz,@rcscr
        ld c,CCOL
        ld a,(TVFLAG)
        rra
        j c,@rcscr
        dec b
; @rcscr: the upper screen past its last line: the console scrolled
; (its rows up a line, the lower screen's with them, as the ROM's do).
@rcscr: ld a,(TVFLAG)
        rra
        ret c
        ld a,(DFSZ)
        cp b
        ret c
        j nz,.out
        push bc
        ld a,C_AT               ; newline on its last row: it scrolls
        call @rcput
        ld a,CON_LOW
        call @rcput
        xor a
        call @rcput
        ld a,C_LF
        call @rcput
        call @rcflush
        ld a,CON_LOW
        ld (@rcrow),a
        xor a
        ld (@rccol),a
        pop bc
        inc b
        ret
.out:   ld a,R_SCR
        jp @rerr

; @rcsync: the console's cursor and colours for position BC: AT and the
; colour codes, when they differ from what it has.  Keeps BC.
@rcsync:
        ld a,(TVFLAG)           ; the row: the upper screen's line, or CON_LOW
        rra
        ld a,CON_LOW
        j c,.r
        ld a,CLINE
        sub b
.r:     ld d,a
        ld a,CCOL
        sub c
        ld e,a                  ; D row, E column
        ld hl,(@rccol)          ; (L column, H row)
        ld a,l
        cp e
        j nz,.at
        ld a,h
        cp d
        j z,.col
.at:    ld a,C_AT
        call @rcput
        ld a,d
        call @rcput
        ld a,e
        call @rcput
        ld l,e
        ld h,d
        ld (@rccol),hl
.col:   ld a,(ATTRT)            ; the colours: ATTR_T's (MASK_T's "as it
        ld e,a                  ; was" has no console code)
        ld a,(@rcatt)
        xor e
        j z,.inv
        ld d,a                  ; the bits that changed
        and A_INK
        j z,.p
        ld a,C_INK
        call @rcput
        ld a,e
        and A_INK
        call @rcput
.p:     ld a,d
        and A_PAPER
        j z,.b
        ld a,C_PAPER
        call @rcput
        ld a,e
        and A_PAPER
        rrca
        rrca
        rrca
        call @rcput
.b:     ld a,d
        and A_BRT
        j z,.s
        ld a,C_BRT
        call @rcput
        ld a,e
        rlca
        rlca
        and 1
        call @rcput
.s:     ld a,e
        ld (@rcatt),a
.inv:   ld a,(PFLAG)
        and 1<<PF_INV
        ld e,a
        ld a,(@rcinv)
        cp e
        ret z
        ld a,e
        ld (@rcinv),a
        ld a,C_INV
        call @rcput
        ld a,e
        or a
        j z,@rcput
        ld a,1
        j @rcput

; @rcput: A to the console's buffer (written when full: @rcflush).
@rcput: push hl
        push de
        ld (@rclast),a
        ld e,a
        ld a,(@rcn)
        ld l,a
        ld h,0
        push de
        ld de,@rcbuf
        add hl,de
        pop de
        ld (hl),e
        inc a
        ld (@rcn),a
        cp CON_BUF
        pop de
        pop hl
        ret c
; @rcflush: the buffer written to the console (write(1)).  Keeps BC, DE, HL.
@rcflush:
        ld a,(@rcn)
        or a
        ret z
        push bc
        push de
        push hl
        ld c,a
        ld b,0
        ld hl,1
        ld de,@rcbuf
        ld a,SYS_WRITE
        call SYS
        xor a
        ld (@rcn),a
        pop hl
        pop de
        pop bc
        ret

; CL-SET: the position BC kept.
@r0DD9: j @rcsto

; CLS: the console cleared, the position top left, then CLS-LOWER.
@r0D6B: ld hl,0
        ld (COORDS),hl
        ld hl,FLAGS2
        res FL2_CLS,(hl)
        ld a,S_SCR
        call @r1601
        ld a,C_FF
        call @rcput
        call @rcflush
        xor a                   ; (its cursor home)
        ld (@rccol),a
        ld (@rcrow),a
        inc a
        ld (SCRCT),a
        ld bc,CLINE<<8|CCOL
        ld (SPOSN),bc
; CLS-LOWER: the console's lower row cleared (BORDCR), two lines for
; DF_SZ, the position its start; channel K.
@r0D6E: ld hl,TVFLAG
        res TVF_ED,(hl)
        set TVF_LOW,(hl)
        call @r0D4D
        ld a,LOWER
        ld (DFSZ),a
        ld a,S_KEY
        call @r1601
        ld bc,(CLINE-1)<<8|CCOL
        push bc
        call @rcsync
        ld b,COLS
.s:     ld a,' '
        call @rcput
        djnz .s
        call @rcflush
        ld a,COLS
        ld (@rccol),a
        pop bc
        j @rcsto

; @rinit, at the start: the system variables (@rsvini); the console:
; call 41's E (a terminal), D (the display file's page: 0, none - POKE
; and PEEK of the screen reach nothing); the positions, the console's
; cursor and colours not known yet.
@rinit: push bc
        push de
        push hl
        call @rsvini
        ld hl,0
        ld a,SYS_SCR
        call SYS
        ld a,d
        j nc,.k
        ld a,SCR_SPEC
        ld e,0
.k:     ld (@rdh),a
        ld a,e
        ld (@rterm),a
        ld bc,CLINE<<8|CCOL
        ld (SPOSN),bc
        ld bc,(CLINE-1)<<8|CCOL
        ld (SPOSNL),bc
        ld a,0FFh
        ld (@rccol),a
        ld (@rcatt),a
        ld (@rcinv),a
        ld a,S_SCR
        call @r1601
        pop hl
        pop de
        pop bc
        ret

; @rcexit, at the end: the console's own colours back.
@rcexit:
        push af
        push bc
        push de
        push hl
        ld hl,@rcend
.l:     ld a,(hl)
        call @rcput
        inc hl
        ld de,@rcende
        or a
        sbc hl,de
        add hl,de
        j nz,.l
        call @rcflush
        pop hl
        pop de
        pop bc
        pop af
        ret
@rcend: db C_INK,CON_INK,C_PAPER,CON_PAPER,C_BRT,0,C_INV,0
@rcende:

; ED-COPY: the line INPUT types (from @rline to its ENTER) printed from
; the lower screen's position, spaces to the last copy's end (ECHO_E,
; its new end), S_POSNL back at its start; the console's cursor at K_CUR.
@r111D: call @r0D4D
        ld hl,TVFLAG
        res TVF_MOD,(hl)
        res TVF_ED,(hl)
        ld a,(@rwait)           ; (a code's operands still to come: not
        ld (@rcwsav),a          ; these characters)
        xor a
        ld (@rwait),a
        ld hl,(SPOSNL)
        ld (@rcstart),hl
        ld (@rccur),hl
        ld hl,(ECHOE)
        ld (@rcold),hl
        call @rline
        ex de,hl
.l:     ld de,(KCUR)
        or a
        sbc hl,de
        add hl,de
        j nz,.nc
        push hl
        ld hl,(SPOSNL)          ; the cursor's place
        ld (@rccur),hl
        pop hl
.nc:    ld a,(hl)
        cp C_CR
        j z,.end
        push hl
        call @rpo
        pop hl
        inc hl
        j .l
.end:   ld de,(@rcold)
.bl:    ld hl,(SPOSNL)
        ld a,h
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
.done:  ld hl,(SPOSNL)
        ld (ECHOE),hl
        ld hl,(@rcstart)
        ld (SPOSNL),hl
        ld bc,(@rccur)
        call @rcsync
        call @rcflush
        ld a,(@rcwsav)
        ld (@rwait),a
        ret

        section bss
@rccol: ds 1                    ; the console's cursor: column (FFh: not known),
@rcrow: ds 1                    ; ... row
@rcatt: ds 1                    ; ... its colours, as last sent
@rcinv: ds 1
@rcn:   ds 1                    ; the buffer's bytes
@rcbuf: ds CON_BUF
@rclast: ds 1
@rcwsav: ds 1
@rcstart: ds 2
@rcold: ds 2
@rccur: ds 2
