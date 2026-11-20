; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): numbers as text and strings, in place of the 48K ROM's
; PRINT-FP, STR$, VAL, CHR$, string addition, the fixed-length LET and
; USR "a".  A string on the calculator stack: its address (D E) and length
; (B C), as STK-STORE puts them; its text in the workspace (BC-SPACES).
; Numbers to text and back: libux's @fstr and @fval (the Spectrum's
; format, 8 digits correctly rounded).  VAL reads a number (spaces and
; minus signs before it, spaces after), not an expression (VAL "2+3" stops
; the program, where the ROM would give 5): anything else stops
; the program (2 Variable not found with a letter in it, else C Nonsense in
; BASIC: the ROM's report can be the other, as it parses an expression);
; VAL$ is C.
        section text
        global @r2DE3,@r361F,@r35DC,@r35DE,@r359C,@r35D0,@r2B7F,@r34BC,@rstostr

; @rstostr (STK-STO-$): the string at DE, BC long, onto the stack.
@rstostr:
        ld hl,FLAGS
        res FL_NUM,(hl)
        xor a
        j @r2AB6

; @rtext: the top number off the stack, as text at @rbuf (NUL-ended) ->
; BC = its length.
@rtext: call @r35BF
        ld (STKEND),hl
        ld de,@rbuf
        call @fstr
        ld de,@rbuf
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ret

; PRINT-FP: the top number off the stack, printed as PRINT writes it.
@r2DE3: call @rtext
        ld hl,@rbuf
.l:     ld a,(hl)
        or a
        ret z
        push hl
        call @r10
        pop hl
        inc hl
        j .l

; STR$: the top number replaced by its text (in the workspace).
@r361F: call @rtext
        push bc
        call @r30               ; DE = the room
        pop bc
        push de
        push bc
        ld hl,@rbuf
        ldir
        pop bc
        pop de
        j @rstostr

; CHR$ (its last part): the character A as a string.  -> DE = STKEND.
@r35D0: push af
        ld bc,1
        call @r30
        pop af
        ld (de),a
        call @rstostr
        ex de,hl
        ret

; The strings a$, b$ on top replaced by a$ + b$.
@r359C: call @r2BF1             ; b$
        ld (@rxb),de
        ld (@rxbl),bc
        call @r2BF1             ; a$
        ld (@rxa),de
        ld (@rxal),bc
        ld hl,(@rxbl)
        add hl,bc
        ld b,h
        ld c,l
        ld (@rxl),bc
        call @r30               ; the room for both
        push de
        ld hl,(@rxa)
        ld bc,(@rxal)
        call .cp
        ld hl,(@rxb)
        ld bc,(@rxbl)
        call .cp
        pop de
        ld bc,(@rxl)
        j @rstostr
.cp:    ld a,b
        or c
        ret z
        ldir
        ret

; The fixed-length LET: the string on top off the stack, into the BC bytes
; at HL (cut short, or padded with spaces), through a copy in the
; workspace (the string may be those bytes).
@r2B7F: ld a,b
        or c
        ret z
        ld (@rxa),hl            ; the destination
        ld (@rxal),bc
        call @r30
        ld (@rxb),de            ; the copy, all spaces first
        ld h,d
        ld l,e
        ld bc,(@rxal)
        ld (hl),' '
        dec bc
        ld a,b
        or c
        j z,.f
        inc de
        ldir
.f:     call @r2BF1             ; the string: DE, BC
        ld hl,(@rxal)
        or a
        sbc hl,bc
        j nc,.k
        ld bc,(@rxal)           ; (longer: cut short)
.k:     ld a,b
        or c
        j z,.c
        ex de,hl
        ld de,(@rxb)
        ldir
.c:     ld hl,(@rxb)
        ld de,(@rxa)
        ld bc,(@rxal)
        ldir
        ret

; USR "a": the address of a user-defined graphic: the string on top (one
; letter A-U, either case, or the graphic's own character) replaced by it.
; A Invalid argument otherwise.
@r34BC: call @r2BF1
        dec bc
        ld a,b
        or c
        j nz,.bad
        ld a,(de)
        cp C_UDG
        j c,.let
        sub C_UDG
        cp UDG_N
        j nc,.bad
        j .ok
.let:   and ~20h & 0FFh         ; either case
        sub 'A'
        cp UDG_N
        j nc,.bad
.ok:    ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl               ; CELL bytes each
        ld bc,(UDG)
        add hl,bc
        ld b,h
        ld c,l
        j @r2D2B
.bad:   ld a,R_ARG
        jp @rerr

VP_INT  equ 0                   ; VAL's parts of a number (@rvpt); bit 0:
VP_FRAC equ 1                   ; spaces skipped in it
VP_EXP  equ 2
VP_ESGN equ 3

; VAL (B = V_VAL; VAL$ is not read): the string on top replaced by the
; number it writes.  @r35DC: B Integer out of range (the ROM's entry
; before VAL, which the runtime jumps to).
@r35DC: ld a,R_RANGE
        jp @rerr
@r35DE: ld a,b
        cp V_VAL
        j nz,.nons
        call @r2BF1             ; DE = the text, BC = its length
        ld a,VP_INT
        ld (@rvpt),a            ; the integer part first
        ld hl,@rvbuf
        ld (hl),0               ; minus signs (bit 0)
        inc hl
.lead:  call .next              ; spaces and minus signs before the number
        j c,.end
        cp ' '
        j z,.lead
        cp '-'
        j nz,.num
        push hl
        ld hl,@rvbuf
        inc (hl)
        pop hl
        j .lead
.num:   cp ' '                  ; the number: spaces in it as the ROM reads
        j nz,.nd                ; them - none in the digits before a point or
        ld a,(@rvpt)            ; in an exponent's, any after a point or an E
        rra                     ; (or the E's sign)
        j nc,.trail
        call .next
        j nc,.num
        j .end
.nd:    call .part

        push de
        push hl
        ld de,@rvbuf+1+VALMAX
        or a
        sbc hl,de
        pop hl
        pop de
        j nc,.nons
        ld (hl),a
        inc hl
        call .next
        j nc,.num
        j .end
.trail: call .next              ; spaces after it, nothing else
        j c,.end
        cp ' '
        j z,.trail
        ld (hl),a               ; (kept for .nons's look at it)
        inc hl
        ld (hl),0
        j .nons
.end:   ld (hl),0
        ld hl,@rvbuf+1
        ld de,@rvnum
        call @fval
        j c,.nons
        ld a,(hl)
        or a
        j nz,.nons              ; something after the number
        ld a,(@rvbuf)
        rra
        j nc,.pos
        ld hl,@rvnum
        ld b,h
        ld c,l
        ld a,F_NEG
        call @rfcall
.pos:   ld hl,@rvnum
        j @r33B4
; .part: the part of the number the character A starts, in @rvpt: a point
; starts the fraction, an E the exponent's sign, a digit after that its
; digits.  Keeps the registers.
.part:  push bc
        push af
        ld b,a
        ld a,(@rvpt)
        ld c,a
        ld a,b
        cp '.'
        j nz,.pe
        ld c,VP_FRAC
.pe:    and ~20h & 0FFh
        cp 'E'
        j nz,.pd
        ld c,VP_ESGN
.pd:    ld a,b
        cp '0'
        j c,.ps
        cp '9'+1
        j nc,.ps
        ld a,c
        cp VP_ESGN
        j nz,.ps
        ld c,VP_EXP
.ps:    ld a,c
        ld (@rvpt),a
        pop af
        pop bc
        ret
; .next: the text's next character -> A; CF: none left
.next:  ld a,b
        or c
        scf
        ret z
        ld a,(de)
        inc de
        dec bc
        or a
        ret
.nons:  ld hl,@rvbuf+1          ; not a number: with a letter in it, the
.nl:    ld a,(hl)               ; ROM would look for a variable (report 2),
        inc hl                  ; else C Nonsense in BASIC
        or a
        j z,.c
        and ~20h & 0FFh
        sub 'A'
        cp 'Z'-'A'+1
        j nc,.nl
        ld a,R_VAR
        jp @rerr
.c:     ld a,R_NONS
        jp @rerr

        section bss
@rbuf:  ds FSTRMAX
@rxa:   ds 2
@rxal:  ds 2
@rxb:   ds 2
@rxbl:  ds 2
@rxl:   ds 2
@rvbuf: ds 1+VALMAX+1
@rvnum: ds FNUM
@rvpt:  ds 1                    ; the part of the number read (VP_*)
