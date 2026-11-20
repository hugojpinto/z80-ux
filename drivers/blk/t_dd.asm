; =====================================================================
; ZX-UX block devices: /bin/dd - copy blocks, disks included.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;   dd [if=FILE] [of=FILE] [count=N] [skip=N] [seek=N]
;
;  Copies blocks of 256 bytes (a disk sector) from if (standard input)
;  to of (standard output): count of them (all), skipping skip blocks of
;  the input and seek blocks of the output first.  skip and seek use the
;  disk driver's sector seek (mode 3), so they reach all of a disk, past
;  the 64K a 16-bit offset can.  An output that cannot be opened is
;  created.  At the end: "N blocks" on standard error.
;
;   dd if=/dev/fd0 count=1 | od      the boot sector  (no pipes: of=)
;   dd if=/dev/fd0 of=/dev/fd1       copy a disk
; =====================================================================
DD_IF   equ TV                  ; if= (string), of=
DD_OF   equ TV+2
DD_CNT  equ TV+4                ; count= (FFFFh: all), skip=, seek=
DD_SKIP equ TV+6
DD_SEEK equ TV+8
DD_IFD  equ TV+10               ; the open files
DD_OFD  equ TV+12
DD_N    equ TV+14               ; blocks copied
DD_BUF  equ TV+16               ; one block
DD_END  equ TV+16+256

t_dd:   db 18h,6
        dw STKRES, DD_END-UDATA, dd_m
dd_m:   pop hl
        call args
        ld hl,0
        ld (DD_IF),hl
        ld (DD_OF),hl
        ld (DD_SKIP),hl
        ld (DD_SEEK),hl
        ld (DD_N),hl
        dec hl
        ld (DD_CNT),hl
        ld a,1
.a:     push af
        call argn
        jr z,.go
        call ddopt
        jr c,.use
        pop af
        inc a
        jr .a
.use:   ld hl,s_ddu
        jp usage
.go:    pop af
        ld hl,(DD_IF)           ; the input (none: fd 0)
        ld a,h
        or l
        jr z,.i0
        ld de,0
        call sc_open
        ld de,(DD_IF)
        jp c,.err
.i0:    ld (DD_IFD),hl
        ld hl,(DD_OF)           ; the output (none: fd 1)
        ld a,h
        or l
        ld hl,1
        jr z,.o0
        ld hl,(DD_OF)
        ld de,1
        call sc_open
        jr nc,.o0
        ld hl,(DD_OF)
        ld de,0Eh               ; rw- r-- (IROWN IWOWN IROTH)
        call sc_creat
        ld de,(DD_OF)
        jp c,.err
.o0:    ld (DD_OFD),hl
        ld hl,(DD_SKIP)
        ld bc,(DD_IFD)
        call .sk
        ld de,(DD_IF)
        jp c,.err
        ld hl,(DD_SEEK)
        ld bc,(DD_OFD)
        call .sk
        ld de,(DD_OF)
        jp c,.err
.l:     ld hl,(DD_CNT)
        ld a,h
        or l
        jr z,.end
        dec hl
        ld (DD_CNT),hl
        ld hl,(DD_IFD)
        ld de,DD_BUF
        ld bc,256
        call sc_read
        ld de,(DD_IF)
        jp c,.err
        ld a,h
        or l
        jr z,.end               ; the end of the input
        ld b,h
        ld c,l
        ld hl,(DD_OFD)
        ld de,DD_BUF
        call sc_write
        ld de,(DD_OF)
        jp c,.err
        ld hl,(DD_N)
        inc hl
        ld (DD_N),hl
        jr .l
.end:   ld hl,(DD_N)
        ld de,DD_BUF
        call fmtdec
        ex de,hl
        ld (hl),0
        ld hl,DD_BUF
        call eputs
        ld hl,s_ddb
        call eputs
        jp exit0
; .sk: seek file BC forward HL blocks (mode 3).
.sk:    ld a,h
        or l
        ret z
        ex de,hl
        ld h,b
        ld l,c
        ld bc,3
        jp sc_seek
; .err: DE = the file's name (0: standard input or output).
.err:   ld a,d
        or e
        jr nz,.e1
        ld de,s_ddstd
.e1:    ex de,hl
        ld de,s_ddio
        call perr
        ld hl,1
        jp exitc

; ddopt: HL = "key=value": set it.  CF if it is no option of dd.
ddopt:  ld de,ddtab
.t:     ld a,(de)
        or a
        scf
        ret z                   ; not in the table
        push hl
.c:     ld a,(de)               ; the key, up to its '='
        cp (hl)
        jr nz,.no
        inc de
        inc hl
        cp '='
        jr nz,.c
        inc de                  ; DE: past the key's 0: its variable
        ex de,hl                ; HL: the variable, DE: the value
        pop af                  ; (drop the saved argument)
        ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        ld a,(hl)               ; 0: a name, 1: a number
        ld h,b
        ld l,c
        or a
        jr z,.set
        push hl
        ex de,hl
        call atoi               ; DE = the number, HL after its digits
        ld a,(hl)
        pop hl
        ret c                   ; no digits
        or a
        scf
        ret nz                  ; something after them
.set:   ld (hl),e
        inc hl
        ld (hl),d
        or a
        ret
.no:    pop hl                  ; the next entry: past the key's 0 ...
.n0:    ld a,(de)
        inc de
        or a
        jr nz,.n0
        inc de                  ; ... its variable and kind
        inc de
        inc de
        jr .t

ddtab:  db "if=",0
        dw DD_IF
        db 0
        db "of=",0
        dw DD_OF
        db 0
        db "count=",0
        dw DD_CNT
        db 1
        db "skip=",0
        dw DD_SKIP
        db 1
        db "seek=",0
        dw DD_SEEK
        db 1
        db 0
s_ddu:  db "dd [if=f] [of=f] [count=n] [skip=n] [seek=n]",0
s_ddb:  db " blocks",10,0
s_ddio: db "I/O error",0
s_ddstd: db "dd",0
e_dd:
