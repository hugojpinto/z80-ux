; =====================================================================
; zx-ux: the float engine, a clean-room implementation of the ZX
; Spectrum's five-byte floating point (platform/float.md).
; =====================================================================
;
;  The interface (the same on every platform; the address comes from
;  system call 42):
;
;     A  = the operation         1 add   2 sub   3 mul   4 div   5 pow
;                                6 abs   7 neg   8 trunc 9 exp  10 ln
;                               11 sin  12 cos  13 tan  14 asin 15 acos
;                               16 atan 17 sqrt
;                               18 to integer: BC = |trunc x|, A = 0 (Z)
;                                  or FFh (NZ) for a negative x
;     HL = x, DE = y (1-5), BC = where the result goes (may be x)
;     IX = the caller's workspace, FPWS bytes
;  -> CF: no result (too big, outside the domain, division by zero).
;     Keeps IX, IY.
;
;  A number is five bytes: 00h, sign (00h or FFh), a 16-bit word (two's
;  complement), 00h - a small integer - or an exponent byte (bias 80h)
;  and a 32-bit mantissa 0.1m..m, high byte first, whose leading 1 holds
;  the sign.  Results that are whole numbers up to 65535 come back as
;  small integers.
;
;  Inside, a number is unpacked (U): sign (bit 7), a 16-bit exponent and
;  a 40-bit mantissa (8 guard bits), normalised.  add, sub, mul, div work
;  on two of them; the functions are written as steps of those (calc)
;  with series from mkfpk.py (fpk.inc).  This file is position
;  independent but for its own addresses (a module: fsmod.py), and keeps
;  no state of its own: everything is in the caller's workspace, so any
;  number of programs may use it at once.
; =====================================================================

; the workspace (IX)
W_FA    equ 0                   ; U: the accumulator
W_FB    equ 8                   ; U: the operand
W_P     equ 16                  ; 8: the product, the remainder
W_Q     equ 24                  ; 5: the quotient
W_SP    equ 29                  ; 2: SP at the entry (fperr)
W_R     equ 31                  ; 2: a primitive's result address
W_OP    equ 33                  ; 1
W_CS    equ 34                  ; 2: calc's step
W_PN    equ 36                  ; 1: poly: coefficients left
W_PP    equ 37                  ; 2: poly: the next one
W_PX    equ 39                  ; 2: poly: x
W_K     equ 41                  ; 1: sin/cos: the quadrant
W_K2    equ 42                  ; 1: flags
W_KE    equ 43                  ; 2: ln: the exponent; exp: the scale
W_PA    equ 45                  ; 5: poly's sum
T0      equ 50
T1      equ 55
T2      equ 60
T3      equ 65
T4      equ 70
T5      equ 75
T6      equ 80
U0      equ 85                  ; the functions that call functions
U1      equ 90
U2      equ 95
U3      equ 100
FPWS    equ 105                 ; the workspace's size

; U: sign, exponent (2), mantissa (5, low byte first)
U_S     equ 0
U_E     equ 1
U_M     equ 3

; calc's steps
S_ADD     equ 1
S_SUB     equ 2
S_MUL     equ 3
S_DIV     equ 4
S_MOV     equ 5
S_POLY    equ 6
S_TRUNC   equ 7

; ---------------------------------------------------------------------
fpent:  jp fpdo                 ; (the module's start: its entry)

fpdo:   push iy
        ld (ix+W_OP),a
        ld (ix+W_R),l           ; (HL, while SP is taken)
        ld (ix+W_R+1),h
        ld hl,0
        add hl,sp
        ld (ix+W_SP),l
        ld (ix+W_SP+1),h
        ld l,(ix+W_R)
        ld h,(ix+W_R+1)
        push hl
        ld hl,.ret              ; the operation returns here
        ex (sp),hl
        push hl
        ld a,(ix+W_OP)
        dec a
        cp 18
        jr nc,.bad
        add a,a
        ld hl,optab
        add a,l
        ld l,a
        jr nc,.n
        inc h
.n:     ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ex (sp),hl              ; HL back, the operation on the stack
        ret
.bad:   pop hl
        jp fperr
.ret:   pop iy
        ret

; fperr: no result: back to the caller from any depth, CF.
fperr:  ld l,(ix+W_SP)
        ld h,(ix+W_SP+1)
        ld sp,hl
        pop iy
        scf
        ret

optab:  dw fadd,fsub,fmul,fdiv,fpow,fabs,fneg,ftrunc,fexp,fln
        dw fsin,fcos,ftan,fasin,facos,fatan,fsqrt,ftoint

; ---------------------------------------------------------------------
; unpack: the number at HL into the U at IY.  Uses A, C, DE.
unpack: ld a,(hl)
        or a
        jr z,.int
        sub 80h
        ld (iy+U_E),a
        sbc a,a
        ld (iy+U_E+1),a
        inc hl
        ld a,(hl)
        and 80h
        ld (iy+U_S),a
        ld a,(hl)
        or 80h
        ld (iy+U_M+4),a
        inc hl
        ld a,(hl)
        ld (iy+U_M+3),a
        inc hl
        ld a,(hl)
        ld (iy+U_M+2),a
        inc hl
        ld a,(hl)
        ld (iy+U_M+1),a
        ld (iy+U_M),0
        ret
.int:   inc hl
        ld c,(hl)               ; 00h or FFh
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        xor a
        ld (iy+U_M),a
        ld (iy+U_M+1),a
        ld (iy+U_M+2),a
        ld (iy+U_E+1),a
        ld (iy+U_S),a
        ld (iy+U_E),16
        or c
        jr z,.p
        ld (iy+U_S),80h
        xor a                   ; DE = -DE: the magnitude
        sub e
        ld e,a
        ld a,0
        sbc a,d
        ld d,a
        or e
        jr nz,.p
        ld (iy+U_M+4),80h       ; -65536
        ld (iy+U_M+3),0
        ld (iy+U_E),17
        ret
.p:     ld (iy+U_M+4),d
        ld (iy+U_M+3),e
        ; (on into norm)

; norm: the U at IY normalised (mantissa's bit 39 set), or zero.
norm:   ld b,5
.by:    ld a,(iy+U_M+4)
        or a
        jr nz,.bi
        ld a,(iy+U_M+3)
        ld (iy+U_M+4),a
        ld a,(iy+U_M+2)
        ld (iy+U_M+3),a
        ld a,(iy+U_M+1)
        ld (iy+U_M+2),a
        ld a,(iy+U_M)
        ld (iy+U_M+1),a
        ld (iy+U_M),0
        ld l,(iy+U_E)
        ld h,(iy+U_E+1)
        ld de,-8
        add hl,de
        ld (iy+U_E),l
        ld (iy+U_E+1),h
        djnz .by
        ret                     ; zero
.bi:    bit 7,(iy+U_M+4)
        ret nz
        sla (iy+U_M)
        rl (iy+U_M+1)
        rl (iy+U_M+2)
        rl (iy+U_M+3)
        rl (iy+U_M+4)
        ld l,(iy+U_E)
        ld h,(iy+U_E+1)
        dec hl
        ld (iy+U_E),l
        ld (iy+U_E+1),h
        jr .bi

; uzero: Z if the U at IY is zero.
uzero:  ld a,(iy+U_M)
        or (iy+U_M+1)
        or (iy+U_M+2)
        or (iy+U_M+3)
        or (iy+U_M+4)
        ret

; pack: the U at IY, rounded, as a number at BC.  Too big: fperr.
pack:   ld h,b
        ld l,c
        call uzero
        jp z,.zero
        bit 7,(iy+U_M)          ; to 32 bits, to nearest
        jr z,.r
        inc (iy+U_M+1)
        jr nz,.r
        inc (iy+U_M+2)
        jr nz,.r
        inc (iy+U_M+3)
        jr nz,.r
        inc (iy+U_M+4)
        jr nz,.r
        ld (iy+U_M+4),80h
        ld e,(iy+U_E)
        ld d,(iy+U_E+1)
        inc de
        ld (iy+U_E),e
        ld (iy+U_E+1),d
.r:     ld e,(iy+U_E)
        ld d,(iy+U_E+1)
        ld a,d                  ; a whole number 1-65535: a small integer
        or a
        jr nz,.fl
        or e
        jr z,.fl
        cp 17
        jr nc,.fl
        ld a,(iy+U_M+1)
        or (iy+U_M+2)
        jr nz,.fl
        push hl
        ld h,(iy+U_M+4)
        ld l,(iy+U_M+3)
        ld a,16
        sub e
        jr z,.iv
        ld b,a
.sh:    srl h
        rr l
        jr c,.nf                ; a fraction
        djnz .sh
.iv:    ld a,(iy+U_S)
        or a
        jr z,.ip
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a
        ld a,0FFh
.ip:    ex de,hl
        pop hl
        ld (hl),0
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0
        or a
        ret
.nf:    pop hl
.fl:    ld a,e                  ; the exponent byte: 1-255
        add a,80h
        ld c,a
        ld a,d
        adc a,0
        jr nz,.big
        ld a,c
        or a
        jr z,.zero
        ld (hl),c
        inc hl
        ld a,(iy+U_M+4)
        and 7Fh
        or (iy+U_S)
        ld (hl),a
        inc hl
        ld a,(iy+U_M+3)
        ld (hl),a
        inc hl
        ld a,(iy+U_M+2)
        ld (hl),a
        inc hl
        ld a,(iy+U_M+1)
        ld (hl),a
        or a
        ret
.big:   rla                     ; below the smallest: zero
        jr c,.zero
        jp fperr                ; above the largest
.zero:  ld b,5
.z:     ld (hl),0
        inc hl
        djnz .z
        or a
        ret

; ---------------------------------------------------------------------
; The primitives: HL = x, DE = y, BC = the result.

; ld2: x into FA, y into FB, the result's address kept.
ld2:    ld (ix+W_R),c
        ld (ix+W_R+1),b
        push de
        push ix
        pop iy
        call unpack
        pop hl
        push ix
        pop iy
        ld de,W_FB
        add iy,de
        jp unpack

; ld1: x into FA, the result's address kept; IY = FA.
ld1:    ld (ix+W_R),c
        ld (ix+W_R+1),b
        push ix
        pop iy
        jp unpack

fadd:   call ld2
        call uadd
        jr pkfa
fsub:   call ld2
        ld a,(ix+W_FB+U_S)
        xor 80h
        ld (ix+W_FB+U_S),a
        call uadd
        jr pkfa
fmul:   call ld2
        call umul
        jr pkfa
fdiv:   call ld2
        call udiv
pkfa:   push ix
        pop iy
        ld c,(ix+W_R)
        ld b,(ix+W_R+1)
        jp pack

fabs:   call ld1
        ld (ix+W_FA+U_S),0
        jr pkfa
fneg:   call ld1
        ld a,(ix+W_FA+U_S)
        xor 80h
        ld (ix+W_FA+U_S),a
        jr pkfa

; ftrunc: toward zero.
ftrunc: call ld1
        call uzero
        jr z,pkfa
        ld e,(iy+U_E)
        ld d,(iy+U_E+1)
        bit 7,d
        jr nz,.z                ; below 1/2
        ld a,d
        or a
        jr nz,pkfa
        ld a,e
        or a
        jr z,.z                 ; below 1
        cp 40
        jr nc,pkfa              ; no fraction bits
        ld a,40                 ; the fraction's bits, from the bottom
        sub e
        ld b,a
        push iy
        pop hl
        ld de,U_M
        add hl,de
.by:    ld a,b
        cp 8
        jr c,.bi
        ld (hl),0
        inc hl
        ld a,b
        sub 8
        ld b,a
        jr .by
.bi:    or a
        jr z,pkfa
        ld a,0FFh
.m:     add a,a
        djnz .m
        and (hl)
        ld (hl),a
        jr pkfa
.z:     xor a
        ld (iy+U_M+4),a
        ld (iy+U_M+3),a
        ld (iy+U_M+2),a
        ld (iy+U_M+1),a
        ld (iy+U_M),a
        jr pkfa

; ftoint: HL = x -> BC = |trunc x|, A = 0 (Z) or FFh (NZ, x < 0).
ftoint: call toi
        ret nc
        jp fperr

; toi: as ftoint; CF if |trunc x| > 65535.
toi:    push ix
        pop iy
        call unpack
        call uzero
        jr z,.zero
        ld e,(iy+U_E)
        ld d,(iy+U_E+1)
        bit 7,d
        jr nz,.zero
        ld a,d
        or a
        jr nz,.big
        ld a,e
        or a
        jr z,.zero
        cp 17
        jr nc,.big
        ld h,(iy+U_M+4)
        ld l,(iy+U_M+3)
        ld a,16
        sub e
        jr z,.v
        ld b,a
.s:     srl h
        rr l
        djnz .s
.v:     ld b,h
        ld c,l
        ld a,(iy+U_S)
        or a
        ret z
        ld a,0FFh
        or a
        ret
.zero:  ld bc,0
        xor a
        ret
.big:   scf
        ret

; uadd: FA = FA + FB.
uadd:   push ix
        pop iy
        ld de,W_FB
        add iy,de
        call uzero
        ret z                   ; + 0
        push ix
        pop iy
        call uzero
        jr nz,.go
        push ix                 ; 0 + y: y
        pop hl
        ld d,h
        ld e,l
        ld bc,W_FB
        add hl,bc
        ld bc,8
        ldir
        ret
.go:    ld l,(ix+W_FA+U_E)
        ld h,(ix+W_FA+U_E+1)
        ld e,(ix+W_FB+U_E)
        ld d,(ix+W_FB+U_E+1)
        or a
        sbc hl,de
        bit 7,h
        jr z,.al
        push hl                 ; the larger into FA
        call uswap
        pop hl
        ld a,l
        cpl
        ld l,a
        ld a,h
        cpl
        ld h,a
        inc hl
.al:    ld a,h
        or a
        ret nz                  ; FB is too small to count
        ld a,l
        cp 41
        ret nc
        ld b,a                  ; FB's mantissa right by that
.sb:    ld a,b
        cp 8
        jr c,.sbi
        ld a,(ix+W_FB+U_M+1)
        ld (ix+W_FB+U_M),a
        ld a,(ix+W_FB+U_M+2)
        ld (ix+W_FB+U_M+1),a
        ld a,(ix+W_FB+U_M+3)
        ld (ix+W_FB+U_M+2),a
        ld a,(ix+W_FB+U_M+4)
        ld (ix+W_FB+U_M+3),a
        ld (ix+W_FB+U_M+4),0
        ld a,b
        sub 8
        ld b,a
        jr .sb
.sbi:   or a
        jr z,.sg
.sbl:   srl (ix+W_FB+U_M+4)
        rr (ix+W_FB+U_M+3)
        rr (ix+W_FB+U_M+2)
        rr (ix+W_FB+U_M+1)
        rr (ix+W_FB+U_M)
        djnz .sbl
.sg:    ld a,(ix+W_FA+U_S)
        xor (ix+W_FB+U_S)
        jp m,.sub
        ld a,(ix+W_FA+U_M)
        add a,(ix+W_FB+U_M)
        ld (ix+W_FA+U_M),a
        ld a,(ix+W_FA+U_M+1)
        adc a,(ix+W_FB+U_M+1)
        ld (ix+W_FA+U_M+1),a
        ld a,(ix+W_FA+U_M+2)
        adc a,(ix+W_FB+U_M+2)
        ld (ix+W_FA+U_M+2),a
        ld a,(ix+W_FA+U_M+3)
        adc a,(ix+W_FB+U_M+3)
        ld (ix+W_FA+U_M+3),a
        ld a,(ix+W_FA+U_M+4)
        adc a,(ix+W_FB+U_M+4)
        ld (ix+W_FA+U_M+4),a
        ret nc
        rr (ix+W_FA+U_M+4)      ; the carry in at the top
        rr (ix+W_FA+U_M+3)
        rr (ix+W_FA+U_M+2)
        rr (ix+W_FA+U_M+1)
        rr (ix+W_FA+U_M)
        ld l,(ix+W_FA+U_E)
        ld h,(ix+W_FA+U_E+1)
        inc hl
        ld (ix+W_FA+U_E),l
        ld (ix+W_FA+U_E+1),h
        ret
.sub:   ld a,(ix+W_FA+U_M)
        sub (ix+W_FB+U_M)
        ld (ix+W_FA+U_M),a
        ld a,(ix+W_FA+U_M+1)
        sbc a,(ix+W_FB+U_M+1)
        ld (ix+W_FA+U_M+1),a
        ld a,(ix+W_FA+U_M+2)
        sbc a,(ix+W_FB+U_M+2)
        ld (ix+W_FA+U_M+2),a
        ld a,(ix+W_FA+U_M+3)
        sbc a,(ix+W_FB+U_M+3)
        ld (ix+W_FA+U_M+3),a
        ld a,(ix+W_FA+U_M+4)
        sbc a,(ix+W_FB+U_M+4)
        ld (ix+W_FA+U_M+4),a
        jr nc,.n
        xor a                   ; below zero: the other way round
        sub (ix+W_FA+U_M)
        ld (ix+W_FA+U_M),a
        ld a,0
        sbc a,(ix+W_FA+U_M+1)
        ld (ix+W_FA+U_M+1),a
        ld a,0
        sbc a,(ix+W_FA+U_M+2)
        ld (ix+W_FA+U_M+2),a
        ld a,0
        sbc a,(ix+W_FA+U_M+3)
        ld (ix+W_FA+U_M+3),a
        ld a,0
        sbc a,(ix+W_FA+U_M+4)
        ld (ix+W_FA+U_M+4),a
        ld a,(ix+W_FA+U_S)
        xor 80h
        ld (ix+W_FA+U_S),a
.n:     push ix
        pop iy
        jp norm

; uswap: FA <-> FB.
uswap:  push ix
        pop hl
        ld d,h
        ld e,l
        ld bc,W_FB
        ex de,hl
        add hl,bc
        ex de,hl
        ld b,8
.l:     ld a,(de)
        ld c,(hl)
        ld (hl),a
        ld a,c
        ld (de),a
        inc hl
        inc de
        djnz .l
        ret

; fazero: FA = 0.
fazero: xor a
        ld (ix+W_FA+U_M),a
        ld (ix+W_FA+U_M+1),a
        ld (ix+W_FA+U_M+2),a
        ld (ix+W_FA+U_M+3),a
        ld (ix+W_FA+U_M+4),a
        ret

; uexp: FA's exponent + FB's (C = 0), or - FB's + 1 (C = 1); the sign
; is the two signs' product.
uexp:   ld a,(ix+W_FA+U_S)
        xor (ix+W_FB+U_S)
        ld (ix+W_FA+U_S),a
        ld l,(ix+W_FA+U_E)
        ld h,(ix+W_FA+U_E+1)
        ld e,(ix+W_FB+U_E)
        ld d,(ix+W_FB+U_E+1)
        dec c
        jr z,.d
        add hl,de
        jr .x
.d:     or a
        sbc hl,de
        inc hl
.x:     ld (ix+W_FA+U_E),l
        ld (ix+W_FA+U_E+1),h
        ret

; umul: FA = FA * FB (their top 32 bits; 64 bits of product, 40 kept).
umul:   push ix
        pop iy
        call uzero
        ret z
        ld de,W_FB
        add iy,de
        call uzero
        jr z,fazero
        ld c,0
        call uexp
        xor a
        ld b,8
        push ix
        pop hl
        ld de,W_P
        add hl,de
.c:     ld (hl),a
        inc hl
        djnz .c
        ld c,32
.l:     srl (ix+W_FB+U_M+4)     ; the multiplier's next bit
        rr (ix+W_FB+U_M+3)
        rr (ix+W_FB+U_M+2)
        rr (ix+W_FB+U_M+1)
        jr nc,.s
        ld a,(ix+W_P+4)
        add a,(ix+W_FA+U_M+1)
        ld (ix+W_P+4),a
        ld a,(ix+W_P+5)
        adc a,(ix+W_FA+U_M+2)
        ld (ix+W_P+5),a
        ld a,(ix+W_P+6)
        adc a,(ix+W_FA+U_M+3)
        ld (ix+W_P+6),a
        ld a,(ix+W_P+7)
        adc a,(ix+W_FA+U_M+4)
        ld (ix+W_P+7),a
.s:     rr (ix+W_P+7)
        rr (ix+W_P+6)
        rr (ix+W_P+5)
        rr (ix+W_P+4)
        rr (ix+W_P+3)
        rr (ix+W_P+2)
        rr (ix+W_P+1)
        rr (ix+W_P)
        dec c
        jr nz,.l
        ld a,(ix+W_P+3)
        ld (ix+W_FA+U_M),a
        ld a,(ix+W_P+4)
        ld (ix+W_FA+U_M+1),a
        ld a,(ix+W_P+5)
        ld (ix+W_FA+U_M+2),a
        ld a,(ix+W_P+6)
        ld (ix+W_FA+U_M+3),a
        ld a,(ix+W_P+7)
        ld (ix+W_FA+U_M+4),a
        push ix
        pop iy
        jp norm

; udiv: FA = FA / FB (40 quotient bits).  / 0: fperr.
udiv:   push ix
        pop iy
        ld de,W_FB
        add iy,de
        call uzero
        jp z,fperr
        push ix
        pop iy
        call uzero
        ret z
        ld c,1
        call uexp
        ld a,(ix+W_FA+U_M+1)    ; the remainder: FA's top 32 bits
        ld (ix+W_P),a
        ld a,(ix+W_FA+U_M+2)
        ld (ix+W_P+1),a
        ld a,(ix+W_FA+U_M+3)
        ld (ix+W_P+2),a
        ld a,(ix+W_FA+U_M+4)
        ld (ix+W_P+3),a
        xor a
        ld (ix+W_P+4),a
        ld (ix+W_Q),a
        ld (ix+W_Q+1),a
        ld (ix+W_Q+2),a
        ld (ix+W_Q+3),a
        ld (ix+W_Q+4),a
        ld c,40
.l:     ld a,(ix+W_P)           ; remainder - divisor ...
        sub (ix+W_FB+U_M+1)
        ld (ix+W_P),a
        ld a,(ix+W_P+1)
        sbc a,(ix+W_FB+U_M+2)
        ld (ix+W_P+1),a
        ld a,(ix+W_P+2)
        sbc a,(ix+W_FB+U_M+3)
        ld (ix+W_P+2),a
        ld a,(ix+W_P+3)
        sbc a,(ix+W_FB+U_M+4)
        ld (ix+W_P+3),a
        ld a,(ix+W_P+4)
        sbc a,0
        ld (ix+W_P+4),a
        jr nc,.one
        ld a,(ix+W_P)           ; ... too much: back
        add a,(ix+W_FB+U_M+1)
        ld (ix+W_P),a
        ld a,(ix+W_P+1)
        adc a,(ix+W_FB+U_M+2)
        ld (ix+W_P+1),a
        ld a,(ix+W_P+2)
        adc a,(ix+W_FB+U_M+3)
        ld (ix+W_P+2),a
        ld a,(ix+W_P+3)
        adc a,(ix+W_FB+U_M+4)
        ld (ix+W_P+3),a
        ld a,(ix+W_P+4)
        adc a,0
        ld (ix+W_P+4),a
        or a
        jr .q
.one:   scf
.q:     rl (ix+W_Q)
        rl (ix+W_Q+1)
        rl (ix+W_Q+2)
        rl (ix+W_Q+3)
        rl (ix+W_Q+4)
        sla (ix+W_P)
        rl (ix+W_P+1)
        rl (ix+W_P+2)
        rl (ix+W_P+3)
        rl (ix+W_P+4)
        dec c
        jp nz,.l
        ld a,(ix+W_Q)
        ld (ix+W_FA+U_M),a
        ld a,(ix+W_Q+1)
        ld (ix+W_FA+U_M+1),a
        ld a,(ix+W_Q+2)
        ld (ix+W_FA+U_M+2),a
        ld a,(ix+W_Q+3)
        ld (ix+W_FA+U_M+3),a
        ld a,(ix+W_Q+4)
        ld (ix+W_FA+U_M+4),a
        push ix
        pop iy
        jp norm

; ---------------------------------------------------------------------
; calc: the steps after the call, four bytes each (step, r, a, b), up to
; a 0: r = a + b, a - b, a * b, a / b; r = a (MOV); r = the series b at
; a (POLY); r = trunc a (TRUNC).  r, a, b: a workspace offset, or 80h +
; n: constant n (fpk.inc).
calc:   pop hl
.n:     ld a,(hl)
        inc hl
        or a
        jr z,.x
        ld (ix+W_OP),a
        ld a,(hl)
        inc hl
        call opad
        push de                 ; r
        ld a,(hl)
        inc hl
        call opad
        push de                 ; a
        ld a,(hl)
        inc hl
        ld (ix+W_CS),l
        ld (ix+W_CS+1),h
        ld e,a
        ld a,(ix+W_OP)
        cp S_POLY
        jr z,.poly
        ld a,e
        call opad               ; b
        pop hl
        pop bc
        ld a,(ix+W_OP)
        call .do
.c:     ld l,(ix+W_CS)
        ld h,(ix+W_CS+1)
        jr .n
.x:     jp (hl)
.poly:  ld a,e
        add a,a
        ld hl,fpptab
        add a,l
        ld l,a
        jr nc,.pn
        inc h
.pn:    ld e,(hl)
        inc hl
        ld d,(hl)
        pop hl
        pop bc
        call poly
        jr .c
.do:    dec a
        jp z,fadd
        dec a
        jp z,fsub
        dec a
        jp z,fmul
        dec a
        jp z,fdiv
        dec a
        jr z,.mov
        jp ftrunc
.mov:   ld d,b
        ld e,c
        ld bc,5
        ldir
        ret

; opad: operand A -> DE = its address.  Keeps HL, BC.
opad:   push hl
        bit 7,a
        jr nz,.k
        push ix
        pop hl
        ld e,a
        ld d,0
        add hl,de
        ex de,hl
        pop hl
        ret
.k:     and 7Fh
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de
        ld de,fpk
        add hl,de
        ex de,hl
        pop hl
        ret

; poly: HL = x, DE = a series (count, then coefficients from the highest
; degree), BC = the result: Horner.
poly:   push bc
        ld (ix+W_PX),l
        ld (ix+W_PX+1),h
        ld a,(de)
        ld (ix+W_PN),a
        inc de
        ex de,hl
        push ix
        pop de
        ld a,W_PA
        call addde
        ld bc,5
        ldir
        ld (ix+W_PP),l
        ld (ix+W_PP+1),h
.l:     dec (ix+W_PN)
        jr z,.e
        call .pa
        ld e,(ix+W_PX)
        ld d,(ix+W_PX+1)
        call fmul               ; sum * x
        call .pa
        ld e,(ix+W_PP)
        ld d,(ix+W_PP+1)
        call fadd               ; + the next coefficient
        ld l,(ix+W_PP)
        ld h,(ix+W_PP+1)
        ld de,5
        add hl,de
        ld (ix+W_PP),l
        ld (ix+W_PP+1),h
        jr .l
.e:     pop de
        push ix
        pop hl
        ld bc,W_PA
        add hl,bc
        ld bc,5
        ldir
        ret
.pa:    push ix                 ; HL = BC = the sum
        pop hl
        ld bc,W_PA
        add hl,bc
        ld b,h
        ld c,l
        ret

; addde: DE = DE + A.
addde:  add a,e
        ld e,a
        ret nc
        inc d
        ret

; wsa: A = a workspace offset -> HL = its address.  Keeps BC, DE.
wsa:    push de
        push ix
        pop hl
        ld e,a
        ld d,0
        add hl,de
        pop de
        ret

; cpin: the number at HL to workspace offset A.  Keeps BC, DE.
cpin:   push bc
        push de
        push hl
        call wsa
        ex de,hl
        pop hl
        ld bc,5
        ldir
        pop de
        pop bc
        ret

; cpout: workspace offset A to the number at BC.
cpout:  call wsa
        ld d,b
        ld e,c
        ld bc,5
        ldir
        or a
        ret

; tsgn: workspace offset A -> Z: zero; else S (M): below zero.
tsgn:   call wsa
        ld a,(hl)
        or a
        jr nz,.f
        inc hl
        ld c,(hl)
        inc hl
        ld a,(hl)
        inc hl
        or (hl)
        ret z
        ld a,c
        or 1                    ; NZ, S from the sign byte
        ret
.f:     inc hl
        ld a,(hl)
        or 1
        ret

; mkint: HL (a signed 16-bit number) to workspace offset A.
mkint:  push hl
        call wsa
        pop de
        ld (hl),0
        inc hl
        ld a,d
        rla
        sbc a,a
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0
        ret

; uscale: the number at workspace offset A, times 2^HL, to BC.
uscale: push hl
        push bc
        call wsa
        push ix
        pop iy
        call unpack
        pop bc
        pop de
        call uzero
        jp z,pack
        ld l,(iy+U_E)
        ld h,(iy+U_E+1)
        add hl,de
        ld (iy+U_E),l
        ld (iy+U_E+1),h
        jp pack

; rnd: T2 = T1 rounded to a whole number (half away from zero).
rnd:    ld a,T1
        call tsgn
        jp m,.n
        call calc
        db S_ADD,T2,T1,C_HALF, S_TRUNC,T2,T2,0, 0
        ret
.n:     call calc
        db S_SUB,T2,T1,C_HALF, S_TRUNC,T2,T2,0, 0
        ret

; ---------------------------------------------------------------------
; The functions: HL = x, BC = the result.

; e^x = 2^n e^r: n = round(x / ln 2), r = x - n ln 2 (in two parts).
fexp:   push bc
        ld a,T0
        call cpin
        call calc
        db S_MUL,T1,T0,C_INVLN2, 0
        call rnd
        ld a,T2
        call wsa
        call toi
        jr c,.far
        ld a,b                  ; n beyond 255: 0 or too big
        or a
        jr nz,.far
        ld l,c
        ld h,b
        call tsgnn              ; HL = n with its sign
        ld (ix+W_KE),l
        ld (ix+W_KE+1),h
        call calc
        db S_MUL,T3,T2,C_LN2HI, S_SUB,T4,T0,T3, S_MUL,T3,T2,C_LN2LO, S_SUB,T4,T4,T3
        db S_POLY,T5,T4,P_EXP, 0
        pop bc
        ld l,(ix+W_KE)
        ld h,(ix+W_KE+1)
        ld a,T5
        jp uscale
.far:   ld a,T0
        call tsgn
        jp p,fperr              ; too big
        pop bc                  ; too small: 0
        ld a,C_ZERO
.z:     ld hl,fpk
        ld d,b
        ld e,c
        ld bc,5
        ldir
        or a
        ret

; tsgnn: HL = a magnitude, the sign of T2 -> HL signed.
tsgnn:  ld a,T2
        push hl
        call tsgn
        pop hl
        ret p
        ld a,l
        cpl
        ld l,a
        ld a,h
        cpl
        ld h,a
        inc hl
        ret

; ln x = ln m + e ln 2, x = m 2^e, m in [0.7, 1.4): ln m by its series.
fln:    push bc
        push ix
        pop iy
        call unpack
        call uzero
        jp z,fperr
        ld a,(iy+U_S)
        or a
        jp nz,fperr
        ld l,(iy+U_E)
        ld h,(iy+U_E+1)
        xor a
        ld (iy+U_E),a
        ld (iy+U_E+1),a
        ld a,(iy+U_M+4)         ; m below 0.7071: 2m, e - 1
        cp 0B5h
        jr nc,.k
        inc (iy+U_E)
        dec hl
.k:     ld (ix+W_KE),l
        ld (ix+W_KE+1),h
        push ix
        pop hl
        ld bc,T0
        add hl,bc
        ld b,h
        ld c,l
        call pack
        call calc
        db S_SUB,T1,T0,C_ONE, S_ADD,T2,T0,C_ONE, S_DIV,T1,T1,T2, S_MUL,T2,T1,T1
        db S_POLY,T3,T2,P_LN, S_MUL,T3,T3,T1, 0
        ld l,(ix+W_KE)
        ld h,(ix+W_KE+1)
        ld a,T4
        call mkint
        call calc
        db S_MUL,T5,T4,C_LN2LO, S_ADD,T3,T3,T5, S_MUL,T5,T4,C_LN2HI, S_ADD,T3,T3,T5, 0
        pop bc
        ld a,T3
        jp cpout

; sqrt x: Newton from x with its exponent halved.
fsqrt:  push bc
        ld a,T0
        call cpin
        ld a,T0
        call wsa
        push ix
        pop iy
        call unpack
        call uzero
        jr z,.z
        ld a,(iy+U_S)
        or a
        jp nz,fperr
        ld l,(iy+U_E)
        ld h,(iy+U_E+1)
        inc hl
        sra h
        rr l
        ld (iy+U_E),l
        ld (iy+U_E+1),h
        push ix
        pop hl
        ld bc,T1
        add hl,bc
        ld b,h
        ld c,l
        call pack
        ld b,6
.l:     push bc
        call calc
        db S_DIV,T2,T0,T1, S_ADD,T1,T1,T2, S_MUL,T1,T1,C_HALF, 0
        pop bc
        djnz .l
        pop bc
        ld a,T1
        jp cpout
.z:     pop bc
        ld a,T0
        jp cpout

; sin, cos: x = q pi/2 + r, |r| <= pi/4; by q's last two bits, sin r,
; cos r, - sin r, - cos r.
fsin:   xor a
        jr fsc
fcos:   ld a,1
fsc:    ld (ix+W_K),a
        push bc
        ld a,T0
        call cpin
        call calc
        db S_MUL,T1,T0,C_TWOOPI, 0
        call rnd
        ld a,T2
        call wsa
        call toi                ; q's last bits (beyond 65535: 0)
        ld a,c
        jr nc,.q
        xor a
.q:     jr z,.qp
        neg
.qp:    add a,(ix+W_K)
        and 3
        ld (ix+W_K),a
        call calc
        db S_MUL,T3,T2,C_PIO2HI, S_SUB,T4,T0,T3, S_MUL,T3,T2,C_PIO2MI, S_SUB,T4,T4,T3
        db S_MUL,T3,T2,C_PIO2LO, S_SUB,T4,T4,T3, S_MUL,T5,T4,T4, 0
        bit 0,(ix+W_K)
        jr nz,.c
        call calc
        db S_POLY,T6,T5,P_SIN, S_MUL,T6,T6,T4, 0
        jr .s
.c:     call calc
        db S_POLY,T6,T5,P_COS, 0
.s:     bit 1,(ix+W_K)
        jr z,.o
        call calc
        db S_SUB,T6,C_ZERO,T6, 0
.o:     pop bc
        ld a,T6
        jp cpout

ftan:   push bc
        ld a,U0
        call cpin
        call .u0
        ld bc,U1
        call .ws
        call fsin
        call .u0
        ld bc,U2
        call .ws
        call fcos
        call calc
        db S_DIV,U1,U1,U2, 0
        pop bc
        ld a,U1
        jp cpout
.u0:    ld a,U0
        jp wsa
; .ws: BC = the workspace's address + BC.  Keeps HL.
.ws:    push hl
        push ix
        pop hl
        add hl,bc
        ld b,h
        ld c,l
        pop hl
        ret

; atan: |x| > 1: pi/2 - atan(1/|x|); then t > tan 15: pi/6 +
; atan((t sqrt 3 - 1)/(t + sqrt 3)); then the series.
fatan:  push bc
        ld a,T0
        call cpin
        ld (ix+W_K2),0
        ld a,T0
        call tsgn
        jp p,.p
        set 7,(ix+W_K2)
        call calc
        db S_SUB,T0,C_ZERO,T0, 0
.p:     call calc
        db S_SUB,T1,C_ONE,T0, 0
        ld a,T1
        call tsgn
        jp p,.le1
        set 0,(ix+W_K2)
        call calc
        db S_DIV,T0,C_ONE,T0, 0
.le1:   call calc
        db S_SUB,T1,C_TAN15,T0, 0
        ld a,T1
        call tsgn
        jp p,.sm
        set 1,(ix+W_K2)
        call calc
        db S_MUL,T1,T0,C_SQRT3, S_SUB,T1,T1,C_ONE, S_ADD,T2,T0,C_SQRT3, S_DIV,T0,T1,T2, 0
.sm:    call calc
        db S_MUL,T1,T0,T0, S_POLY,T2,T1,P_ATAN, S_MUL,T2,T2,T0, 0
        bit 1,(ix+W_K2)
        jr z,.a
        call calc
        db S_ADD,T2,T2,C_PI6, 0
.a:     bit 0,(ix+W_K2)
        jr z,.b
        call calc
        db S_SUB,T2,C_PIO2,T2, 0
.b:     bit 7,(ix+W_K2)
        jr z,.o
        call calc
        db S_SUB,T2,C_ZERO,T2, 0
.o:     pop bc
        ld a,T2
        jp cpout

; asin x = atan(x / sqrt((1 - x)(1 + x))); |x| = 1: +- pi/2.
fasin:  push bc
        ld a,U0
        call cpin
        call calc
        db S_SUB,U1,C_ONE,U0, S_ADD,U2,C_ONE,U0, S_MUL,U1,U1,U2, 0
        ld a,U1
        call tsgn
        jp m,fperr
        jr nz,.g
        call calc
        db S_MOV,U2,C_PIO2,0, 0
        ld a,U0
        call tsgn
        jp p,.o
        call calc
        db S_SUB,U2,C_ZERO,U2, 0
        jr .o
.g:     ld a,U1
        call wsa
        ld bc,U2
        call ftan.ws
        call fsqrt
        call calc
        db S_DIV,U1,U0,U2, 0
        ld a,U1
        call wsa
        ld bc,U2
        call ftan.ws
        call fatan
.o:     pop bc
        ld a,U2
        jp cpout

; acos x = pi/2 - asin x.
facos:  push bc
        ld bc,U3
        call ftan.ws
        call fasin
        call calc
        db S_SUB,U3,C_PIO2,U3, 0
        pop bc
        ld a,U3
        jp cpout

; pow: x^y.  x < 0: no result (as the Spectrum); 0^0 = 1, 0^y = 0
; (y > 0); a whole y up to 255: by squaring (exact where it can be);
; else e^(y ln x).
fpow:   push bc
        ld a,U0
        call cpin
        ex de,hl
        ld a,U1
        call cpin
        ld a,U0
        call tsgn
        jp m,fperr
        jr nz,.pos
        ld a,U1
        call tsgn
        jp m,fperr
        ld a,C_ONE
        jr z,.k
        ld a,C_ZERO
.k:     pop bc
        call opad
        ex de,hl
        ld d,b
        ld e,c
        ld bc,5
        ldir
        or a
        ret
.pos:   call calc
        db S_TRUNC,U2,U1,0, S_SUB,U2,U2,U1, 0
        ld a,U2
        call tsgn
        jr nz,.gen              ; y has a fraction
        ld a,U1
        call wsa
        call toi
        jr c,.gen
        ld a,b
        or a
        jr nz,.gen
        ld (ix+W_K),c           ; |y|
        ld (ix+W_K2),0          ; y < 0: 1 / the result
        ld a,U1
        call tsgn
        jp p,.yp
        ld (ix+W_K2),1
.yp:
        call calc
        db S_MOV,U2,C_ONE,0, 0
.sq:    ld a,(ix+W_K)
        or a
        jr z,.done
        srl (ix+W_K)
        jr nc,.nm
        call calc
        db S_MUL,U2,U2,U0, 0
.nm:    ld a,(ix+W_K)
        or a
        jr z,.done
        call calc
        db S_MUL,U0,U0,U0, 0
        jr .sq
.done:  ld a,(ix+W_K2)
        or a
        jr z,.o
        call calc
        db S_DIV,U2,C_ONE,U2, 0
        jr .o
.gen:   ld a,U0
        call wsa
        ld bc,U2
        call ftan.ws
        call fln
        call calc
        db S_MUL,U2,U2,U1, 0
        ld a,U2
        call wsa
        ld b,h
        ld c,l
        call fexp
.o:     pop bc
        ld a,U2
        jp cpout

        include "fpk.inc"
fpend:
