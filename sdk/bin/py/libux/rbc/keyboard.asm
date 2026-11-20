; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): the keys, in place of the 48K ROM's KEY-SCAN, K-TEST, K-DECODE
; (the runtime's INKEY$) and KEYBOARD (rbc's PAUSE).
;
; On a screen console (system call 41, E = 0: a Spectrum) the keyboard's
; half-rows (port KPORT) as the ROM reads them: one key besides the
; shifts, decoded by @rkeys (libux/rbc/keyboard.py's layout: unshifted,
; CAPS, SYMBOL, both; CAPS LOCK making letters capitals).  Behind a
; terminal (E = 1) the terminal's next character, read without waiting
; (TT_NOWAIT), taken by K-DECODE; a terminal has no key rows.
; Clean room: checked against the ROM's INKEY$ (test/basic/romdiff.py).
        section text
        global @r028E,@r031E,@r0333,@r02BF

; KEY-SCAN: -> Z: at most one key held besides the shifts (NZ: more; both
; shifts count as SYMBOL under CAPS); E = it (0FFh: none), D = the shifts
; (bit 0 CAPS, bit 1 SYMBOL).
@r028E: ld a,(@rterm)
        or a
        j nz,.tty
        ld de,0FFh
        ld bc,KFIRST<<8|KPORT
        ld h,0                  ; the index of the row's first key
.row:   in a,(c)
        cpl
        push bc
        ld b,KBITS
.bit:   rra
        j nc,.nx
        push af
        ld a,h
        cp K_CAPSI
        j z,.cs
        cp K_SYMI
        j z,.ss
        ld a,e
        inc a
        j nz,.two
        ld e,h
        j .p
.cs:    set 0,d
        j .p
.ss:    set 1,d
.p:     pop af
.nx:    inc h
        djnz .bit
        pop bc
        rlc b                   ; the next half-row
        ld a,b
        cp KFIRST
        j nz,.row
        ld a,d                  ; both shifts: SYMBOL is the key, under
        cp 3                    ; CAPS (EXTEND MODE) - with a third key,
        j nz,.one               ; too many
        ld a,e
        inc a
        j nz,.many
        ld de,1<<8|K_SYMI
.one:   ld (@rksh),de
        xor a
        ret
.many:  ld (@rksh),de
        or 1
        ret
.two:   pop af
        pop bc
        ld (@rksh),de
        or 1
        ret
.tty:   call @rkpoll
        ld de,0FFh
        j nc,.t0
        ld e,0
.t0:    ld (@rksh),de
        xor a
        ret

; K-TEST: -> CF and A = the key, if KEY-SCAN found one.
@r031E: ld a,e
        cp 0FFh
        ret

; K-DECODE: -> A = the character of the key KEY-SCAN found.
@r0333: ld a,(@rterm)
        or a
        j nz,.tty
        ld de,(@rksh)           ; E key, D shifts
        ld a,e
        add a,a
        add a,a
        add a,d
        ld e,a
        ld d,0
        ld hl,@rkeys
        add hl,de
        ld a,(@rksh+1)
        or a
        ld a,(hl)
        ret nz
        ld hl,FLAGS2            ; unshifted, under CAPS LOCK: capitals
        bit FL2_CAPS,(hl)
        ret z
        cp 'a'
        ret c
        cp 'z'+1
        ret nc
        sub 'a'-'A'
        ret
.tty:   xor a
        ld (@rkwait),a          ; taken
        ld a,(@rkc)
        ret

; KEYBOARD (as rbc's PAUSE reads it): KSTATE's first key: the key held
; (0FFh: none); the second: none.
@r02BF: call @r028E
        ld a,0FFh
        j nz,.n
        ld a,e
.n:     ld (KSTATE),a
        ld a,0FFh
        ld (KSTATE4),a
        ret

; @rkpoll: CF if a character is waiting at the terminal (@rkc): read
; once, without waiting, the terminal's mode put back.
@rkpoll:
        ld a,(@rkwait)
        or a
        scf
        ret nz
        ld hl,0
        ld de,@rktty
        ld a,SYS_GTTY
        call SYS
        ccf
        ret nc
        ld a,(@rktty+TTMODE)
        ld (@rkold),a
        ld a,TT_RAW|TT_NOWAIT
        ld (@rktty+TTMODE),a
        call .mode
        ld hl,0
        ld de,@rkc
        ld bc,1
        ld a,SYS_READ
        call SYS
        j nc,.r
        ld hl,0
.r:     push hl
        ld a,(@rkold)
        ld (@rktty+TTMODE),a
        call .mode
        pop hl
        ld a,h
        or l
        ret z
        ld a,1
        ld (@rkwait),a
        scf
        ret
.mode:  ld hl,0
        ld de,@rktty
        ld a,SYS_STTY
        jp SYS

        section bss
@rksh:  ds 2                    ; the key (E), the shifts (D)
@rkc:   ds 1                    ; the terminal's character
@rkwait: ds 1                   ; ... waiting
@rkold: ds 1
@rktty: ds 6
