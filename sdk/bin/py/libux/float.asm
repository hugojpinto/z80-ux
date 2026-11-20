; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; C48 floats: the Spectrum's five-byte format.
; zx-ux+ (libux): the arithmetic is the platform's float engine, whose
; address system call 42 gives (platform/float.md): the 48 ROM's
; calculator on a Spectrum, a loaded clean-room engine on a machine
; without that ROM - one interface: A = operation, HL = x, DE = y, BC =
; the result, IX = this program's workspace.  Asking for the engine
; (@fpget) and beep() are the runtime's choice: rom48k.asm (rcc --rom48k:
; the ROM's calculator without call 42, the ROM's BEEP) or norom.asm
; (rcc --no-rom: call 42 only, a clean-room beep).
        section text
        global @fac,@fmov,@fop,@itof,@utof,@ftoi,@ftou,@fcmp,@ftst,@ferr,@fcall
        global @fbc,@fpe,@fws
        global _sin,_cos,_tan,_asin,_acos,_atan,_sqrt,_exp,_log,_fabs,_pow
SYS     equ 6003h
; @fmov: 6 bytes. Copy one five-byte float from HL to DE.
@fmov:  ld bc,5
        ldir
        ret

; @ferr: 6 bytes. End the program with status one on a floating-point failure.
@ferr:  ld hl,1                 ; status 1, as the C48 language requires
        jp _exit
; @fop: operation A on the floats at HL and DE, the result at HL; exit
; on failure.
@fop:   ld b,h
        ld c,l
        call @fcall
        ret nc
        j @ferr
; @fcall: the engine: A = operation, HL = x, DE = y, BC = the result ->
; CF: none.  The engine's address is asked for once.
@fcall: push ix
        ld ix,@fws
        push af
        push hl
        ld hl,(@fpe)
        ld a,h
        or l
        call z,@fpget
        ld (.c+1),hl
        pop hl
        pop af
.c:     call 0
        pop ix
        ret
; @itof: 5 bytes. Convert signed HL into a five-byte float at DE.
@itof:  ld a,h
        add a,a
        sbc a,a                 ; FF if negative
        j @icv
; @utof: 1 byte. Convert unsigned HL into the same format. No sign drama.
@utof:  xor a
; @icv: 13 bytes. Write the small-integer float form to DE.
@icv:   ex de,hl
        ld (hl),0
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0
        ret

; @ftoi: 33 bytes. Truncate a float to signed 16-bit or exit if it will not fit.
@ftoi:  call @fbc
        j c,@ferr
        j z,.pos
        ld a,b                  ; negative: up to 32768
        cp 80h
        j c,.ok
        j nz,@ferr
        ld a,c
        or a
        j nz,@ferr
.ok:    xor a
        sub c
        ld l,a
        sbc a,a
        sub b
        ld h,a
        ret
.pos:   bit 7,b                 ; positive: up to 32767
        j nz,@ferr
        ld h,b
        ld l,c
        ret
; @ftou: 16 bytes. Truncate a float to unsigned 16-bit; reject negatives outside zero.
@ftou:  call @fbc
        j c,@ferr
        j z,.p
        ld a,b                  ; negative: only zero
        or c
        j nz,@ferr
.p:     ld h,b
        ld l,c
        ret
; @fbc: the integer part's magnitude in BC; Z: not negative; CF: too big.
@fbc:   ld a,18
        j @fcall

; @fcmp: 40 bytes. Compare floats at HL and DE; carry means less, zero means equal.
@fcmp:  ld bc,@ftmp
        push bc
        push de
        ld d,b
        ld e,c
        call @fmov              ; x -> @ftmp
        pop de
        pop hl
        ld a,2                  ; x - y
        call @fop
        ld hl,@ftmp
        ld a,(hl)
        or a
        j nz,.big
        inc hl                  ; small integer: sign byte, value
        ld b,(hl)
        inc hl
        ld a,(hl)
        inc hl
        or (hl)
        ret z                   ; zero: equal (NC)
        ld a,b
        j .sg
.big:   inc hl
        ld a,(hl)
.sg:    or 1                    ; NZ
        rla                     ; CF = sign
        ret

; @ftst: 7 bytes. Set zero flag when the float at HL is zero.
@ftst:  ld a,(hl)
        inc hl
        inc hl
        or (hl)
        inc hl
        or (hl)
        ret
; _sin: 4 bytes. Send sine to the ROM calculator helper.
_sin:   ld a,11
        j @fun1
; _cos: 4 bytes. Send cosine to the ROM calculator helper.
_cos:   ld a,12
        j @fun1
; _tan: 4 bytes. Send tangent to the ROM calculator helper.
_tan:   ld a,13
        j @fun1
; _asin: 4 bytes. Send inverse sine to the ROM calculator helper.
_asin:  ld a,14
        j @fun1
; _acos: 4 bytes. Send inverse cosine to the ROM calculator helper.
_acos:  ld a,15
        j @fun1
; _atan: 4 bytes. Send inverse tangent to the ROM calculator helper.
_atan:  ld a,16
        j @fun1
; _sqrt: 4 bytes. Send square root to the ROM calculator helper.
_sqrt:  ld a,17
        j @fun1
; _exp: 4 bytes. Send exponential to the ROM calculator helper.
_exp:   ld a,9
        j @fun1
; _log: 4 bytes. Send logarithm to the ROM calculator helper.
_log:   ld a,10
        j @fun1
; _fabs: 2 bytes. Send absolute value to the ROM calculator helper.
_fabs:  ld a,6
; @fun1: 18 bytes. Copy one float to @fac and run the selected ROM operation.
@fun1:  push af
        ld de,@fac
        call @fmov
        pop af
        ld hl,@fac
        call @fop
        ld hl,@fac
        ret
; _pow: 24 bytes. Raise x to y with the ROM; return the result at @fac.
_pow:   pop bc
        pop de
        push bc
        push hl
        ex de,hl
        ld de,@fac
        call @fmov
        pop de
        ld hl,@fac
        ld a,5
        call @fop
        ld hl,@fac
        ret
        section bss
; @fac: 5 BSS bytes. Shared result for ROM calculator calls.
@fac:   ds 5
; @ftmp: 5 BSS bytes. Comparison scratch; no second register bank.
@ftmp:  ds 5
; @fpe: the engine's address (0: not asked yet).
@fpe:   ds 2
; @fws: the engine's workspace (drivers/fp/fp.asm FPWS: 105).
@fws:   ds 112
