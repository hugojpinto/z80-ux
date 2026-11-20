; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): pixels, in place of the 48K ROM's PIXEL-ADD, PLOT, DRAW (a
; line) and SCREEN$, in the display file at page @rdh.  PLOT and DRAW set
; points under OVER and INVERSE and colour their cells as PRINT does
; (@rsetat); a line steps along its longer side, the shorter one by an
; error carried from half the longer.  Clean room: checked pixel by
; pixel against the ROM's (test/basic/romdiff.py).
        section text
        global @r22AA,@r22E5,@r22DF,@r24B7,@r2477,@r2538,@rstkbc,@rdline,@r232D,@rmap,@rattrh

; PIXEL-ADD: B = y (0 at the bottom), C = x -> HL = the pixel's byte, A =
; its bit's place from the left (0-7); B Integer out of range past YMAX.
@r22AA: ld a,YMAX
        sub b
        j c,.errb
        ld b,a                  ; the line from the top: 0-175
        and L_THIRD<<3          ; its third
        rrca
        rrca
        rrca
        ld h,a
        ld a,b
        and L_ROW               ; its pixel row in the character
        or h
        ld h,a
        ld a,(@rdh)
        add a,h
        ld h,a
        ld a,b                  ; its character line in the third
        rlca
        rlca
        and L_ROW<<5
        ld l,a
        ld a,c
        rrca
        rrca
        rrca
        and COLS-1
        or l
        ld l,a
        ld a,c
        and 7
        ret
.errb:  ld a,R_RANGE
        jp @rerr

; PLOT-SUB: the point BC (C = x, B = y): COORDS, the pixel (OVER: flipped;
; INVERSE: cleared), its cell's colour.  PLOT: then TEMPS.
@r22DF: call @r22E5
        j @r0D4D
@r22E5: ld (COORDS),bc
        call @r22AA
        ld b,a                  ; the bit: 80h >> A
        inc b
        ld a,1
.bit:   rrca
        djnz .bit
        ld b,a
        ld a,(PFLAG)
        ld c,a
        ld a,(hl)
        bit PF_OVER,c
        j nz,.ov
        bit PF_INV,c
        j nz,.clr
        or b                    ; set
        j .st
.ov:    bit PF_INV,c
        j nz,.st                ; (OVER and INVERSE: left as it is)
        xor b
        j .st
.clr:   ld c,a
        ld a,b
        cpl
        and c
.st:    ld (hl),a
        ld a,(PFLAG)
        ld c,a
        j @rsetat

; @rstkbc (STK-TO-BC): the top two numbers off the stack: B = the top's
; magnitude, D = its sign (1, or 0FFh below 0), C and E the next's; B
; Integer out of range past 255.
@rstkbc:
        call .one
        ld b,a
        push bc
        call .one
        ld e,c
        pop bc
        ld d,c
        ld c,a
        ret
.one:   call @r2DA2             ; rounded: BC, A = C, Z if not negative
        j c,.errb
        push af
        ld a,b
        or a
        j nz,.errb
        pop af
        ld c,1
        ret z
        ld c,0FFh
        ret
.errb:  ld a,R_RANGE
        jp @rerr

; DRAW-LINE: from COORDS by the two numbers on the stack (x, then y on
; top).  DRAW (the ROM's 2477h): then TEMPS.
@r2477: call @r24B7
        j @r0D4D
@r24B7: call @rstkbc            ; C |dx|, E its sign; B |dy|, D its sign
; @rdline: the line from COORDS by C |dx| (E its sign), B |dy| (D its sign).
@rdline:
        ld a,c
        cp b
        j nc,.xl
        ld l,c                  ; y the longer: its steps every time
        ld h,b
        ld (@rgdia),de          ; a diagonal step
        ld e,0                  ; a straight one: y alone
        ld (@rgstr),de
        j .go
.xl:    or c
        ret z                   ; (0, 0: nothing)
        ld l,b                  ; x the longer
        ld h,c
        ld (@rgdia),de
        ld d,0                  ; straight: x alone
        ld (@rgstr),de
.go:    ld b,h                  ; the steps
        ld a,h
        srl a                   ; the error: half the longer side
.loop:  add a,l
        j c,.dia
        cp h
        j c,.str
.dia:   sub h
        ld de,(@rgdia)
        j .step
.str:   ld de,(@rgstr)
.step:  push af
        push bc
        push hl
        ld bc,(COORDS)          ; (C x, B y)
        ld a,b
        add a,d
        ld b,a
        ld a,e
        add a,c
        ld c,a                  ; x: past 0 or 255 is out of range
        ld a,e
        or a
        j z,.ok
        rla                     ; (E: 1 or 0FFh)
        j c,.left
        ld a,c
        or a
        j z,.errb
        j .ok
.left:  ld a,c
        inc a
        j z,.errb
.ok:    call @r22E5
        pop hl
        pop bc
        pop af
        djnz .loop
        ret
.errb:  ld a,R_RANGE
        jp @rerr

; SCREEN$: C = the line, B = the column -> the character there (CHARS'
; glyph, or its inverse) as a string on the stack; none: an empty one.
@r2538: ld a,c
        push bc
        call @rlnad             ; HL = the line's first character
        pop bc
        ld a,b
        add a,l
        ld l,a
        ld (@rgcell),hl
        ld hl,(CHARS)
        ld de,' '*CELL
        add hl,de               ; the first glyph
        ld c,' '
.ch:    push hl
        ld de,(@rgcell)
        ld b,CELL
        ld a,(de)
        xor (hl)                ; 0: the glyph, 0FFh: its inverse
        ld (@rgmask),a
        or a
        j z,.cmp
        inc a
        j nz,.no
.cmp:   ld a,(de)
        xor (hl)
        push hl
        ld hl,@rgmask
        cp (hl)
        pop hl
        j nz,.no
        inc hl
        inc d
        djnz .cmp
        pop hl
        ld a,c                  ; found
        call @r35D0
        ret
.no:    pop hl
        ld de,CELL
        add hl,de
        inc c
        ld a,c
        cp ' '+FONT_N
        j nz,.ch
        ld bc,0                 ; none: ""
        jp @rstostr

; CIRCLE: x, y, r on the stack (r on top): a polygon of A = 4 INT(pi
; SQR r / 4) + 4 sides (as many as the ROM's) inscribed in the circle,
; from (x + r, y), each corner rounded, joined by @rdline; then TEMPS.
; r rounding to 0: the point x, y.  B Integer out of range off the screen.
; (The ROM places its corners by its own arithmetic: a pixel can differ.)
@r232D: ld hl,@rcr              ; r, y, x off the stack
        call .pop
        ld hl,@rcy
        call .pop
        ld hl,@rcx
        call .pop
        ld hl,@rcr
        ld b,h
        ld c,l
        ld a,F_ABS
        call @rfcall
        ld hl,@rcr              ; r < 1/2: the point
        ld de,@chalf
        ld bc,@rct
        ld a,F_SUB
        call @rfcall
        ld a,(@rct+1)
        and N_SIGN
        j z,.big
        ld hl,@rcx
        call .round
        push af
        ld hl,@rcy
        call .round
        ld b,a
        pop af
        ld c,a
        call @r22E5
        j @r0D4D
.big:   ld hl,@rcr              ; A = 4 INT(pi SQR r / 4) + 4
        ld bc,@rct
        ld a,F_SQR
        call @rfcall
        ld hl,@rct
        ld de,@cpi4
        ld b,h
        ld c,l
        ld a,F_MUL
        call @rfcall
        ld hl,@rct
        call @r33B4
        call @r2DA2             ; (rounded: INT of t, as t - 1/2 rounds)
        ld hl,@rct              ; (A from INT: t - 1/2 rounded)
        ld a,c
        ld (@rcn),a
        call .intfix
        ld a,(@rcn)
        add a,a
        add a,a
        add a,4
        ld (@rcn),a
        ld l,a                  ; theta = 2 pi / A: its cos and sin
        ld h,0
        ld (@rct+2),hl
        xor a
        ld (@rct),a
        ld (@rct+1),a
        ld (@rct+4),a
        ld hl,@c2pi
        ld de,@rct
        ld bc,@rcs
        ld a,F_DIV
        call @rfcall
        ld hl,@rcs
        ld bc,@rcc
        ld a,F_COS
        call @rfcall
        ld hl,@rcs
        ld b,h
        ld c,l
        ld a,F_SIN
        call @rfcall
        ld hl,@rcr              ; (U, V) = (r, 0)
        ld de,@rcu
        ld bc,FNUM
        ldir
        ld hl,@rcv
        ld b,FNUM
.z:     ld (hl),0
        inc hl
        djnz .z
        call .corner            ; the first corner: plotted
        call @r22E5
.side:  ld hl,@rcu              ; (U, V) turned by theta
        ld de,@rcc
        ld bc,@rct              ; U cos
        ld a,F_MUL
        call @rfcall
        ld hl,@rcv
        ld de,@rcs
        ld bc,@rcw              ; V sin
        ld a,F_MUL
        call @rfcall
        ld hl,@rcv
        ld de,@rcc
        ld b,h                  ; V cos
        ld c,l
        ld a,F_MUL
        call @rfcall
        ld hl,@rcu
        ld de,@rcs
        ld b,h                  ; U sin
        ld c,l
        ld a,F_MUL
        call @rfcall
        ld hl,@rcv              ; V = V cos + U sin
        ld de,@rcu
        ld b,h
        ld c,l
        ld a,F_ADD
        call @rfcall
        ld hl,@rct              ; U = U cos - V sin
        ld de,@rcw
        ld bc,@rcu
        ld a,F_SUB
        call @rfcall
        call .corner            ; BC = the next corner
        ld hl,(COORDS)
        ld a,c                  ; dx
        sub l
        ld e,1
        j nc,.px
        neg
        ld e,0FFh
.px:    ld c,a
        ld a,b                  ; dy
        sub h
        ld d,1
        j nc,.py
        neg
        ld d,0FFh
.py:    ld b,a
        call @rdline
        ld hl,@rcn
        dec (hl)
        j nz,.side
        j @r0D4D
; .corner: BC = (x + U, y + V) rounded (C x, B y); B Integer out of range off the screen
.corner:
        ld hl,@rcx
        ld de,@rcu
        call .sum
        push af
        ld hl,@rcy
        ld de,@rcv
        call .sum
        ld b,a
        pop af
        ld c,a
        ld a,b
        cp YMAX+1
        ret c
.errb:  ld a,R_RANGE
        jp @rerr
.sum:   ld bc,@rct
        ld a,F_ADD
        call @rfcall
        ld hl,@rct
; .round: A = the number at HL rounded, 0-255; else B Integer out of range
.round: call @r33B4
        call @r2DA2
        j c,.errb
        j nz,.errb
        ld a,b
        or a
        j nz,.errb
        ld a,c
        ret
; .intfix: (@rcn) = INT of t at @rct, from its rounding: less 1 if t rounded up
.intfix:
        ld hl,@rcn
        ld a,(hl)
        or a
        ret z
        ld l,a
        ld h,0
        ld (@rcw+2),hl
        xor a
        ld (@rcw),a
        ld (@rcw+1),a
        ld (@rcw+4),a
        ld hl,@rct              ; t - its rounding below 0: rounded up
        ld de,@rcw
        ld bc,@rcw
        ld a,F_SUB
        call @rfcall
        ld a,(@rcw+1)
        and N_SIGN
        ret z
        ld hl,@rcn
        dec (hl)
        ret
.pop:   push hl                 ; the top number to HL
        call @r35BF
        ld (STKEND),hl
        pop de
        ld bc,FNUM
        ldir
        ret

; @rattrh: A = a third of the screen (0-3) -> A = its attributes' page
; (the runtime's ATTR formed it as 58h + the third).
@rattrh:
        push bc
        ld b,a
        ld a,(@rdh)
        add a,ATTRS>>8
        add a,b
        pop bc
        ret

; @rmap: HL = an address as BASIC PEEKs and POKEs it (the Spectrum's) ->
; HL = where it is here: the display file (4000h - 5AFFh) at page @rdh;
; the ROM's font (FONT_ROM - 3FFFh) the program's own (CHARS); the rest of
; the ROM: a zero byte.  Keeps BC, DE.
@rmap:  ld a,h
        cp SCR_SPEC
        j c,.rom
        cp SCR_SPEC+(ATTRS+COLS*LINES)/256
        ret nc
        sub SCR_SPEC
        push bc
        ld b,a
        ld a,(@rdh)
        or a                    ; (no display file: nothing there)
        j z,.nod
        add a,b
        ld h,a
        pop bc
        ret
.nod:   pop bc
        j .none
.rom:   cp FONT_ROM>>8
        j c,.none
        push de
        ld de,FONT_ROM-256
        or a
        sbc hl,de               ; (CHARS: 256 bytes before ' ')
        ld de,(CHARS)
        add hl,de
        pop de
        ret
.none:  ld hl,@rzero
        ret

        section bss
@rzero: ds 1
@rcx:   ds FNUM
@rcy:   ds FNUM
@rcr:   ds FNUM
@rcu:   ds FNUM
@rcv:   ds FNUM
@rcc:   ds FNUM
@rcs:   ds FNUM
@rct:   ds FNUM
@rcw:   ds FNUM
@rcn:   ds 1
@rgdia: ds 2
@rgstr: ds 2
@rgcell: ds 2
@rgmask: ds 1
