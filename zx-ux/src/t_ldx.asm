; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  /etc/ldx - the SSX1 program loader (ZX-UX v1)
;
;  The kernel runs this in place of an SSX1 program, the program's source
;  open on LDXFD and argv unchanged:
;   - a file (HAL_SSXFILE, ssx.asm): its SSX1 header says the length and
;     the memory the program needs (image + bss + stack + heap);
;   - DEV/NAME, DEV a sequential device (HAL_SEQDEV, seqx: the cassette's
;     /dev/cassette/NAME): it searches DEV for the header of NAME, a CODE
;     header whose second parameter is "SS" and whose first is the memory
;     the program needs (SPEC-SDK-R2 section 9).  DEV/* runs the first
;     program on it, whatever its name: argv[0] becomes DEV/NAME as if
;     typed (the program, the status line and ps see the name; sys
;     ssxload names the process from argv[0]).  BREAK stops the search.
;  Which of the two: a file has a length, a device none.
;  Then sys ssxload has the kernel load the SSX1 file (the device's next
;  record) into a block of memory, relocate it and start it with the
;  arguments; this process becomes the program.
; =====================================================================
LX_H    equ TV                  ; 17-byte cassette header.
LX_NM   equ TV+19               ; the name looked for.
LX_A0   equ TV+21               ; the SSX1 header; argv[0] for *: DEV/NAME.
LXA0SZ  equ 40
LX_END  equ LX_A0+LXA0SZ

t_ldx:  db 18h,6
        dw STKRES, LX_END-UDATA, ldx_m
; ldx_m: find the program, then have the kernel load it.
ldx_m:  pop hl
        call args
        IF HAL_SSXFILE
        ld hl,LDXFD             ; its length: seek to the end
        ld de,0
        ld bc,2
        call sc_seek
        jp c,.ioe
        IF HAL_SEQDEV
        ld a,h                  ; none: a sequential device
        or l
        jp z,.seq
        ENDIF
        ld (LX_H+11),hl
        ld hl,LDXFD             ; back to its start: the SSX1 header
        ld de,0
        ld bc,0
        call sc_seek
        ld hl,LDXFD
        ld de,LX_A0
        ld bc,20
        call sc_read
        jp c,.ioe
        ld a,l
        cp 20
        jp nz,.ioe
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
        jp .args
.mem:   ld de,s_lxmem
        jp .err
        ENDIF
        IF HAL_SEQDEV
.seq:   xor a
        call argn
        call basenm
        ld (LX_NM),hl
        ld a,(hl)              ; An empty name is no program. This search ends here.
        or a                    ; The star is allowed; an empty name is not. Picky tape.
        jp z,.nameerr           ; No name? Do not spin the cassette for nothing.
.hdr:   ld hl,LDXFD             ; the next header.
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
.any:   xor a                   ; argv[0] becomes DEV/NAME: DEV/ as typed ...
        call argn
        ld de,LX_A0
        ld b,LXA0SZ-11
.ap:    push hl
        push de
        ld de,(LX_NM)
        or a
        sbc hl,de
        pop de
        pop hl
        jr z,.an0
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .ap
.an0:   ld hl,(U_ARGV)
        push de
        ld de,LX_A0
        ld (hl),e
        inc hl
        ld (hl),d
        pop de
        ld hl,LX_H+1            ; ... then the name found
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
; Print the accepted name before the executable body is loaded. The screen belongs to the loader
; until _ssxload succeeds.
.got:   ld hl,s_lxload
        call puts
        xor a
        call argn
        call puts
        call crlf
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
        IF HAL_SEQDEV
.nameerr:
        ld de,s_lxname
        jr .err
        ENDIF
.ioe:   ld de,s_lxio
.err:   xor a
        call argn
.xpe:   call perr               ; (t_file: perr, then exit 1)
.xj0_1:                         ; (t_misc, t_file: exit 1)
        ld hl,1
        jp exitc
        IF HAL_SEQDEV
s_lxload: db "Loading: ",0
s_lxname: db "missing program name",0
        ENDIF
        IF HAL_SSXFILE
s_lxio: db "not an SSX1 program",0
        ELSE
s_lxio: db "tape error",0
        ENDIF
s_lxmem: db "not enough memory",0
e_ldx:
