; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; z80-ux: numbers to text and back, in the program (platform/float.md).
;
; @fstr  HL = a five-byte number, DE = a buffer (14 bytes) -> the number
;        there as the Spectrum's PRINT writes it, NUL-ended; HL = the NUL.
;        8 significant digits, correctly rounded (half up); trailing zeros
;        dropped; "0.5", ".05", "1E+8", "1.5E-7": plain from 1E-5 to
;        99999999, E form beyond.
; @fval  HL = text: digits, a point, digits, then E, a sign and digits ->
;        the number at DE (small-integer form when whole and below 65536);
;        HL = the first character after it.  CF: no digits, or too big.
;        Up to 9 significant digits count; tiny values become 0.
; ftoa(float x, char *buf) -> buf;  atof(char *s) -> the number (0 when
; there is none), after spaces and a sign.
;
; Clean room: written from the format's definition, with exact integer
; arithmetic on a 208-bit number (@fsb); no ROM code, no float engine
; (atof's minus sign aside).  Tested against the ROM's PRINT-FP and exact
; values: test/fp/strtest.py.
BN      equ 26
        section text
        global @fstr,@fval,_ftoa,_atof

; ftoa(float x, char *buf): buf in HL, x's address on the stack.
_ftoa:  pop bc
        pop de
        push bc
        push hl
        ex de,hl
        call @fstr
        pop hl
        ret

; atof(char *s): HL = s -> HL = the number (@fac).
_atof:
.sp:    ld a,(hl)
        cp ' '
        jr nz,.sg
        inc hl
        jr .sp
.sg:    ld c,0
        cp '-'
        jr nz,.pl
        inc c
        jr .ad
.pl:    cp '+'
        jr nz,.go
.ad:    inc hl
.go:    push bc
        ld de,@fac
        call @fval
        pop bc
        ld hl,@fac
        jr nc,.ok
        ld b,5
.z:     ld (hl),0
        inc hl
        djnz .z
        ld hl,@fac
        ret
.ok:    bit 0,c
        ret z
        ld a,7                  ; the engine's negate
        call @fop
        ld hl,@fac
        ret

; @fstr: see above.
@fstr:  ld (@fsd),de
        xor a
        ld (@fss),a
        ld a,(hl)
        or a
        jr nz,.full
        inc hl                  ; the small-integer form: 0, sign, value, 0
        ld a,(hl)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        or a
        jr z,.pos
        ld a,80h
        ld (@fss),a
        ld hl,0
        or a
        sbc hl,de
        ex de,hl
        ld a,d
        or e
        jr nz,.pos
        ld hl,0                 ; -65536
        ld (@fsm),hl
        ld h,80h
        ld (@fsm+2),hl
        ld a,145
        jr .nrm
.pos:   ld a,d
        or e
        jr nz,.int
        ld a,'0'
        call .put
        jp .end
.int:   ld a,(@fss)             ; whole, below 65536: its digits directly
        or a
        ld a,'-'
        call nz,.put
        ex de,hl
        ld c,0                  ; C: a digit written
        ld de,-10000
        call .d16
        ld de,-1000
        call .d16
        ld de,-100
        call .d16
        ld de,-10
        call .d16
        ld a,l
        add a,'0'
        call .put
        jp .end
.d16:   ld a,'0'-1              ; one digit of HL: HL / -DE
.dl:    inc a
        add hl,de
        jr c,.dl
        sbc hl,de
        cp '0'
        jr nz,.dw
        bit 0,c
        ret z
.dw:    ld c,1
        jp .put
.full:  ld (@fse),a             ; exponent, then the mantissa, low byte first
        inc hl
        ld a,(hl)
        and 80h
        ld (@fss),a
        ld a,(hl)
        or 80h
        ld (@fsm+3),a
        inc hl
        ld a,(hl)
        ld (@fsm+2),a
        inc hl
        ld a,(hl)
        ld (@fsm+1),a
        inc hl
        ld a,(hl)
        ld (@fsm),a
        jr .sgn
.nrm:   ld (@fse),a             ; shift the mantissa up to its top bit
.nl:    ld a,(@fsm+3)
        rla
        jr c,.sgn
        ld hl,@fsm
        sla (hl)
        inc hl
        rl (hl)
        inc hl
        rl (hl)
        inc hl
        rl (hl)
        ld hl,@fse
        dec (hl)
        jr .nl
.sgn:   ld a,(@fss)
        or a
        ld a,'-'
        call nz,.put
; the number is M * 2^(E-160), M 32 bits; its decimal exponent e (the
; number is 0.d1d2... * 10^e) is first guessed as (E-129)*log10(2) + 1.
        ld a,(@fse)
        sub 129
        ld l,a
        rla
        sbc a,a
        ld h,a
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        push hl                 ; 4x
        add hl,hl
        push hl                 ; 8x
        add hl,hl
        add hl,hl
        add hl,hl               ; 64x
        pop bc
        add hl,bc
        pop bc
        add hl,bc
        add hl,de               ; 77x: 77/256 = log10(2), a little under
        ld a,h
        inc a
        ld (@fsk),a
; Q = floor(2 * x * 10^(8-e)), exactly: M, times 10 (8-e) times, shifted by
; E-159, divided by 10 (e-8) times.  Nested floors are exact.
.try:   call @bclr
        ld hl,@fsm
        ld de,@fsb
        ld bc,4
        ldir
        ld a,(@fsk)
        ld c,a
        ld a,8
        sub c
        jp m,.sh
        call @bmn
.sh:    ld a,(@fse)
        sub 159
        jr c,.rt
        call @bshln
        jr .dv
.rt:    neg
        call @bshrn
.dv:    ld a,(@fsk)
        sub 8
        jp m,.got
        call @bdn
.got:   ld hl,@fsb+4            ; 10^7 <= Q/2 < 10^8, or guess again
        ld b,BN-4
        xor a
.gz:    or (hl)
        inc hl
        djnz .gz
        jr nz,.up
        call @bshr              ; T = Q/2; CF: the half
        push af
        ld de,@c1e8
        call @bcmp
        jr nc,.upp
        ld de,@c1e7
        call @bcmp
        jr c,.dnp
        pop af
        ld a,0
        adc a,a
        call nz,@badd           ; rounded: T + the half
        ld de,@c1e8
        call @bcmp
        jr c,.dig
        ld hl,@c1e7             ; 99999999.5 -> 1E+8
        ld de,@fsb
        ld bc,4
        ldir
        ld hl,@fsk
        inc (hl)
        jr .dig
.upp:   pop af
.up:    ld hl,@fsk
        inc (hl)
        jp .try
.dnp:   pop af
        ld hl,@fsk
        dec (hl)
        jp .try
.dig:   ld hl,@fsg+7            ; the 8 digits
        ld b,8
.dg:    push bc
        push hl
        call @bd10
        pop hl
        ld (hl),a
        dec hl
        pop bc
        djnz .dg
        ld hl,@fsg+7            ; C = how many, trailing zeros dropped
        ld c,8
.nd:    ld a,(hl)
        or a
        jr nz,.fmt
        dec hl
        dec c
        jr .nd
.fmt:   ld a,(@fsk)
        add a,4
        cp 13
        jr nc,.ef               ; e outside -4..8: E form
        ld a,(@fsk)
        or a
        jr z,.z0
        jp m,.fr
        ld b,a                  ; 1 <= e <= 8: digits, the point after e
        ld hl,@fsg
        ld d,0
.pl:    ld a,d
        cp b
        jr nz,.np
        ld a,'.'
        call .put
.np:    ld a,(hl)
        add a,'0'
        call .put
        inc hl
        inc d
        ld a,d
        cp b
        jr c,.pl
        cp c
        jr c,.pl
        jr .end
.z0:    ld a,'0'
        call .put
.fr:    ld a,'.'                ; e <= 0: ".", -e zeros, the digits
        call .put
        ld a,(@fsk)
        neg
        jr z,.fd
        ld b,a
.fz:    ld a,'0'
        call .put
        djnz .fz
.fd:    ld hl,@fsg
        ld b,c
.fl:    ld a,(hl)
        add a,'0'
        call .put
        inc hl
        djnz .fl
        jr .end
.ef:    ld hl,@fsg              ; d.dddE+x
        ld a,(hl)
        add a,'0'
        call .put
        ld a,c
        dec a
        jr z,.ex
        ld b,a
        ld a,'.'
        call .put
.el:    inc hl
        ld a,(hl)
        add a,'0'
        call .put
        djnz .el
.ex:    ld a,'E'
        call .put
        ld a,(@fsk)
        dec a
        ld b,'+'
        jp p,.ep
        neg
        ld b,'-'
.ep:    ld c,a
        ld a,b
        call .put
        ld a,c
        ld b,'0'-1
.t:     inc b
        sub 10
        jr nc,.t
        add a,10+'0'
        ld c,a
        ld a,b
        cp '0'
        call nz,.put
        ld a,c
        call .put
.end:   ld hl,(@fsd)
        ld (hl),0
        ret
.put:   push hl
        ld hl,(@fsd)
        ld (hl),a
        inc hl
        ld (@fsd),hl
        pop hl
        ret

; @fval: see above.
@fval:  ld (@fsd),de
        ld (@fsp),hl
        call @bclr
        ld hl,0
        ld (@fsq),hl
        xor a
        ld (@fsf),a             ; bit 0: a digit, bit 1: the point
        ld (@fsn),a             ; significant digits taken
.ch:    ld hl,(@fsp)
        ld a,(hl)
        cp '.'
        jr nz,.dg
        ld hl,@fsf
        bit 1,(hl)
        jr nz,.me
        set 1,(hl)
        jr .nx
.dg:    sub '0'
        cp 10
        jr nc,.me
        ld c,a
        ld hl,@fsf
        set 0,(hl)
        ld a,(@fsn)
        cp 9
        jr nc,.dr
        push bc
        call @bm10
        pop bc
        ld a,c
        call @badd
        ld hl,@fsf
        bit 1,(hl)
        jr z,.ni
        ld hl,(@fsq)
        dec hl
        ld (@fsq),hl
.ni:    call @bzero
        jr z,.nx
        ld hl,@fsn
        inc (hl)
        jr .nx
.dr:    ld hl,@fsf              ; a digit past the ninth
        bit 1,(hl)
        jr nz,.nx
        ld hl,(@fsq)
        inc hl
        ld (@fsq),hl
.nx:    ld hl,(@fsp)
        inc hl
        ld (@fsp),hl
        jr .ch
.me:    ld a,(@fsf)
        rra
        ccf
        jp c,.out
        ld hl,(@fsp)            ; E, a sign, digits (else E is not ours)
        ld a,(hl)
        or 20h
        cp 'e'
        jr nz,.calc
        inc hl
        ld a,(hl)
        ld c,0
        cp '+'
        jr z,.es
        cp '-'
        jr nz,.ed
        inc c
.es:    inc hl
        ld a,(hl)
.ed:    sub '0'
        cp 10
        jr nc,.calc
        ld de,0
.en:    ld a,(hl)
        sub '0'
        cp 10
        jr nc,.ee
        push hl
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        ld e,a
        ld d,0
        add hl,de
        ex de,hl
        pop hl
        ld a,d
        cp 4
        jr c,.eo
        ld de,1000
.eo:    inc hl
        jr .en
.ee:    ld (@fsp),hl
        ld hl,(@fsq)
        bit 0,c
        jr z,.ea
        or a
        sbc hl,de
        jr .eq
.ea:    add hl,de
.eq:    ld (@fsq),hl
; the number is B * 10^q: exactly, then rounded to 32 bits
.calc:  call @bzero
        jp z,.zero
        ld hl,(@fsq)
        bit 7,h
        jr nz,.qn
        ld a,h
        or a
        jp nz,.ovf
        ld a,l
        cp 41
        jp nc,.ovf
        call @bmn
        ld de,0
        jr .nm
.qn:    ld de,60
        add hl,de
        bit 7,h
        jp nz,.zero
        ld a,(@fsq)             ; j = -q: B moved up j*0.42 + 6 bytes
        neg                     ; (j*log2(10) + 41 bits), so that 34 bits
        ld l,a                  ; are left after dividing; the whole 208
        ld h,0                  ; when that is too many
        ld d,h
        ld e,l
        add hl,hl
        push hl
        add hl,hl
        add hl,hl
        push hl
        add hl,hl
        pop bc
        add hl,bc
        pop bc
        add hl,bc
        add hl,de               ; j*27
        add hl,hl
        add hl,hl               ; H = j*27/64
        ld a,h
        add a,6
        cp BN-3
        jr nc,.all
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        push hl                 ; S = the bytes * 8
        ld b,a
.qu:    push bc
        call @bup8
        pop bc
        djnz .qu
        jr .qd
.all:   call @bnorm
        push de
.qd:    ld a,(@fsq)
        neg
        call @bdn
        pop de
.nm:    push de
        call @bnorm
        pop hl
        add hl,de               ; the shifts: the number is B / 2^S
        ex de,hl
        ld hl,336               ; the exponent byte: 208 - S + 128
        or a
        sbc hl,de
        ld a,(@fsb+BN-5)
        rla
        jr nc,.rn
        push hl
        ld hl,@fsb+BN-4
        ld b,4
.ri:    inc (hl)
        jr nz,.rd
        inc hl
        djnz .ri
        ld a,80h
        ld (@fsb+BN-1),a
        pop hl
        inc hl
        jr .rn
.rd:    pop hl
.rn:    bit 7,h
        jp nz,.zero
        ld a,h
        or a
        jp nz,.ovf
        ld a,l
        or a
        jp z,.zero
        ld hl,(@fsd)
        ld (hl),a
        inc hl
        ld a,(@fsb+BN-1)
        and 7Fh
        ld (hl),a
        inc hl
        ld a,(@fsb+BN-2)
        ld (hl),a
        inc hl
        ld a,(@fsb+BN-3)
        ld (hl),a
        inc hl
        ld a,(@fsb+BN-4)
        ld (hl),a
        ld hl,(@fsd)
        call @fsmall
        jr .ok
.zero:  ld hl,(@fsd)
        ld b,5
.zl:    ld (hl),0
        inc hl
        djnz .zl
.ok:    ld hl,(@fsp)
        or a
        ret
.ovf:   scf
.out:   ld hl,(@fsp)
        ret

; @fsmall: the positive five-byte number at HL in small-integer form if it
; is whole and below 65536.
@fsmall:
        ld a,(hl)
        sub 129
        cp 16
        ret nc
        push hl
        inc hl
        ld a,(hl)
        or 80h
        ld (@fsm+3),a
        inc hl
        ld a,(hl)
        ld (@fsm+2),a
        inc hl
        ld a,(hl)
        ld (@fsm+1),a
        inc hl
        ld a,(hl)
        ld (@fsm),a
        pop hl
        push hl
        ld a,160
        sub (hl)
        ld b,a
        ld c,0
.s:     ld hl,@fsm+3
        srl (hl)
        dec hl
        rr (hl)
        dec hl
        rr (hl)
        dec hl
        rr (hl)
        jr nc,.k
        ld c,1
.k:     djnz .s
        pop hl
        ld a,c
        or a
        ret nz
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld a,(@fsm)
        ld (hl),a
        inc hl
        ld a,(@fsm+1)
        ld (hl),a
        inc hl
        ld (hl),0
        ret

; The 208-bit number @fsb, low byte first.
; @bclr: B = 0.
@bclr:  ld hl,@fsb
        ld b,BN
.l:     ld (hl),0
        inc hl
        djnz .l
        ret

; @bzero: Z if B = 0.
@bzero: ld hl,@fsb
        ld b,BN
        xor a
.l:     or (hl)
        inc hl
        djnz .l
        ret

; @bm10: B = B * 10.  Uses A, BC, DE, HL.
@bm10:  call @blen
        ld a,b
        cp BN
        jr z,.f
        inc b
.f:     ld hl,@fsb
        ld c,0
.l:     push hl
        ld l,(hl)
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        ld e,c
        add hl,de
        ld c,h
        ld a,l
        pop hl
        ld (hl),a
        inc hl
        djnz .l
        ret

; @badd: B = B + A.
@badd:  ld hl,@fsb
        add a,(hl)
        ld (hl),a
        ret nc
.l:     inc hl
        inc (hl)
        jr z,.l
        ret

; @bshl, @bshr: B shifted one bit; CF: the bit shifted out.
@bshl:  ld hl,@fsb
        ld b,BN
        or a
.l:     rl (hl)
        inc hl
        djnz .l
        ret

@bshr:  ld hl,@fsb+BN-1
        ld b,BN
        or a
.l:     rr (hl)
        dec hl
        djnz .l
        ret

; @bmn, @bdn: B times (divided by) 10, A times: by 100 while it can.
@bmn:   ld c,a
.p:     ld a,c
        cp 2
        jr c,.o
        sub 2
        ld c,a
        push bc
        call @bm100
        pop bc
        jr .p
.o:     or a
        ret z
        jp @bm10

@bdn:   ld c,a
.p:     ld a,c
        cp 2
        jr c,.o
        sub 2
        ld c,a
        push bc
        ld d,100
        call @bdv
        pop bc
        jr .p
.o:     or a
        ret z
        ld d,10
        jp @bdv

; @bm100: B = B * 100.  Uses A, BC, DE, HL.
@bm100: call @blen
        ld a,b
        cp BN
        jr z,.f
        inc b
.f:     ld hl,@fsb
        ld c,0
.l:     push hl
        ld l,(hl)
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        ld e,c
        ld d,0
        add hl,de
        ld c,h
        ld a,l
        pop hl
        ld (hl),a
        inc hl
        djnz .l
        ret

; @bd10: B = B / 10 -> A = the remainder.  @bdv: B = B / D (D <= 128).
; Uses BC, E, HL.
@bd10:  ld d,10
@bdv:   call @blen
        ld e,b
        xor a
.o:     ld c,(hl)
        ld b,8
.i:     sla c
        rla
        cp d
        jr c,.n
        sub d
        inc c
.n:     djnz .i
        ld (hl),c
        dec hl
        dec e
        jr nz,.o
        ret

; @bnorm: B shifted up until its top bit is set (B <> 0) -> DE = the shifts.
@bnorm: ld de,0
.b:     ld a,(@fsb+BN-1)
        or a
        jr nz,.l
        push de
        call @bup8
        pop de
        ld hl,8
        add hl,de
        ex de,hl
        jr .b
.l:     ld a,(@fsb+BN-1)
        rla
        ret c
        inc de
        call @bshl
        jr .l

; @bshln, @bshrn: B shifted A bits up (down: the floor), whole bytes first.
@bshln: cp 8
        jr c,.bit
        sub 8
        push af
        call @bup8
        pop af
        jr @bshln
.bit:   or a
        ret z
        ld b,a
.l:     push bc
        call @bshl
        pop bc
        djnz .l
        ret

@bshrn: cp 8
        jr c,.bit
        sub 8
        push af
        ld hl,@fsb+1
        ld de,@fsb
        ld bc,BN-1
        ldir
        xor a
        ld (de),a
        pop af
        jr @bshrn
.bit:   or a
        ret z
        ld b,a
.l:     push bc
        call @bshr
        pop bc
        djnz .l
        ret

; @bup8: B shifted 8 bits up.
@bup8:  ld hl,@fsb+BN-2
        ld de,@fsb+BN-1
        ld bc,BN-1
        lddr
        xor a
        ld (de),a
        ret

; @blen: HL = B's top non-zero byte (or its lowest), B = how many bytes up to it.
@blen:  ld hl,@fsb+BN-1
        ld b,BN
.l:     ld a,(hl)
        or a
        ret nz
        dec hl
        djnz .l
        inc b
        inc hl
        ret

; @bcmp: CF if B's low 32 bits are below the 32 bits at DE.
@bcmp:  ld hl,@fsb
        ld b,4
        or a
.l:     ld a,(hl)
        ex de,hl
        sbc a,(hl)
        ex de,hl
        inc hl
        inc de
        djnz .l
        ret

@c1e7:  db 80h,96h,98h,00h      ; 10^7
@c1e8:  db 00h,0E1h,0F5h,05h    ; 10^8

        section bss
@fsb:   ds BN
@fsm:   ds 4
@fse:   ds 1
@fss:   ds 1
@fsk:   ds 1
@fsd:   ds 2
@fsp:   ds 2
@fsq:   ds 2
@fsf:   ds 1
@fsn:   ds 1
@fsg:   ds 8
