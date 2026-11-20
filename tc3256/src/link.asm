; =====================================================================
; ZX-UX on the Timex TC3256: the host's end of the FDD3000 link.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; TC3256 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; The FDD3000 runs TOS, a disk server; the TC3256 reaches it over the
; 6-bit link on port EFh (TI_FDD_Technical_Reference_v2.md §6), in user
; mode - the shadow ROM is not needed for it.  Three tiers:
;  - a byte: two nibbles on bits 3-0, each confirmed on bits 7-6 (send:
;    the low nibble, wait 01; it with the strobe, wait 11; the high one
;    with the strobe, then without, wait 00.  Receive: ask with 01, the
;    low nibble comes with 10, acknowledge with 11, the high one comes
;    with 00, lines clear).  A handshake that does not come within
;    LKPOLL reads is a timeout: the lines are cleared, the block fails;
;  - a block: type (C0h a command, D0h data), length (0: 256), a marker,
;    the payload, a checksum (the negated sum: the block sums to 0), then
;    the receiver's ACK (B0h) or NAK (E0h, sent again, LKTRIES times);
;  - a command: a C0h block of 13 bytes, TOS's function code (lkcom) and
;    the host's registers AF, BC, DE, HL, IX, IY, which TOS loads; the
;    reply is a C0h block the same shape, lkcom = 80h and A the status,
;    perhaps after D0h blocks of data (lkdat).
;  A block moves with interrupts off: TOS waits only so long for each
;  handshake, and a frame interrupt between two would lose it the block.
;  Between blocks - while TOS reads a disk - they are on again, once the
;  kernel runs (lkint, set by hinit; tcboot, before, keeps them off).
; =====================================================================

LINK    equ 0EFh                ; the link (bit 7 in: also the FDC's DRQ)
LK_HS   equ 0C0h                ; the handshake bits
LK_SEND equ 40h                 ; ... 01: a nibble taken / ready to receive
LK_STB  equ 80h                 ; ... 10: the strobe / a nibble offered
LK_CMD  equ 0C0h                ; block types
LK_DATA equ 0D0h
LK_ACK  equ 0B0h
LK_NAK  equ 0E0h
LK_OK   equ 80h                 ; a reply's function code
LKTRIES equ 10                  ; a block's tries
LKPOLL  equ 0                   ; handshake reads before a timeout (0: 256)
LKWAIT  equ 4000                ; tries for a reply while TOS works (~20 s)

; lkcom: a command, as TOS takes it: the function, then AF (F, A), BC
; (C, B), DE (E, D), HL, IX, IY
LKC_F   equ 0
LKC_A   equ 2
LKC_C   equ 3
LKC_B   equ 4
LKC_E   equ 5
LKC_D   equ 6
LKC_L   equ 7
LKC_H   equ 8
LKCLEN  equ 13

; lkcmd: send lkcom to TOS and wait for its reply (into lkcom; data blocks
; on the way into lkdat, the last one's length in lkdlen) -> A = the
; status (0: done), Z; CF: the link failed, or the reply was not one.
lkcmd:  ld a,LK_CMD
        ld b,LKCLEN
        ld hl,lkcom
        call lksend
        ret c
lkreply: ld hl,LKWAIT
.w:     push hl
        call lkrecv
        pop hl
        jr nc,.got
        dec hl
        ld a,h
        or l
        jr nz,.w
        scf
        ret
.got:   cp LK_CMD
        jr nz,lkreply           ; data: kept, the reply still to come
        ld a,(lkcom+LKC_F)
        cp LK_OK
        scf
        ret nz
        ld a,(lkcom+LKC_A)
        or a                    ; NC, Z: done
        ret

; lksend: a block - A = its type, B = its length (0: 256), HL = the
; payload -> CF: not acknowledged in LKTRIES tries.  Keeps HL.
lksend: di
        call lksend0
        jr lkei
lksend0: ld (lkhdr),a
        ld a,b
        ld (lkhdr+1),a
        ld a,LKTRIES
        ld (lktry),a
.again: push hl
        push bc
        ld c,0
        ld a,(lkhdr)
        call lksb
        jr c,.fail
        ld a,(lkhdr+1)
        call lksb
        jr c,.fail
        ld a,(lkhdr+2)
        call lksb
        jr c,.fail
        ld a,(lkhdr+1)          ; the length (C: the sum, kept)
        ld b,a
.d:     ld a,(hl)
        call lksb
        jr c,.fail
        inc hl
        djnz .d
        ld a,c
        neg
        call lksb
        jr c,.fail
        call lkrb
        jr c,.fail
        cp LK_ACK
        jr nz,.fail
        pop bc
        pop hl
        or a
        ret
.fail:  pop bc
        pop hl
        ld a,(lktry)
        dec a
        ld (lktry),a
        jr nz,.again
        scf
        ret

; lkrecv: a block from TOS - a command into lkcom, data into lkdat ->
; A = its type, lkdlen its length; CF: none came (or not whole, LKTRIES
; times).
lkrecv: di
        call lkrecv0
lkei:   push af                 ; interrupts on again, if the kernel runs
        ld a,(lkint)
        or a
        jr z,.x
        ei
.x:     pop af
        ret
lkrecv0: ld a,LKTRIES
        ld (lktry),a
.again: ld c,0
        ld hl,lkhdr
        ld b,3
.h:     call lkrb
        ret c                   ; nothing: TOS still at work
        ld (hl),a
        inc hl
        djnz .h
        ld hl,lkcom
        ld a,(lkhdr)
        cp LK_CMD
        jr z,.p
        ld hl,lkdat
        cp LK_DATA
        jr nz,.again            ; not a block: from its header again
.p:     ld a,(lkhdr+1)
        ld b,a
.d:     call lkrb
        jr c,.bad
        ld (hl),a
        inc hl
        djnz .d
        call lkrb               ; the checksum: the sum is now 0
        jr c,.bad
        ld a,c
        or a
        jr nz,.bad
        ld a,LK_ACK
        call lksb
        ld a,(lkhdr)
        cp LK_DATA
        jr nz,.ok
        ld a,(lkhdr+1)
        ld (lkdlen),a
        ld a,LK_DATA
.ok:    or a
        ret
.bad:   ld a,(lktry)
        dec a
        ld (lktry),a
        scf
        ret z
        ld a,LK_NAK
        call lksb
        jr .again

; lksb: send the byte A; C += A -> CF: a timeout.  Keeps B, HL.
lksb:   push de
        ld d,a
        add a,c
        ld c,a
        ld a,d
        and 0Fh
        out (LINK),a            ; the low nibble
        ld a,LK_SEND
        call lkhs
        jr c,.x
        ld a,d
        and 0Fh
        or LK_STB
        out (LINK),a            ; ... strobed
        ld a,LK_HS
        call lkhs
        jr c,.x
        ld a,d
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        ld e,a
        or LK_STB
        out (LINK),a            ; the high nibble, strobed
        ld a,e
        out (LINK),a            ; ... the strobe off
        xor a
        call lkhs
.x:     pop de
        ret

; lkrb: receive a byte -> A; C += A; CF: a timeout.  Keeps B, HL.
lkrb:   push de
        ld a,LK_SEND
        out (LINK),a            ; ready
        ld a,LK_STB
        call lkhs               ; the low nibble
        jr c,.x
        and 0Fh
        ld e,a
        ld a,LK_HS
        out (LINK),a            ; taken
        xor a
        call lkhs               ; the high nibble
        jr c,.x
        and 0Fh
        rlca
        rlca
        rlca
        rlca
        or e
        ld d,a
        xor a
        out (LINK),a            ; the lines clear
        ld a,d
        add a,c
        ld c,a
        ld a,d
        or a                    ; NC
.x:     pop de
        ret

; lkhs: wait for the handshake A (bits 7-6) -> A = the link's byte, NC;
; CF: it did not come (the lines cleared).  Keeps BC, DE, HL.
lkhs:   push bc
        ld c,a
        ld b,LKPOLL
.l:     in a,(LINK)
        push af
        and LK_HS
        cp c
        jr z,.ok
        pop af
        djnz .l
        xor a
        out (LINK),a
        pop bc
        scf
        ret
.ok:    pop af
        pop bc
        or a
        ret

; the link's buffers
lkhdr:  db 0,0,0                ; a block's type, length, marker
lktry:  db 0
lkint:  db 0                    ; interrupts may be on between blocks (hinit)
lkdlen: db 0                    ; the last data block's length (0: 256)
lkcom:  ds LKCLEN               ; a command, a reply
lkdat:  ds 256                  ; a data block
