; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: the calculator stack and its arithmetic, in place of the 48K
; ROM's entry points the HiSoft runtime calls (@rNNNN: platform/basic.md).
;
; Clean room: each routine keeps the interface the runtime relies on -
; registers in and out, the stack of five-byte numbers between STKBOT and
; STKEND, ERR_NR and ERR_SP - written from that interface; the arithmetic
; is the platform's float engine (@rfcall, system call 42: platform/
; float.md).  Checked against the ROM's own routines, on the same inputs,
; by test/basic/romdiff.py.
        section text
        global @r08,@rerr,@r16BF,@r16C5,@rt5,@rroom
        global @r33B4,@r35BF,@r2BF1,@r2AB6,@r2D2B,@r2D7F,@r2DA2,@r3297
        global @r343C,@r34E9,@r350B,@r3492
        global @r3014,@r300F,@r30CA,@r31AD,@r31AF,@r3851
        global @r346E,@r346A,@r3214,@r36AF,@r36C4,@r3713,@r37AA,@r37B5,@r384A
        global @r28,@rint

; RST 8: the report whose number (less one) follows the call: ERR_NR,
; then the stack ERR_SP holds, the calculator stack emptied, and RET to
; the handler there.
@r08:   pop hl
        ld a,(hl)
@rerr:  ld (ERRNR),a
        ld hl,(CHADD)
        ld (XPTR),hl
        ld sp,(ERRSP)
        j @r16C5

; SET-WORK: the workspace emptied (STKBOT = WORKSP), then SET-STK: the
; calculator stack emptied (STKEND = STKBOT), MEM at MEMBOT.  -> HL = STKBOT.
@r16BF: ld hl,(WORKSP)
        ld (STKBOT),hl
@r16C5: ld hl,MEMBOT
        ld (MEMV),hl
        ld hl,(STKBOT)
        ld (STKEND),hl
        ret

; @rt5: room for one more number on the calculator stack, or report 4.
; @rroom: room for BC bytes.  Both keep DE, HL.
@rt5:   ld bc,FNUM
@rroom: push de
        push hl
        ld hl,(STKEND)
        add hl,bc
        j c,.full
        ld de,ROOM
        add hl,de
        j c,.full
        sbc hl,sp
        j nc,.full
        pop hl
        pop de
        ret
.full:  ld a,R_OOM
        jp @rerr

; STACK-NUM: the number at HL onto the stack -> HL past it, DE = STKEND.
@r33B4: call @rt5
        ld de,(STKEND)
        ldir
        ld (STKEND),de
        ret

; STK-PNTRS: HL = the top number, DE = STKEND.
@r35BF: ld hl,(STKEND)
        ld d,h
        ld e,l
        dec hl
        dec hl
        dec hl
        dec hl
        dec hl
        ret

; STK-FETCH: the top five bytes off the stack -> A, E, D, C, B; HL = STKEND.
@r2BF1: ld hl,(STKEND)
        dec hl
        ld b,(hl)
        dec hl
        ld c,(hl)
        dec hl
        ld d,(hl)
        dec hl
        ld e,(hl)
        dec hl
        ld a,(hl)
        ld (STKEND),hl
        ret

; STK-STORE: A, E, D, C, B onto the stack -> HL = STKEND; keeps BC, DE.
@r2AB6: push bc
        call @rt5
        pop bc
        ld hl,(STKEND)
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld (STKEND),hl
        ret

; STACK-BC: BC onto the stack as a small integer -> HL = it, DE = STKEND.
@r2D2B: xor a
        ld e,a
        ld d,c
        ld c,b
        ld b,a
        call @r2AB6
        j @r35BF

; INT-FETCH: the small integer at HL -> C = its sign byte, DE = its
; magnitude, A = D; HL at its last byte.
@r2D7F: inc hl
        ld c,(hl)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,c
        or a
        ld a,d
        ret z
        xor a
        sub e
        ld e,a
        ld a,0
        sbc a,d
        ld d,a
        ret

; FP-TO-BC: the top number off the stack, rounded (half up) -> BC = its
; magnitude, A = C; CF: it does not fit 16 bits; Z: it is not negative.
; DE = STKEND, HL = the number now on top.
@r2DA2: call @r35BF
        ld a,(hl)
        or a
        j z,.int
        push hl
        ld b,h                  ; x + 1/2
        ld c,l
        ld de,@chalf
        ld a,F_ADD
        call @rfcall
        pop hl
        call @rint              ; INT
.int:   ld (STKEND),hl
        ld a,(hl)
        ld (@rt1),a             ; its exponent byte: not 0, too big
        call @r2D7F             ; C sign, DE magnitude
        ld a,c
        ld (@rt1+1),a
        ld b,d
        ld c,e
        ld de,(STKEND)
        ld hl,-FNUM
        add hl,de
        ld a,(@rt1)
        or a
        ld a,(@rt1+1)
        j z,.fit
        and N_SIGN
        scf
        ld a,c
        ret
.fit:   and N_SIGN
        ld a,c
        ret

; RE-STACK: the small integer at HL in the full form (exponent, mantissa).
; Keeps BC, DE, HL; A = the exponent byte.
@r3297: ld a,(hl)
        or a
        ret nz
        push de
        push hl
        call @r2D7F             ; C sign, DE magnitude
        pop hl
        ld a,d
        or a
        j nz,.a
        ld a,e
.a:     push af                 ; A out: D, or E when D = 0
        ld a,d
        or e
        ld b,a
        j z,.st                 ; 0 (and -65536): all zero
        ld b,N_INT16
.sh:    bit 7,d
        j nz,.st
        ex de,hl
        add hl,hl
        ex de,hl
        dec b
        j .sh
.st:    push hl
        ld (hl),b               ; exponent, then the mantissa with the sign
        inc hl
        ld a,d
        and ~N_SIGN & 0FFh
        bit 7,c
        j z,.p
        or N_SIGN
.p:     ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        pop hl
        pop af
        pop de
        ret

; exchange: the five bytes at HL and at DE swapped -> HL, DE past them.
@r343C: ld b,FNUM
.l:     ld a,(de)
        ld c,(hl)
        ld (hl),a
        ld a,c
        ld (de),a
        inc hl
        inc de
        djnz .l
        ret

; TEST-ZERO: CF and Z if the number at HL is 0 (its first four bytes).
; Keeps A, BC, HL.
@r34E9: push hl
        push bc
        ld b,a
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        ld a,b
        pop bc
        pop hl
        ret nz
        scf
        ret

; The number at HL set to 1 if CF, else 0 (small integers).  Keeps CF, HL.
@r350B: push hl
        ld a,0
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        rla
        ld (hl),a
        rra
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        pop hl
        ret

; sgn: the number at HL replaced by -1, 0 or 1.  Keeps HL, DE.
@r3492: call @r34E9
        ret c
        push hl
        inc hl
        ld a,(hl)               ; the sign (bit 7, in either form)
        dec hl
        ld (hl),0
        inc hl
        rla
        sbc a,a
        ld c,a
        ld (hl),c
        inc hl
        or 1
        ld (hl),a
        inc hl
        ld (hl),c
        inc hl
        ld (hl),0
        pop hl
        ret

; The arithmetic: HL = x (the result's place), DE = y -> DE = HL + 5 (the
; new STKEND); 6 Number too big (A Invalid argument for x^y with x < 0)
; when there is no result.
@r3014: ld a,F_ADD
        j @rdy
@r300F: ld a,F_SUB
        j @rdy
@r30CA: ld a,F_MUL
        j @rdy
@r3851: call @r35BF             ; to-power: the stack's top two (a calculator
        ld (STKEND),hl          ; routine: no HL, DE) -> HL = the result on
        ld d,h                  ; top, DE = STKEND
        ld e,l
        ld bc,-FNUM
        add hl,bc
        ld a,F_POW
        call @rdy
        j @r35BF
@r31AD: ld a,R_BIG
        jp @rerr
@r31AF: ld a,F_DIV
@rdy:   push hl
        push af
        ld c,a                  ; the ROM's form for the result (whatever
        ld a,(de)               ; the engine's): full if either operand is
        or (hl)                 ; (exponent bytes not 0), or division, x^y
        ld b,a
        ld a,c
        cp F_DIV
        j c,.f
        ld b,1
.f:     ld a,b
        ld (@rfull),a
        pop af
        push af
        ld b,h
        ld c,l
        call @rfcall
        pop bc
        pop hl
        j c,.no
        call @rform
        ld de,FNUM
        ex de,hl
        add hl,de
        ex de,hl
        ret
.no:    ld a,b
        cp F_POW
        ld a,R_BIG
        jp nz,@rerr
        inc hl
        bit 7,(hl)              ; x^y, x < 0: A Invalid argument
        jp z,@rerr
        ld a,R_ARG
        jp @rerr

; The functions of one number: the number at HL replaced.  Keeps HL, DE.
@r346E: ld a,F_NEG
        j @rmo
@r346A: ld a,F_ABS
        j @rmo
@r3214: ld a,F_TRUNC
        j @rmo
; ... and those that are calculator routines in the ROM: the number on top
; of the stack, whatever HL -> HL = it, DE = STKEND.
@r36C4: ld a,F_EXP
        j @rso
@r37B5: ld a,F_SIN
        j @rso
@r37AA: ld a,F_COS
@rso:   push af
        call @r35BF
        pop af
        j @rmo
@r3713: ld a,F_LN
        j @rsa
@r384A: ld a,F_SQR
@rsa:   push af
        call @r35BF
        pop af
@rma:   ld c,R_ARG              ; no result
        j @rmc
@rmo:   ld c,R_BIG              ; no result
@rmc:   push af                 ; the ROM's form for the result: the
        cp F_EXP                ; operand's for negate, abs (truncate: the
        ld a,1                  ; engine's, small when whole); full for the
        j nc,.f                 ; functions (exp ... sqr)
        ld a,(hl)
.f:     ld (@rfull),a
        pop af
        cp F_TRUNC
        j nz,.t
        push af
        xor a
        ld (@rfull),a
        pop af
.t:     push hl
        push de
        push bc
        ld b,h
        ld c,l
        call @rfcall
        pop bc
        pop de
        pop hl
        j c,.no
        jp @rform
.no:    ld a,c
        jp @rerr

; @rform: the number at HL in the full form if @rfull is not 0 (RE-STACK):
; the ROM's arithmetic gives that, and the runtime reads it so (RND takes
; 16 off a result's exponent).  Keeps HL, DE, BC.
@rform: ld a,(@rfull)
        or a
        ret z
        jp @r3297

; int: the number on top of the stack (@r36AF, a calculator routine: HL =
; it, DE = STKEND), or at HL (@rint: keeps HL, DE), replaced by the whole
; number at or below it.
@r36AF: call @r35BF
@rint:  push hl
        push de
        ld de,@rt1              ; the number, kept
        ld bc,FNUM
        push hl
        ldir
        pop hl
        ld b,h
        ld c,l
        ld a,F_TRUNC
        call @rfcall
        ld a,(@rt1+1)
        ld e,a
        ld a,(@rt1)
        or a
        j nz,.f
        ld a,e                  ; small integers are whole
        j .done
.f:     bit 7,e
        j z,.done
        pop de                  ; negative: the truncation less 1 if it moved
        pop hl
        push hl
        push de
        ex de,hl
        ld hl,@rt1
        ld b,h
        ld c,l
        ld a,F_SUB              ; x - trunc(x) into @rt1
        call @rfcall
        ld hl,@rt1
        call @r34E9
        j c,.done
        pop de
        pop hl
        push hl
        push de
        ld b,h
        ld c,l
        ld de,@cone
        ld a,F_SUB
        call @rfcall
.done:  pop de
        pop hl
        ret

; RST 28h: the calculator, for the operations the runtime asks of it (the
; K_ names in rbc.inc; a comparison is B's, as in the ROM); end-calc -> HL
; = the top number, DE = STKEND.
@r28:   ld a,b
        ld (@rbreg),a           ; the comparisons' operation: B, as the runtime gives it
        pop hl
.l:     ld a,(hl)
        inc hl
        cp K_END
        j z,.end
        cp K_DATA
        j z,.dat
        push hl
        call .op
        pop hl
        j .l
.end:   push hl
        jp @r35BF
.dat:   call .data
        j .l
.op:    cp K_ONE
        j nz,.n1
        ld hl,@cone
        jp @r33B4
.n1:    cp K_PI2
        j nz,.n2
        ld hl,@cpi2
        jp @r33B4
.n2:    cp K_DUP
        j nz,.n3
        call @r35BF
        jp @r33B4
.n3:    cp K_DEL
        j nz,.n4
        call @r35BF
        ld (STKEND),hl
        ret
.n4:    cp K_ATN
        j nz,.n5
        call @r35BF
        ld a,F_ATN
        j @rmo
.n5:    cp K_MOD
        j z,.mod
        push af                 ; the operations of two
        call .p2
        pop af
        cp K_SUB
        j z,.sub
        cp K_MUL
        j z,.mul
        cp K_ADD
        j z,.add
        j nc,.bad
        cp K_CMP
        j c,.bad
        ld a,(@rbreg)           ; compare (09-0E): which comparison is B's
        sub K_CMP
        cp K_CMPN
        j nc,.bad
        push hl
        ld hl,.cmpt
        add a,l
        ld l,a
        ld a,0
        adc a,h
        ld h,a
        ld a,(hl)               ; which signs of x - y are true
        pop hl
        push af
        call @r300F
        ld (STKEND),de
        ld c,CMP_Z
        call @r34E9
        j c,.cs
        ld c,CMP_P
        inc hl
        bit 7,(hl)
        dec hl
        j z,.cs
        ld c,CMP_N
.cs:    pop af
        and c
        add a,0FFh              ; CF: true
        jp @r350B
.sub:   call @r300F
        ld (STKEND),de
        ret
.mul:   call @r30CA
        ld (STKEND),de
        ret
.add:   call @r3014
        ld (STKEND),de
        ret
.bad:   ld a,R_NONS             ; not an operation of ours
        jp @rerr
; n-mod-m: n, m -> n - m*INT(n/m), INT(n/m)
.mod:   call .p2
        push hl
        push de
        ld bc,@rt2              ; q = INT(n/m)
        ld a,F_DIV
        call @rfcall
        j c,.ovf
        ld hl,@rt2
        call @rint
        pop de                  ; @rt1 = q*m
        push de
        ld hl,@rt2
        ld bc,@rt1
        ld a,F_MUL
        call @rfcall
        pop de
        pop hl
        push de
        ld de,@rt1              ; n = n - q*m
        ld b,h
        ld c,l
        push hl
        ld a,F_SUB
        call @rfcall
        pop hl
        call @r3297             ; (both in the full form, as the ROM's)
        pop de                  ; m = q
        push de
        ld hl,@rt2
        ld bc,FNUM
        ldir
        pop hl
        jp @r3297
.ovf:   ld a,R_BIG
        jp @rerr
.p2:    call @r35BF             ; HL = x, DE = y
        ld d,h
        ld e,l
        ld bc,-FNUM
        add hl,bc
        ret
; stk-data: the number written after it (HL) onto the stack -> HL past it
.data:  ld a,(hl)
        inc hl
        ld b,a
        and K_DLEN
        rlca
        rlca
        inc a
        ld c,a                  ; mantissa bytes
        ld a,b
        and K_DEXP
        j nz,.e
        ld a,(hl)
        inc hl
.e:     add a,K_DBIAS
        ld de,@rt1
        ld (de),a
        inc de
        ld b,FNUM-1
.m:     ld a,c
        or a
        j z,.z
        ld a,(hl)
        inc hl
        dec c
        j .w
.z:     xor a
.w:     ld (de),a
        inc de
        djnz .m
        push hl
        ld hl,@rt1
        call @r33B4
        pop hl
        ret
.cmpt:  db CMP_Z|CMP_N,CMP_Z|CMP_P,CMP_N|CMP_P,CMP_P,CMP_N,CMP_Z   ; <= >= <> > < =


        section bss
@rt1:   ds FNUM
@rt2:   ds FNUM
@rbreg: ds 1
@rfull: ds 1
