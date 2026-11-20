; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): the screen as PRINT sees it, in place of the 48K ROM's
; output (platform/basic.md).
;
; @r10 (RST 10h) prints A through the current channel: the screen ('S',
; the upper part; 'K', the lower), with the Spectrum's control codes (C_
; in rbc.inc: comma, back, right, ENTER, INK ... OVER with one operand, AT
; and TAB with two), characters from CHARS, block graphics, UDGs, keywords
; (@rtok); other codes as '?'.  The printer ('P') takes nothing: ZX-UX has
; none.
;
; State: the system variables at @rsv (S_POSN, DF_CC, the lower screen's
; S_POSNL, DFCCL, DF_SZ, ATTR_T, MASK_T, P_FLAG, TV_FLAG, TVDATA...), the
; display file at page @rdh (system call 41's answer, from @rinit).
; Clean room: written from what PRINT does on the screen, checked against
; the ROM's output on the same character streams (test/basic/romdiff.py).
        section text
        global @r10,@rpo,@r1601,@r0D4D,@r1CAD,@r2211,@r0DD9,@r203C
        global @r0D6B,@r0D6E,@r2297,@r1E52,@r1E56,@r21D6,@rcladdr,@rattr,@rinit,@rterm,@rwait

; RST 10h: A through the current channel.  Keeps BC, DE, HL.
@r10:   push bc
        push de
        push hl
        ld hl,(CURCHL)
        ld de,CH_LET
        add hl,de
        ld e,a
        ld a,(hl)
        cp 'P'
        ld a,e
        call nz,@rpo
        pop hl
        pop de
        pop bc
        ret

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
        cp C_RIGHT
        j z,.right
        cp C_ENTER
        j z,.enter
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
        ld a,e                  ; AT and TAB: the first of two
        ld (TVDATA+1),a
        ret
.go:    ld a,(TVDATA)
        cp C_AT
        j z,.at
        j nc,.tab
        ld d,e                  ; INK ... OVER: the operand in D
        j @r2211
.quest: ld a,'?'
.able:  cp C_TOKEN
        j nc,@rtok
        call @rfetch
        call @rchar
        j @rstore
; ENTER: the next line
.enter: call @rfetch             ; (a line past the bottom scrolls first:
        call @rscr              ; the next line may be past it, until a
        ld c,CCOL               ; character is printed there)
        dec b
        call @rcset
        j @rstore
; comma: spaces to column 0 or 16
.comma: call @rfetch
        ld a,c
        dec a
        dec a
        and COLS/2
        j @rfill
; TAB n: spaces to column n (mod COLS)
.tab:   ld a,(TVDATA+1)
        and COLS-1
        push af
        call @rfetch
        pop af
        j @rfill
; AT line, column
.at:    call @rfetch
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
        neg                     ; upper: lines 0 .. LINES-1-DF_SZ
        add a,LINES
        dec a
        cp e
        j c,.err5
        ld a,CLINE
        sub e
        ld b,a
        call @rcset
        j @rstore
.atl:   cp e                    ; lower: lines 0 .. DF_SZ-1
        j c,.err5
        j z,.err5
        ld a,CLINE
        sub e
        ld b,a
        call @rcset
        j @rstore
.errb:  ld a,R_RANGE
        jp @rerr
.err5:  ld a,R_SCR
        jp @rerr
; backspace: one column left (to the end of the line above)
.back:  call @rfetch             ; (from column 0: the end of the line
        inc c                   ; above - but not from line 1, and from
        ld a,c                  ; line 0 to "line -1", as in the ROM)
        cp CCOL+1
        j nz,.b1
        inc b
        ld c,CCOL-COLS+1
        ld a,b
        cp CLINE
        j nz,.b1
        dec b
        ld c,CCOL
.b1:    call @rcset
        j @rstore
; 09: the next cell as a character would take it (past the line's end:
; the next line), its attribute set; the position not advanced
.right: call @rfetch
        call @rwrap
        call @rstore
        ld hl,FLAGS             ; (a space, for @rtok's spacing)
        set FL_SP,(hl)
        call @rfetch
        ld c,1<<PF_OVER         ; (under OVER 1 alone: no INK 9, PAPER 9)
        j @rsetat

; @rfill: spaces from the position in BC to column A (none if there).
@rfill: add a,c
        dec a
        and COLS-1
        ret z
        ld d,a
.sp:    push de
        ld a,' '
        call @rpo
        pop de
        dec d
        j nz,.sp
        ret

; @rfetch: BC = the position (C = CCOL-column, B = CLINE-line), HL = its address;
; upper or lower screen.
@rfetch:
        push af
        ld a,(TVFLAG)
        rra
        j c,.l
        ld bc,(SPOSN)
        ld hl,(DFCC)
        pop af
        ret
.l:     ld bc,(SPOSNL)
        ld hl,(DFCCL)
        pop af
        ret

; @rstore: the position BC and its address HL kept (the lower screen's,
; on channel K, as ECHO_E too).
@rstore:
        ld a,(TVFLAG)
        rra
        j c,.l
        ld (SPOSN),bc
        ld (DFCC),hl
        ret
.l:     ld (SPOSNL),bc
        ld (DFCCL),hl
        ld a,(FLAGS2)           ; channel K's: the echo's end too
        bit FL2_K,a
        ret z
        ld (ECHOE),bc
        ret

; @rcset: HL = the address of position BC (CL-SET).
; @r0DD9: the same, kept as the position (the ROM's CL-SET).
@r0DD9: call @rcset
        j @rstore
@rcset: push bc
        ld a,(TVFLAG)
        rra
        ld a,b
        j nc,.u
        ld a,(DFSZ)             ; lower: B counts from CLINE at its top line
        add a,b
        sub LINES
.u:     call @rcladdr           ; line CLINE-A
        pop bc
        ld a,CCOL
        sub c
        add a,l
        ld l,a
        ret

; @rcladdr: HL = the display address of line CLINE-A, column 0.
@rcladdr:
        ld l,a
        ld a,CLINE
        sub l
        ld l,a                  ; the line
        and L_THIRD             ; its third: 8 lines, 8 pixel rows each
        ld h,a
        ld a,(@rdh)
        add a,h
        ld h,a
        ld a,l
        and L_ROW               ; its line in the third: 32 bytes each
        rrca
        rrca
        rrca
        ld l,a
        ret

; @rscr: about to use line B: scroll first if it is past the bottom.
; -> HL = the address of position BC.  The upper screen scrolls as the
; ROM's does: the whole display's pixels up a line (the lower screen's
; top line rises into the upper's last), the upper screen's attributes up
; with its last line ATTR_P, the lower screen's attribute lines rotated.
@rscr:  ld a,(TVFLAG)
        rra
        j c,.low
        ld a,(DFSZ)
        cp b
        j c,@rcset
        j nz,.out
        ld a,(SCRCT)            ; (rbc keeps SCR_CT at 255: no "scroll?")
        dec a
        j nz,.s1
        ld a,1
.s1:    ld (SCRCT),a
        push bc
        ld bc,LINES<<8          ; pixels: all the lines
        call @rpscr
        ld a,(DFSZ)             ; attributes: the upper screen's lines
        neg
        add a,LINES
        ld b,a
        ld c,0
        ld a,(ATTRP)
        call @rascr
        ld a,(DFSZ)             ; the lower screen's, rotated
        ld b,a
        neg
        add a,LINES
        ld c,a
        ld a,ROTATE
        call @rascr
        pop bc
        inc b
        j @rcset
.out:   ld a,R_SCR
        jp @rerr
.low:   ld a,(DFSZ)             ; the lower screen grows by a line
        neg
        add a,CLINE
        cp b
        j c,@rcset
        push bc
        ld a,(DFSZ)
        inc a
        cp LINES
        j nc,.out
        ld (DFSZ),a
        ld b,a                  ; its lines scroll up into the new one
        neg
        add a,LINES
        ld c,a
        push bc
        call @rpscr
        pop bc
        ld a,(BORDCR)
        call @rascr
        ld a,(DFSZ)             ; the upper screen loses its last line
        ld b,a
        ld a,(SPOSN+1)
        dec a
        cp b
        j nc,.l2
        ld a,b
        inc a
        ld (SPOSN+1),a
        ld b,a
        ld a,(SPOSN)
        ld c,a
        ld hl,TVFLAG
        res TVF_LOW,(hl)
        call @rcset
        ld (DFCC),hl
        ld hl,TVFLAG
        set TVF_LOW,(hl)
.l2:    pop bc
        j @rcset

; @rpscr: the pixels of lines C .. C+B-1 up a line; the last cleared.
@rpscr: dec b
        j z,.clr
.l:     push bc
        ld a,c
        call @rlnad
        ex de,hl
        pop bc
        push bc
        ld a,c
        inc a
        call @rlnad
        ld b,CELL
.r:     push bc
        push hl
        push de
        ld bc,COLS
        ldir
        pop de
        pop hl
        inc h
        inc d
        pop bc
        djnz .r
        pop bc
        inc c
        djnz .l
.clr:   ld a,c
        call @rlnad
        ld b,CELL
.p:     push bc
        push hl
        ld b,COLS
.z:     ld (hl),0
        inc hl
        djnz .z
        pop hl
        inc h
        pop bc
        djnz .p
        ret

; @rascr: the attributes of lines C .. C+B-1 up a line; the last line A
; (FFh: the first line's, a rotation).
@rascr: push af
        push bc
        ld a,c
        call @rlnad
        call @rattr             ; HL = line C's attributes
        ld de,@rarow
        push hl
        ld bc,COLS
        ldir                    ; (kept, for a rotation)
        pop de
        pop bc
        push bc
        ld hl,COLS
        add hl,de
        dec b
        j z,.last
        ld a,b                  ; (B-1) * COLS bytes, from line C+1 to C
        push hl
        ld hl,0
        ld bc,COLS
.m:     add hl,bc
        dec a
        j nz,.m
        ld b,h
        ld c,l
        pop hl
        ldir
.last:  pop bc                  ; DE: the last line's attributes
        pop af
        cp ROTATE
        j z,.rot
        ld b,COLS
.f:     ld (de),a
        inc de
        djnz .f
        ret
.rot:   ld hl,@rarow
        ld bc,COLS
        ldir
        ret

; @rlnad: HL = the address of line A, column 0.
@rlnad: ld l,a
        ld a,CLINE
        sub l
        j @rcladdr

; @rclr1: line at HL cleared: pixels 0, attributes A.
@rclr1: push af
        ld b,CELL
.p:     push bc
        push hl
        ld b,COLS
.z:     ld (hl),0
        inc hl
        djnz .z
        pop hl
        inc h
        pop bc
        djnz .p
        dec h
        call @rattr
        pop af
        ld b,COLS
.a:     ld (hl),a
        inc hl
        djnz .a
        ret

; @rattr: HL = the attribute of the character cell whose pixels are at HL.
@rattr: ld a,(@rdh)
        neg
        add a,h
        rrca
        rrca
        rrca
        and L_THIRD>>3
        add a,ATTRS>>8
        push bc
        ld b,a
        ld a,(@rdh)
        add a,b
        pop bc
        ld h,a
        ret

; @rwrap: the cell for a character at BC: past the last column, the next
; line; a line's first column, scrolled to if needed.  Keeps A.
@rwrap: push af
        ld a,c
        dec a
        ld a,CCOL
        j nz,.c1
        dec b
        ld c,a
.c1:    cp c
        call z,@rscr
        pop af
        ret

; @rchar: character A at position BC (address HL); BC, HL advanced.
@rchar: call @rwrap
        ld (@rlast),a
        push bc
        push hl
        ld de,@rgly
        cp C_GRAPH
        j nc,.gr
        ld l,a                  ; CHARS + CELL * A
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,(CHARS)
        add hl,de
        ex de,hl
        j .draw
.gr:    cp C_UDG
        j nc,.udg
        push de                 ; block graphics: quadrants by bits 0-3
        call .half
        call .half
        pop de
        j .draw
.half:  rra                     ; bit 0 / 2: right, bit 1 / 3: left
        push af
        sbc a,a
        and GR_R
        ld c,a
        pop af
        rra
        push af
        sbc a,a
        and GR_L
        or c
        ld b,CELL/2
.hw:    ld (de),a
        inc de
        djnz .hw
        pop af
        ret
.udg:   sub C_UDG
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,(UDG)
        add hl,de
        ex de,hl
; DE = the 8 bytes, at (SP) the address: drawn with OVER and INVERSE
.draw:  pop hl
        push hl
        ld a,(PFLAG)
        ld c,a
        ld b,CELL
.row:   ld a,(de)
        bit PF_INV,c
        j z,.ni
        cpl
.ni:    bit PF_OVER,c
        j z,.no
        xor (hl)
.no:    ld (hl),a
        inc de
        inc h
        djnz .row
        pop hl
        push hl
        call @rsetat
        pop hl
        pop bc
        inc hl
        dec c
        ld a,(@rlast)           ; whether it was a space, for @rtok's
        cp C_GRAPH              ; spacing (a block graphic leaves that as
        j c,.sp                 ; it was; a UDG is not a space)
        cp C_UDG
        ret c
.sp:    push hl
        ld hl,FLAGS
        res FL_SP,(hl)
        cp ' '
        j nz,.ns
        set FL_SP,(hl)
.ns:    pop hl
        ret

; @rsetat: the attribute of the cell at HL: ATTR_T where MASK_T is 0,
; INK 9 and PAPER 9 (P_FLAG in C).
@rsetat:
        call @rattr
        ld a,(MASKT)
        ld b,a
        ld a,(ATTRT)
        ld e,a
        xor (hl)
        and b
        xor e                   ; (old AND mask) OR (ATTR_T AND NOT mask)
        bit PF_PAP9,c           ; PAPER 9: paper in contrast to ink
        j z,.p9
        and ~A_PAPER & 0FFh
        bit A_INKL,a
        j nz,.p9
        xor A_PAPER
.p9:    bit PF_INK9,c           ; INK 9: ink in contrast to paper
        j z,.i9
        and ~A_INK & 0FFh
        bit A_PAPL,a
        j nz,.i9
        xor A_INK
.i9:    ld (hl),a
        ret

; CHAN-OPEN: stream A (0, 1, S_KEY: 'K', the lower screen; 2, S_SCR: 'S';
; others: 'P').
@r1601: ld hl,@rchk
        cp S_MAIN
        j c,.k
        cp S_KEY
        j z,.k
        ld hl,@rchs
        cp S_SCR
        j z,.s
        cp S_MAIN
        j z,.s
        ld hl,@rchp
        ld (CURCHL),hl
        ld hl,FLAGS2
        res FL2_K,(hl)
        ld hl,FLAGS
        set FL_PR,(hl)
        ret
.k:     ld (CURCHL),hl
        ld hl,TVFLAG
        set TVF_LOW,(hl)
        ld hl,FLAGS
        res FL_KEY,(hl)
        res FL_PR,(hl)
        ld hl,FLAGS2
        set FL2_K,(hl)
        j @r0D4D
.s:     ld (CURCHL),hl
        ld hl,FLAGS2
        res FL2_K,(hl)
        ld hl,TVFLAG
        res TVF_LOW,(hl)
        ld hl,FLAGS
        res FL_PR,(hl)
; TEMPS: the temporary colours from the permanent ones (the lower screen:
; BORDCR, no mask, no OVER or INVERSE).
@r0D4D: ld a,(TVFLAG)
        rra
        j c,.l
        ld hl,(ATTRP)           ; ATTR_P, MASK_P
        ld (ATTRT),hl
        ld hl,PFLAG             ; the even (temporary) bits from the odd
        ld a,(hl)
        rrca
        xor (hl)
        and PF_TEMP
        xor (hl)
        ld (hl),a
        ret
.l:     ld a,(BORDCR)
        ld (ATTRT),a
        xor a
        ld (MASKT),a
        ld hl,PFLAG
        ld a,(hl)
        and PF_PERM
        ld (hl),a
        ret

; The temporary colours made permanent (after INK ..., as a statement).
@r1CAD: ld hl,(ATTRT)
        ld (ATTRP),hl
        ld hl,PFLAG             ; the odd (permanent) bits from the even
        ld a,(hl)
        rlca
        xor (hl)
        and PF_PERM
        xor (hl)
        ld (hl),a
        ret

; CO-TEMP-5: A = C_INK .. C_OVER (INK, PAPER, FLASH, BRIGHT, INVERSE,
; OVER), D = the value -> the temporary colours; K Invalid colour.
@r2211: sub C_INK
        j z,.ink
        dec a
        j z,.pap
        dec a
        j z,.fla
        dec a
        j z,.bri
        dec a
        ld c,1<<PF_INV          ; INVERSE
        j z,.pf
        ld c,1<<PF_OVER         ; OVER
.pf:    ld a,d
        cp 2
        j nc,.errk
        ld hl,PFLAG
        ld a,c
        cpl
        and (hl)
        ld (hl),a
        ld a,d
        or a
        ret z
        ld a,c
        or (hl)
        ld (hl),a
        ret
.ink:   ld a,d
        ld bc,A_INK<<8|1<<PF_INK9
        j .col
.pap:   ld a,d
        rlca
        rlca
        rlca
        ld bc,A_PAPER<<8|1<<PF_PAP9
        j .col
.fla:   ld b,A_FLASH
        j .fb
.bri:   ld b,A_BRT
.fb:    ld a,d                  ; 0, 1 or COL_TR
        cp COL_TR
        j z,.tr
        cp 2
        j nc,.errk
        or a
        j z,.f0
        ld a,b
.f0:    ld e,a
        ld c,0
        j .set
.tr:    ld a,b                  ; COL_TR: transparent (ATTR_T's bit cleared)
        ld hl,MASKT
        or (hl)
        ld (hl),a
        ld a,b
        cpl
        ld hl,ATTRT
        and (hl)
        ld (hl),a
        ret
.col:   ld e,a                  ; 0-7: set, 8: transparent, 9: contrast
        ld a,d
        cp COL_MAX
        j nc,.errk
        ld hl,PFLAG
        ld a,c
        cpl
        and (hl)
        ld (hl),a
        ld a,d
        cp COL_TR
        j c,.set0
        j nz,.c9
        ld a,b                  ; 8: the mask's bits
        ld hl,MASKT
        or (hl)
        ld (hl),a
        ret
.c9:    ld a,c                  ; 9: contrast, and transparent; ATTR_T's
        or (hl)                 ; bits in contrast now (ink 0 on a light
        ld (hl),a               ; paper, 7 on a dark one; paper likewise)
        ld a,b
        ld hl,MASKT
        or (hl)
        ld (hl),a
        ld hl,ATTRT
        ld a,b
        cp A_INK
        ld a,(hl)
        j nz,.pc
        and ~A_INK & 0FFh
        bit A_PAPL,a
        j nz,.s9
        or A_INK
        j .s9
.pc:    and ~A_PAPER & 0FFh
        bit A_INKL,a
        j nz,.s9
        or A_PAPER
.s9:    ld (hl),a
        ret
.set0:  ld c,0
.set:   ld a,b                  ; ATTR_T's bits B from E; MASK_T's cleared
        cpl
        ld hl,MASKT
        and (hl)
        ld (hl),a
        ld hl,ATTRT
        ld a,(hl)
        xor e
        and b
        xor (hl)
        ld (hl),a
        ret
.errk:  ld a,R_COL
        jp @rerr

; PR-STRING: BC characters from DE.
@r203C: ld a,b
        or c
        ret z
        ld a,(de)
        inc de
        dec bc
        push bc
        push de
        call @r10
        pop de
        pop bc
        j @r203C

; CLS: the whole screen cleared (ATTR_P; the lower part BORDCR), the
; position top left, then CLS-LOWER.
@r0D6B: ld hl,0
        ld (COORDS),hl
        ld hl,FLAGS2
        res FL2_CLS,(hl)
        ld a,S_SCR              ; the upper screen's colours
        call @r1601
        ld c,0
.l:     push bc
        ld a,c
        call @rlnad
        ld a,(ATTRP)
        call @rclr1
        pop bc
        inc c
        ld a,c
        cp LINES
        j c,.l
        ld a,1
        ld (SCRCT),a
        ld bc,CLINE<<8|CCOL
        call @rcset
        call @rstore
; CLS-LOWER: the lower screen cleared (BORDCR), two lines high, the
; position the start of its bottom line; channel K.
@r0D6E: ld hl,TVFLAG
        res TVF_ED,(hl)
        set TVF_LOW,(hl)
        call @r0D4D
        ld a,(DFSZ)
        ld b,a
.lw:    push bc
        ld a,LINES
        sub b
        call @rlnad
        ld a,(BORDCR)
        call @rclr1
        pop bc
        djnz .lw
        ld a,LOWER
        ld (DFSZ),a
        ld a,S_KEY
        call @r1601
        ld bc,(CLINE-1)<<8|CCOL ; its bottom line
        call @rcset
        j @rstore

; BORDER: A (0-7).  The border is the platform's (the console's colour
; on a Spectrum): only BORDCR, for the lower screen's colours.
@r2297: cp A_INK+1
        j nc,.errk
        rlca                    ; as a paper, with ink in contrast
        rlca
        rlca
        bit A_PAPL,a
        j nz,.dark
        xor A_INK
.dark:  ld (BORDCR),a
        ret
.errk:  ld a,R_COL
        jp @rerr

; RANDOMIZE BC (0: the time, the kernel's ticks: nothing counts FRAMES in
; the program's own system variables).
@r1E52: ld a,b
        or c
        j nz,@rseed
@r1E56: push hl                 ; (FRAMES: the kernel's ticks)
        ld a,SYS_TICKS
        call SYS
        ld b,h
        ld c,l
        pop hl
@rseed: ld (SEED),bc
        ret

; IN-CHAN-K: Z if the current channel is 'K'.
@r21D6: ld hl,(CURCHL)
        ld de,CH_LET
        add hl,de
        ld a,(hl)
        cp 'K'
        ret

; The channels, as CURCHL points to them: two addresses, then the letter.
@rchk:  dw 0,0
        db 'K'
@rchs:  dw 0,0
        db 'S'
@rchp:  dw 0,0
        db 'P'

; @rinit, at the start (after the screen's claim): the system variables
; set up; the display file's page from the platform (system call 41: D)
; and whether the console is a terminal (E = 1), or the Spectrum's for a
; kernel without it.  Keeps BC, DE, HL.
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
        ld e,0                  ; (no call 41: a Spectrum's screen)
.k:     ld (@rdh),a
        ld a,e
        ld (@rterm),a
        ld hl,TVFLAG            ; the positions: the lower screen's bottom
        set TVF_LOW,(hl)        ; line, the upper screen's top left
        ld bc,(CLINE-1)<<8|CCOL
        call @rcset
        ld (SPOSNL),bc
        ld (DFCCL),hl
        ld hl,TVFLAG
        res TVF_LOW,(hl)
        ld bc,CLINE<<8|CCOL
        call @rcset
        ld (SPOSN),bc
        ld (DFCC),hl
        ld a,S_SCR
        call @r1601
        pop hl
        pop de
        pop bc
        ret

        section data
@rdh:   db SCR_SPEC             ; the display file's page (@rinit)
        section bss
@rlast: ds 1                    ; the last character drawn
@rterm: ds 1                    ; the console is a terminal (call 41's E)
@rwait: ds 1                    ; operands still to come
@rgly:  ds 8
@rarow: ds 32
