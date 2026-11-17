; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  /etc/ldx - the SSX1 program loader (ZX-UX v1)
;
;  "exec /dev/cassette/NAME args" runs this program instead (the kernel
;  redirects it, argv unchanged).  It searches the cassette for the
;  header of NAME: a CODE header whose second parameter is "SS" and
;  whose first is the memory the program needs (SPEC-SDK-R2 section 9).
;  Then sys ssxload has the kernel load the SSX1 file that follows into
;  a block of memory, relocate it and start it with the arguments; this
;  process becomes the program.  BREAK stops the search.
;
;  /dev/cassette/* runs the first program on the tape, whatever its
;  name: argv[0] becomes /dev/cassette/NAME as if typed (the program,
;  the status line and ps see the name; sys ssxload names the process
;  from argv[0]).
; =====================================================================
LX_H    equ TV                  ; 17-byte cassette header.
LX_FD   equ TV+17
LX_NM   equ TV+19               ; the name looked for.
LX_A0   equ TV+21               ; argv[0] for *: /dev/cassette/NAME (25). Nobody told the cassette about
                                ; instant access.
LX_END  equ TV+46

t_ldx:  db 18h,6
        dw STKRES, LX_END-UDATA, ldx_m
; ldx_m: 276 bytes. Find the named program on a very slow tape.
ldx_m:  pop hl
        call args
        IFDEF FDD3000
; FDD3000: the kernel opened the program file on LDXFD and ran us in its
; place (ssx.asm).  Its SSX1 header says what a cassette header said:
; the length (the file's) and the memory it needs (image + bss + stack +
; heap, at least the file's length).  LX_A0 holds the header.
        ld hl,LDXFD
        ld de,LX_A0
        ld bc,20
        call sc_read
        jp c,.ioe
        ld a,l
        cp 20
        jp nz,.ioe
        ld hl,LDXFD             ; its length: seek to the end and back
        ld de,0
        ld bc,2
        call sc_seek
        jp c,.ioe
        ld (LX_H+11),hl
        ld hl,LDXFD
        ld de,0
        ld bc,0
        call sc_seek
        ld hl,(LX_A0+6)         ; image ...
        ld de,(LX_A0+8)         ; ... bss ...
        add hl,de
        jp c,.mem
        ld de,(LX_A0+10)        ; ... stack ...
        add hl,de
        jp c,.mem
        ld de,(LX_A0+12)        ; ... heap
        add hl,de
        jp c,.mem
        ld de,(LX_H+11)
        or a
        sbc hl,de
        add hl,de
        jr nc,.need
        ex de,hl                ; less than the file: the file
.need:  ld (LX_H+13),hl
        jr .args
.mem:   ld de,s_lxmem
        jp .err
        ELSE
        xor a
        call argn
        call basenm
        ld (LX_NM),hl
        ld a,(hl)              ; An empty cassette name is no program. This search ends here.
        or a                    ; The star is allowed; an empty name is not. Picky tape.
        jp z,.nameerr           ; No name? Do not spin the cassette for nothing.
        ld hl,s_tap
        ld de,0
        call sc_open
        jp c,.ioe
        ld (LX_FD),hl
.hdr:   ld hl,(LX_FD)           ; the next header.
        ld de,LX_H
        ld bc,17
        call sc_read
        jr c,.hdr
        ld a,(LX_H)             ; ... of a CODE block.
        cp 3                    ; older CODE/SS tapes.
        jr z,.ss
        cp 4                    ; versioned SSX1/SS tapes.
        jr nz,.hdr
.ss:    ld hl,(LX_H+15)         ; for an SSX1 program.
        ld de,'S'+256*'S'
        or a
        sbc hl,de
        jr nz,.hdr
        ld de,(LX_NM)           ; called NAME.
        ld a,(de)               ; "*" alone: any name.
        cp '*'
        jr nz,.cmp
        inc de
        ld a,(de)
        dec de
        or a
        jr z,.any
.cmp:   ld hl,LX_H+1
        ld b,10
.nm:    ld a,(de)
        or a
        jr z,.sp
        cp (hl)
        jr nz,.hdr
        inc hl
        inc de
        djnz .nm
        jr .got
.sp:    ld a,(hl)
        cp ' '
        jr nz,.hdr
        inc hl
        djnz .sp
        jr .got
.any:   ld de,LX_A0             ; Wildcard tape name becomes /dev/cassette/NAME.
        ld hl,(U_ARGV)          ; name found.
        ld (hl),e
        inc hl
        ld (hl),d
        ld hl,s_cas
        call strcpy             ; DE on its 0.
        ld a,'/'
        ld (de),a
        inc de
        ld hl,LX_H+1
        ld b,10
.an:    ld a,(hl)
        cp ' '
        jr z,.a0
        ld (de),a
        inc hl
        inc de
        djnz .an
.a0:    xor a
        ld (de),a
.got:   ld hl,(LX_FD)
        call sc_close
; Print the accepted header name before the executable body is loaded. The screen belongs to the loader
; until _ssxload succeeds.
        ld hl,s_lxload
        call puts
        ld hl,LX_H+1
        ld b,10
.lprint: ld a,(hl)
        cp ' '
        jr z,.ldone
        call putc
        inc hl
        djnz .lprint
.ldone: call crlf
        ENDIF
.args:
; memory: the program's, and its arguments (strings and vector).
        ld hl,(LX_H+13)
        ld a,(U_ARGC)
        ld d,a
        add a,a
        add a,6
        call adda
.as:    dec d
        jp m,.ae
        push hl
        ld a,d
        call argn
        call strlen
        pop hl
        add hl,bc
        inc hl
        jr .as
.ae:    ld (LX_NM),hl
        ld hl,0                 ; Ask for current free RAM. Imaginary bytes will not help.
        SC _zxpack              ; Include the window only if we may borrow it. No squatters.
        ld de,CORETOP-WINDOW+LX_END-UDATA+STKRES    ; Add the loader and process room. Every byte gets a
                                                    ; bill.
        add hl,de
        ld de,(LX_NM)
        call cphl
        ld de,s_lxmem
        jr c,.err
        ld de,(LX_NM)           ; Give the loader the requested memory. No guessing.
        ld bc,(LX_H+11)         ; Pass the real tape-file length. Close enough never loads.
        ld hl,(U_ARGV)          ; Pass the arguments, too. Programs like introductions.
        ld a,_ssxload
        call SYS                ; returns only if it was refused. We do not call this a surprise feature.
        jr .ioe                ; preserve the failed-load error path. The failure gets a name, not a
                               ; disguise.
        IFNDEF FDD3000
.nameerr:
        ld de,s_lxname
        jr .err
        ENDIF
.ioe:   ld de,s_lxio
.err:   xor a
        call argn
        call perr
.xj0_1:
        ld hl,1
        jp exitc
        IFDEF FDD3000
s_lxio: db "not an SSX1 program",0
        ELSE
s_lxload: db "Loading: /dev/cassette/",0
s_lxname: db "missing cassette program name",0
s_lxio: db "tape error",0
        ENDIF
s_lxmem: db "not enough memory",0
e_ldx:
