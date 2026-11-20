; =====================================================================
; ZX-UX on the Timex TC3256: the keyboard, clean room.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; TC3256 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; The Spectrum's matrix on port FEh (the TC3256's extra keys come as
; CAPS / SYMBOL pairs, in hardware), scanned each frame: what each key
; gives - plain, with CAPS SHIFT, with SYMBOL SHIFT - is kbdtab.inc's,
; which build.py writes from the description BASIC's keyboard uses too
; (sdk/bin/py/libux/rbc/keyboard.py): the codes ttrawin takes (ASCII,
; ENTER 0Dh, DELETE 0Ch, EDIT 07h, the cursors 08h-0Bh, keywords).
; A key held repeats after KREPD frames, then every KREPP (the 48K's
; REPDEL and REPPER); CAPS LOCK (CAPS + 2) turns letters to capitals;
; CAPS + SPACE is BREAK (ttintr, once a press).
; While a link command is under way the frame interrupt is cut short
; (link.asm): it only reads the matrix (kbheld), queueing it when it has
; changed; the queue is played through the same logic when the command
; is done (kbdrain, from lktick) - a key pressed and let go meanwhile is
; still typed.
; =====================================================================

KREPD   equ 35
KREPP   equ 5
KB_SHC  equ 1                   ; kbsh: CAPS SHIFT down
KB_SHS  equ 2                   ; ... SYMBOL SHIFT down
KB_QN   equ 16                  ; matrices a link command's wait may queue
KB_MASK equ (1 << KB_BITS)-1    ; a row's keys (the port's bits 7-5 are not)

; kbscan: the matrix now -> kbnow (a byte a row, 1: down).  Uses A, BC,
; DE, HL.
kbscan: ld hl,kbrows
        ld de,kbnow
        ld b,KB_ROWS
.r:     push bc
        ld b,(hl)
        ld c,KB_PORT
        in a,(c)
        cpl                     ; 1: down
        and KB_MASK
        ld (de),a
        inc hl
        inc de
        pop bc
        djnz .r
        ret

; kbheld: the frame interrupt cut short (link.asm), which TOS waits on:
; all the rows at once first (a few dozen T-states) - the matrix read and
; queued for kbdrain only when that has changed (a key down or up; full:
; dropped).  Uses A, BC, DE, HL.
kbheld: xor a                   ; every row: a key down anywhere
        in a,(KB_PORT)
        and KB_MASK
        ld hl,kbany
        cp (hl)
        ret z
        ld (hl),a
        call kbscan
        ld hl,kbnow
        ld de,kbmat
        ld b,KB_ROWS
.c:     ld a,(de)
        cp (hl)
        jr nz,.q
        inc hl
        inc de
        djnz .c
        ret
.q:     ld a,(kbqn)
        cp KB_QN
        ret nc
        inc a
        ld (kbqn),a
        dec a
        ld l,a                  ; kbq + n * KB_ROWS
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ASSERT KB_ROWS == 8
        ld de,kbq
        add hl,de
        ex de,hl
        ld hl,kbnow
        ld bc,KB_ROWS
        ldir
        ld hl,kbnow
        ld de,kbmat
        ld bc,KB_ROWS
        ldir
        ret

; kbdrain: the matrices kbheld queued, through kbproc in turn.  Uses A,
; BC, DE, HL.
kbdrain: ld a,(kbqn)
        or a
        ret z
        ld hl,kbq
.n:     push af
        push hl
        ld de,kbnow
        ld bc,KB_ROWS
        ldir
        call kbproc
        pop hl
        ld bc,KB_ROWS
        add hl,bc
        pop af
        dec a
        jr nz,.n
        ld (kbqn),a
        ret

; kbtick: the frame interrupt's keys (and the rows at once, for kbheld).
kbtick: xor a
        in a,(KB_PORT)
        and KB_MASK
        ld (kbany),a
        call kbscan
; kbproc: the keys of the matrix kbnow (kbmat: the last taken).
kbproc: ld hl,kbnow
        ld de,kbmat
        ld bc,KB_ROWS
        ldir
        xor a
        ld (kbsh),a
        ld d,KB_NONE            ; the key down (the last found)
        ld e,0                  ; the key's index
        ld hl,kbnow
        ld b,KB_ROWS
.row:   push bc
        ld c,(hl)
        ld b,KB_BITS
.bit:   srl c
        jr nc,.nx
        ld a,e
        cp KB_CAPS
        jr z,.caps
        cp KB_SYM
        jr z,.sym
        ld d,e
        jr .nx
.caps:  ld a,(kbsh)
        or KB_SHC
        ld (kbsh),a
        jr .nx
.sym:   ld a,(kbsh)
        or KB_SHS
        ld (kbsh),a
.nx:    inc e
        djnz .bit
        pop bc
        inc hl
        djnz .row
        ld a,(kbsh)             ; BREAK: CAPS SHIFT + SPACE
        cp KB_SHC
        jr nz,.nb
        ld a,d
        cp KB_SPACE
        jr nz,.nb
        ld a,KB_NONE
        ld (kblast),a
        ld a,(kbbrk)
        or a
        ret nz                  ; held: once a press
        inc a
        ld (kbbrk),a
        jp ttintr
.nb:    xor a
        ld (kbbrk),a
        ld a,d
        ld hl,kblast
        cp KB_NONE
        jr nz,.key
        ld (hl),a               ; none down
        ret
.key:   cp (hl)
        jr z,.same
        ld (hl),a
        ld a,KREPD
        ld (kbcnt),a
        jr .emit
.same:  ld hl,kbcnt
        dec (hl)
        ret nz
        ld (hl),KREPP
.emit:  ld a,d                  ; its code: kbtab[key * 4 + the shifts]
        add a,a
        add a,a
        ld hl,kbsh
        add a,(hl)
        ld l,a
        ld h,0
        ld de,kbtab
        add hl,de
        ld a,(hl)
        cp KB_NONE
        ret z
        cp KB_CAPSLK
        jr nz,.cl
        ld a,(kbcl)
        cpl
        ld (kbcl),a
        ret
.cl:    ld b,a
        ld a,(kbcl)
        or a
        ld a,b
        jr z,.go
        cp 'a'
        jr c,.go
        cp 'z'+1
        jr nc,.go
        sub 'a'-'A'
.go:    jp ttrawin

kbsh:   db 0                    ; the shifts down (KB_SHC, KB_SHS)
kblast: db KB_NONE              ; the key down at the last frame
kbcnt:  db 0                    ; frames to its next repeat
kbbrk:  db 0                    ; BREAK down
kbcl:   db 0                    ; CAPS LOCK (FFh: on)
kbnow:  ds KB_ROWS              ; the matrix read (kbscan)
kbmat:  ds KB_ROWS              ; ... the last taken (kbproc, or queued)
kbany:  db KB_MASK               ; kbheld: the rows at once, last read
kbqn:   db 0                    ; matrices queued (kbheld) ...
kbq:    ds KB_QN*KB_ROWS        ; ... these

        include "kbdtab.inc"    ; kbrows, kbtab (build.py)
