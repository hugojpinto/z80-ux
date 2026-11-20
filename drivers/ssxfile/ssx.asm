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
; What it needs (its flags: const.inc SSX*) that this machine has not:
; refused, saying which.  Before the kinds were declared, a program
; needed all of it: the 48K ROM, a screen, at 4000h.
        ld a,(u_dirbuf+4)
        ld c,a
        IF HAL_ROM48K == 0
        ld hl,s_rom             ; the 48K ROM
        bit SSXB_ROM,c
        jr nz,.ref
        bit SSXB_DECL,c
        jr z,.ref
        ENDIF
        IF HAL_SCREEN == 0
        ld hl,s_draws           ; a screen to draw on
        bit SSXB_DECL,c
        jr z,.ref
        bit SSXB_DRAWS,c
        jr nz,.ref
        ELSE
        IF HAL_SCR4000 == 0
        ld hl,s_at4000          ; the screen at 4000h
        bit SSXB_DECL,c
        jr z,.ref
        ld a,c
        and SSX_KIND
        cp SSX_FIXED
        jr z,.ref
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
.ref:   call kputs
        jr .nx
        IF HAL_ROM48K == 0
s_rom:  db "this program needs the 48K ROM",10,0
        ENDIF
        IF HAL_SCREEN == 0
s_draws: db "this program draws: it needs a screen",10,0
        ELSE
        IF HAL_SCR4000 == 0
s_at4000: db "this program draws at 4000h: there is no screen there",10,0
        ENDIF
        ENDIF
s_ssx1: db "SSX1"

