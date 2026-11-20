; =====================================================================
; ZX-UX on the Timex FDD3000: SSX1 programs from files.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  On the Spectrum an SSX1 program (the ZX-UX SDK's executables: C48,
;  BASIC, Pascal, FORTRAN, Forth) comes from the cassette: exec of
;  /dev/cassette/NAME runs /etc/ldx, which finds NAME's header on the
;  tape and has sys ssxload (40) read the file that follows.  The FDD3000
;  has no cassette, and files: an SSX1 program is a file - on a disk or in
;  RAM - with execute permission, run by its name like any other:
;
;    - kexec meets a file that is not resident text: if it is executable
;      and begins "SSX1" (hssx), the kernel opens it on descriptor LDXFD
;      and runs /etc/ldx in its place, the arguments as they were;
;    - /etc/ldx (t_ldx.asm, FDD3000 part) reads the SSX1 header from
;      LDXFD, works out the memory the program needs - what a cassette
;      header carried - and makes sys ssxload;
;    - ssxload reads the file from LDXFD (ldxrd, unix.asm) as it reads a
;      sequential device's record, closes it, relocates and starts the
;      program, as before.
; =====================================================================

; hssx: kexec, i-node HL (IX) is no resident text.  If it is an
; executable SSX1 file, open it on LDXFD and say Z; else NZ.  Keeps HL.
hssx:   ld a,(ix+0)
        and IEXEC
        jr z,.no
        push hl
        ld hl,0                 ; its first 5 bytes (the signature, flags)
        ld de,u_dirbuf
        ld bc,5
        xor a
        call iio
        pop hl
        jr c,.no
        ld a,(u_nread)
        cp 5
        jr nz,.no
        push hl
        ld hl,u_dirbuf
        ld de,s_ssx1
        ld b,4
.c:     ld a,(de)
        cp (hl)
        jr nz,.nx
        inc hl
        inc de
        djnz .c
        IF HAL_SCREEN == 0
        ld a,(u_dirbuf+4)       ; no screen here: only a program declared of
        and 0Ch                 ; the stream or console kind (bit 3 set,
        cp 08h                  ; bit 2 clear: kinds 00, 01) - not one that
        jr nz,.at               ; draws, nor an older, undeclared one
        ELSE
        IF HAL_SCR4000 == 0
        ld a,(u_dirbuf+4)       ; a program that needs 4000h (built before
        and 0Eh                 ; rcc --ux - no kind declared - or of the
        cp 08h+6                ; fixed kind): 4000h is not to be had here
        jr z,.at
        bit 3,a
        jr z,.at
        ENDIF
        ENDIF
        pop hl
        call ldxopen            ; the file on LDXFD (unix.asm); keeps HL
        jr c,.no
        xor a
        ret
.nx:    pop hl
.no:    or 1
        ret
        IF HAL_SCREEN == 0
.at:    ld hl,s_draws
        call kputs
        jr .nx
s_draws: db "this program draws: it needs a screen",10,0
        ELSE
        IF HAL_SCR4000 == 0
.at:    ld hl,s_at4000
        call kputs
        jr .nx
s_at4000: db "this program draws at 4000h: rebuild it with rcc --ux",10,0
        ENDIF
        ENDIF
s_ssx1: db "SSX1"

; ssxfix: ssxload, the image relocated (KC_IMG, u_tmp2 bytes): what in
; it would stop the FDD3000 is made harmless.
;   OUT (FEh),A -> two NOPs.  Port FEh is the Spectrum's border and
;     beeper, and the FDD3000's drive latch: a C48 border() would page the
;     boot ROM in over the restart vectors (latch bit 6).
;   EI / HALT / LD HL,0 (the end of C48's beep(): "one interrupt frame
;     between notes") -> its HALT a NOP: no frame interrupt ever comes.
; The patterns are matched as bytes; data that happened to hold them
; would be changed too - a small risk against a certain one.
ssxfix: ld hl,(KC_IMG)
        ld bc,(u_tmp2)
.l:     ld a,b
        or c
        ret z
        dec bc
        ld a,(hl)
        inc hl
        cp 0D3h
        jr z,.out
        cp 0FBh
        jr nz,.l
        push hl                 ; EI: then 76 21 00 00?
        push bc
        ld de,ssxhlt
        ld b,4
.h:     ld a,(de)
        cp (hl)
        jr nz,.hn
        inc hl
        inc de
        djnz .h
        pop bc
        pop hl
        ld (hl),0               ; HALT -> NOP
        jr .l
.hn:    pop bc
        pop hl
        jr .l
.out:   ld a,b
        or c
        ret z
        ld a,(hl)
        cp 0FEh
        jr nz,.l
        xor a
        ld (hl),a
        dec hl
        ld (hl),a
        inc hl
        jr .l
ssxhlt: db 76h,21h,0,0
