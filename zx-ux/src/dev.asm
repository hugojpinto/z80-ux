; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  device drivers  (u6 rtty/wtty/rmem/wmem, u7 otty/ctty, u9 getc/putc)
;   1 /dev/tty   the console (the platform's: screen64, a terminal)
;   2 /dev/mem   core memory
;   and the platform's own (devtab): 5 /dev/tap on the Spectrum (rom48),
;   8-11 /dev/fd0-3 on the FDD3000 (fd.asm)
; =====================================================================

; ---------------------------------------------------------------------
; The devices are the platform's: devtab (platform/README.md) lists, from
; device number FIRST to LAST, the routines that read, write and open
; them, and what kind they are.  An entry: db FIRST, LAST; dw read,
; write, open (0: none); db flags (DV_SEQ: const.inc).  A 0 ends the
; table.  read and write: A = the device number, the transfer in
; u_off, u_base, u_count, as readi/writei.  open: HL = the device's
; i-number; CF, A on an error; keeps HL, DE, BC, IX.
; ---------------------------------------------------------------------
DEVSZ   equ 9
DV_FLAGS equ 6                  ; the flags, from what devfind gives

; devread, devwrite: the device of i-node IX.
devread:
        ld a,(ix+30)
        call devfind
        jr c,devnone
        jr devgo
devwrite:
        ld a,(ix+30)
        call devfind
        jr c,devnone
        inc hl
        inc hl
devgo:  ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ld a,(ix+30)
        jp (hl)
devnone: ld a,EIO
        scf
        ret

; devfind: device number A -> HL = its routines in devtab (read first); CF
; if no device has it.  Keeps A, BC, DE.
devfind:
        push bc
        ld c,a
        ld hl,devtab
.l:     ld a,(hl)
        or a
        jr z,.no
        ld a,c
        cp (hl)
        jr c,.n                 ; below FIRST
        inc hl
        cp (hl)
        dec hl
        jr z,.yes
        jr c,.yes               ; up to LAST
.n:     ld a,l
        add a,DEVSZ
        ld l,a
        jr nc,.l
        inc h
        jr .l
.yes:   inc hl
        inc hl
        ld a,c
        pop bc
        or a
        ret
.no:    ld a,c
        pop bc
        scf
        ret

; devopen: an open of i-number HL: its device's open routine, if it has
; one (a disk: probe it).  CF, A on an error.  Keeps HL, DE, BC, IX.
devopen:
        ld a,h
        or a
        ret nz
        ld a,l
        cp ROOTINO
        jr nc,.no
        push hl
        push de
        call devfind
        jr c,.n
        ld de,4
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or e
        jr z,.n
        ex de,hl
        pop de
        ex (sp),hl              ; on to it, HL = the i-number
        ret
.n:     pop de
        pop hl
.no:    or a
        ret

; memrd: 9 bytes. Read RAM directly. The address had better be right.
memrd:  ld hl,(u_off)
        ld de,(u_base)
        jr memwr.xj0_0  
; memwr: 19 bytes. Write RAM directly. No second chance for bad pointers.
memwr:  ld de,(u_off)
        ld hl,(u_base)
.xj0_0:
        ld bc,(u_count)
        ld a,b
        or c
        ret z
        ldir
        jp ttwrite.xj1_13  


; ---------------------------------------------------------------------
; tty input - ISR side. The keyboard has no rewind switch.
; ---------------------------------------------------------------------
; ttrawin: 89 bytes. A = key code from ROM KEY-INPUT (ISR). One keystroke, one chance to behave.
ttrawin:
        cp 0Dh                  ; ENTER.
        jr z,.st
        cp 0Ch                  ; DELETE.
        jr z,.st
        cp 07h                  ; EDIT → EOT (ESC in vi).
        jr z,.st
        cp 08h                  ; cursor keys 8..11 (raw mode).
        jr c,.ign
        cp 0Ch
        jr c,.st
.ign:   cp 20h
        ret c
        cp 80h
        jr c,.st
        ld hl,toktab
        ld b,a
.t:     ld a,(hl)
        or a
        ret z
        inc hl
        cp b
        ld a,(hl)
        inc hl
        jr nz,.t
.st:    ld b,a
        ld a,(ttyhd)
        ld c,a
        inc a
        and 31
        ld hl,ttytl
        cp (hl)
        ret z                   ; ring full.
        ld (ttyhd),a
        ld hl,ttyring
        ld a,c
        call addhla
        ld (hl),b
        call kclick             ; the key click, if the machine has one.
        ld a,WC_TTY
        jp kwakeup

; ttintr: 50 bytes. BREAK signals every live process (UNIX v1 DEL). The key does not negotiate.
ttintr:
        ld b,0
.l:     ld a,b
        ld l,a                  ; p_stat is page aligned (KV).
        ld h,p_stat >> 8
        ld a,(hl)
        or a
        jr z,.n
        cp SZOMB
        jr z,.n
        ld a,b
        ld hl,p_sig
        call addhla
        ld a,(hl)
        or a
        jr nz,.n
        ld (hl),1
.n:     call nxslot
        jr c,.l
        call ttyflush           ; discard stale keys after BREAK. The input line is not a parking lot.
        ld a,WC_TTY
        call kwakeup
        ld a,WC_WAIT
        call kwakeup
        ld a,WC_TIME
        jp kwakeup

; ttyflush: 7 bytes. Flush raw keys after a foreground child; leave background readers alone. No stale votes.
ttyflush:
        ld a,(ttyhd)
        ld (ttytl),a
        ret

; ---------------------------------------------------------------------
; tty input - process side (canonical line discipline, echo) DELETE erases, ENTER ends the line, EDIT = EOT
; (^D), BREAK = intr. BREAK is a key, not a polite suggestion.
; ---------------------------------------------------------------------
; ttgetc: 55 bytes. Pull one character from the line. No queue jumping.
ttgetc:                         ; → A = key; CF if interrupted (ignored). The keyboard insists on being
                                ; heard.
.l:     di
        call sigck
        jr c,.int
        ld a,(ttytl)
        ld hl,ttyhd
        cp (hl)
        jr nz,.have
        call curon
        ld a,WC_TTY
        call ksleep
        ei
        jr .l
.have:  ld hl,ttyring
        call addhla
        ld b,(hl)
        ld a,(ttytl)
        inc a
        and 31
        ld (ttytl),a
        ei
        call curoff
        ld a,b
        or a
        ret
.int:   ei
        call curoff
        scf
        ret

; ttread: 244 bytes. Read the terminal line. The keyboard gets a turn.
ttread:
        ld a,(ttymode)
        and TT_RAW
        jr z,.can
        ld a,(ttymode)          ; z80-ux: TT_NOWAIT - no key waiting, nothing read
        and TT_NOWAIT
        jr z,.raw
        ld a,(ttytl)
        ld hl,ttyhd
        cp (hl)
        jr nz,.raw
        ld hl,0
        jp iadv
.raw:   call ttgetc
        jp c,.int
        ld hl,(u_base)            ; raw: keys untranslated (ENTER = 13). No key gets to jump the queue.
        ld (hl),a
        ld hl,1
        jp iadv
.can:   ld a,(ttyrdy)
        or a
        jr nz,.copy
.col:   call ttgetc
        jp c,.int
        cp 0Dh
        jr z,.nl
        cp 0Ch
        jr z,.del
        cp 07h
        jr z,.eot
        cp 0Ch
        jr c,.col               ; cursor keys: raw mode only.
        ld b,a
        ld a,(ttycnt)
        cp TTYBSZ-1
        jr nc,.col
        ld hl,TTYBUF
        call addhla
        ld (hl),b
        ld hl,ttycnt
        inc (hl)
        ld a,(ttymode)
        and TT_ECHO
        jr z,.col
        ld a,b
        jr ttread.xj0_42  
.del:   ld a,(ttycnt)
        or a
        jr z,.col
        dec a
        ld (ttycnt),a
        ld a,(ttymode)
        and TT_ECHO
        jr z,.col
        ld a,8
        call kputc
        ld a,' '
        call kputc
        ld a,8
.xj0_42:
        call kputc
        jr .col
.nl:    ld a,(ttycnt)
        ld hl,TTYBUF
        call addhla
        ld (hl),10
        ld hl,ttycnt
        inc (hl)
        ld a,10
        call kputc
        jr .done
.eot:   ld a,(ttycnt)
        or a
        ret z                   ; EOF: nread = 0.
.done:  ld a,1
        ld (ttyrdy),a
.copy:  ld a,(ttypos)
        ld b,a
        ld a,(ttycnt)
        sub b
        ld l,a
        ld h,0
        ld de,(u_count)
        call minhlde
        ld (ktmp),hl
        ld a,(ttypos)
        add a,l
        ld (ttypos),a
        ld a,b
        ld hl,TTYBUF
        call addhla
        ld de,(u_base)
        ld bc,(ktmp)
        ld a,b
        or c
        jr z,.c1
        ldir
.c1:    ld a,(ttypos)
        ld hl,ttycnt
        cp (hl)
        jr c,.c2
        xor a
        ld (ttyrdy),a
        ld (ttycnt),a
        ld (ttypos),a
.xj0_34:
.c2:    ld hl,(ktmp)
        jp iadv
.int:   xor a
        ld (ttyrdy),a
        ld (ttycnt),a
        ld (ttypos),a
        ld a,(ttymode)
        and TT_RAW
        ld a,10
        call z,kputc
        ld a,EINTR
        scf
        ret

; ---------------------------------------------------------------------
; tty output. The keys have the last word.
; ---------------------------------------------------------------------
; ttwrite: 29 bytes. Put text on screen. Pixels have a tight schedule.
ttwrite:
        ld hl,(u_base)
        ld bc,(u_count)
.l:     ld a,b
        or c
        jr z,.d
        ld a,(hl)
        push hl
        push bc
        call kputc
        pop bc
        pop hl
        inc hl
        dec bc
        jr .l
.xj0_33:
.xj1_13:
.d:     ld hl,(u_count)
        jp iadv

; kputs: 11 bytes. Print a string. The screen charges by the character.
kputs:  ld a,(hl)
        or a
        ret z
        push hl
        call kputc
        pop hl
        inc hl
        jr kputs

; ---------------------------------------------------------------------
;  64 x 24 text screen in a 4 x 8 font (rows 0-22 text, row 23 status)
;  No ROM printing: every character is drawn into the display file.
;  The ULA's interleaved layout does most of the work - the 8 pixel
;  lines of a character cell lie 256 bytes apart, so INC H steps one
;  line down - and two characters share each byte, one per nibble.
; The display will notice if we cheat.
; ---------------------------------------------------------------------
TROWS   equ 23

; The console - kputc, kcls, curon, curoff (and sys screen, cext.asm) -
; is the platform's: drivers/screen64 on the Spectrum, the FDD3000's
; terminal in fdd3000/src/hal.asm (platform/README.md).

; ---------------------------------------------------------------------
; stty / gtty (u1) HL = fd, DE = 3 word buffer (speeds, mode). Every byte has to pay rent.
; ---------------------------------------------------------------------
; sysstty: 33 bytes. Set terminal rules. The keys follow orders.
sysstty:
        push de
        call getf
        pop de
        jp c,syserr
        call ckty
        jp c,syserr
        ex de,hl
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)
        rla                     ; TT_FLUSH bit 7 requests raw ring drain.
        call c,ttyflush
        ld a,(hl)
        and TT_RAW+TT_ECHO+TT_NOWAIT
        ld (ttymode),a
        jp sysok
; sysgtty: 31 bytes. Read terminal rules. Nobody likes surprises.
sysgtty:
        push de
        call getf
        pop de
        jp c,syserr
        call ckty
        jp c,syserr
        ex de,hl
        xor a
        ld b,6
.z:     ld (hl),a
        inc hl
        djnz .z
        dec hl
        dec hl
        ld a,(ttymode)
        ld (hl),a
        jp sysok

; ckty: 10 bytes. HL = fsp entry → CF if it is not the terminal. Other devices need not apply.
ckty:   ld a,(hl)
        dec a
        inc hl
        or (hl)
        dec hl
        ret z
        ld a,ENOTTY
        scf
        ret
ENOTTY  equ 25

; low-memory scratch (the time of day, stdirty and kcon: kvars.inc; they were MEMBOT+0..4, which a
; program's BEEP uses). The clock keeps counting while we argue.
trow    equ MEMBOT+8            ; print position: row (trow, tcol adjacent).
tcol    equ MEMBOT+9            ; column 0-63.
tinv    equ MEMBOT+10           ; F0h: INVERSE 1.
cvis    equ MEMBOT+11           ; cursor wanted (waiting for a key). One keystroke, one chance to behave.
cdrawn  equ MEMBOT+12           ; cursor is on the screen.
cbusy   equ MEMBOT+13           ; screen being changed: no blinking.
cblink  equ MEMBOT+14           ; blink frame counter.
