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


; TTYC: A = the terminal whose line state is loaded (always 0 with one).
        MACRO TTYC
        IF NTTY > 1
        ld a,(ttyc)
        ELSE
        xor a
        ENDIF
        ENDM

; ---------------------------------------------------------------------
; tty input - ISR side. The keyboard has no rewind switch.
; z80-ux: NTTY terminals (kvars.inc): each its own ring; the console is 0.
; ---------------------------------------------------------------------
; ttrawin: 89 bytes. A = key code from ROM KEY-INPUT (ISR): the console's.
; ttrawn: A = a key, E = its terminal.  One keystroke, one chance to behave.
ttrawin:
        ld e,0
ttrawn:
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
        ld a,e
        IF NTTY > 1
        ld (ttykt),a
        ENDIF
        call ttq                ; HL: its head, DE: its tail, BC: its ring
        push bc
        ld c,a                  ; (the key)
        ld a,(hl)
        push af
        inc a
        and TTRING-1
        ex de,hl
        cp (hl)
        ex de,hl
        jr z,.full
        ld (hl),a
        pop af                  ; the old head: the key goes there
        pop hl
        call addhla
        ld (hl),c
        IF NTTY > 1
        ld a,(ttykt)            ; the key click, if the machine has one:
        or a                    ; the console's keys only
        call z,kclick
        ld a,(ttykt)            ; its own terminal's readers
        call ttwc
        ELSE
        call kclick             ; the key click, if the machine has one.
        ld a,WC_TTY
        ENDIF
        jp kwakeup
.full:  pop af
        pop bc
        ret                     ; ring full.

; ttq: A = a terminal -> HL = its ring's head, DE = its tail, BC = its
; ring; A = the key that came in B, as it was.  (A terminal < 8.)
        IF NTTY > 1
ttq:    push af
        ld hl,ttytl
        call addhla
        ex de,hl
        pop af
        push af
        ld hl,ttyhd
        call addhla
        pop af
        push hl
        rrca                    ; x TTRING (32)
        rrca
        rrca
        ld hl,ttyring
        call addhla
        ld a,b
        ld b,h
        ld c,l
        pop hl
        ret
        ASSERT TTRING == 32
        ELSE
ttq:    ld hl,ttyhd             ; (one terminal: its ring)
        ld de,ttytl
        ld a,b
        ld bc,ttyring
        ret
        ENDIF

; ttintr: 50 bytes. BREAK on the console.  ttintn: on terminal E.  Every
; live process of that terminal gets the interrupt (UNIX v1 DEL; with one
; terminal, every live process).  The key does not negotiate.
ttintr:
        ld e,0
ttintn:
        ld b,0
.l:     ld a,b
        ld l,a                  ; p_stat is page aligned (KV).
        ld h,p_stat >> 8
        ld a,(hl)
        or a
        jr z,.n
        cp SZOMB
        jr z,.n
        IF NTTY > 1
        ld a,b
        ld hl,p_tty
        call addhla
        ld a,(hl)
        cp e
        jr nz,.n
        ENDIF
        ld a,b
        ld hl,p_sig
        call addhla
        ld a,(hl)
        or a
        jr nz,.n
        ld (hl),1
.n:     call nxslot
        jr c,.l
        ld a,e
        call ttflsn             ; discard stale keys after BREAK. The input line is not a parking lot.
        IF NTTY > 1
        ld a,e                  ; (that terminal's readers)
        call ttwc
        ELSE
        ld a,WC_TTY
        ENDIF
        call kwakeup
        ld a,WC_WAIT
        call kwakeup
        ld a,WC_TIME
        jp kwakeup

; ttyflush: 7 bytes. Flush raw keys after a foreground child; leave background readers alone. No stale votes.
; (the terminal in use; ttflsn: terminal A's)
ttyflush:
        TTYC
ttflsn: push bc
        push de
        push hl
        call ttq
        ld a,(hl)
        ld (de),a
        pop hl
        pop de
        pop bc
        ret

        IF NTTY > 1
; ttsel: terminal A's line state in the variables (the one there saved):
; ttymode .. ttyrdy, ttat .. ttp1, TTYBUF.  Keeps BC, DE, HL.  (The
; print position, trow and tcol, is the console's: its cursor blinks in
; the frame interrupt; drivers/vt52 keeps its terminals' own.)
ttsel:  push hl
        ld hl,ttyc
        cp (hl)
        jr z,.x
        push de
        push bc
        push af
        ld a,(hl)
        call .sv                ; HL: its save area
        ex de,hl
        call .cp                ; the variables -> it
        pop af
        ld (ttyc),a
        call .sv
        ex de,hl
        call .cp                ; ... and back, the other way
        pop bc
        pop de
.x:     pop hl
        ret
; .sv: A = a terminal -> HL = its save area
.sv:    ld hl,ttsave
        or a
        ret z
        ld b,a
.m:     push bc
        ld bc,TTSV
        add hl,bc
        pop bc
        djnz .m
        ret
; .cp: swap the variables with DE (TTSV bytes)
.cp:    ld hl,ttymode
        ld b,4
        call .xb
        ld hl,ttat
        ld b,3
        call .xb
        ld hl,TTYBUF
        ld b,TTYBSZ
.xb:    ld a,(de)
        ld c,(hl)
        ld (hl),a
        ld a,c
        ld (de),a
        inc hl
        inc de
        djnz .xb
        ret

; ttwc: A = a terminal -> A = its wait channel (WC_TTY for the console;
; WC_TTY1 - 1 + n): a key wakes only the readers of its terminal.
ttwc:   or a
        jr z,.c
        add a,WC_TTY1-1
        ret
.c:     ld a,WC_TTY
        ret
        ASSERT WC_TTY1 > WC_TIME && WC_TTY1+NTTY-2 < 256

; ttnum: A = a terminal's device number -> A = the terminal (DEV_TTY:
; the running process's own).
ttnum:  cp DEV_TTY
        jr nz,.n
        ld a,(cur)
        push hl
        ld hl,p_tty
        call addhla
        ld a,(hl)
        pop hl
        ret
.n:     sub DEV_TTY1-1
        ret

; ttopen: an open of terminal i-number L (DEV_TTY1 ...): the running
; process's terminal from now on (its children's too).  Keeps HL, DE,
; BC, IX.
ttopen: push hl
        ld a,l
        call ttnum
        push af
        ld a,(cur)
        ld hl,p_tty
        call addhla
        pop af
        ld (hl),a
        pop hl
        or a
        ret

; ttself: the running process's terminal loaded (for what the kernel
; says to it: kputs).
ttself: ld a,DEV_TTY
        call ttnum
        jp ttsel

; ttdisp: system call 41 (the platform's sysdisp) - a process whose
; terminal is not the console is told of a terminal: D = 0 (no display
; file), E = 1 (a terminal), TTCOLS x TTROWS (TTNARROW for a narrow
; console); HL = 1, a claim: EINVAL.
TTCOLS  equ 80
TTROWS  equ 24
TTNARROW equ 32
ttdisp: push hl
        ld a,DEV_TTY
        call ttnum
        pop hl
        or a
        jp z,sysdisp
        ld a,h
        or l
        ld a,EINVAL
        jp nz,syserr
        call connar
        ld de,1
        ld hl,TTROWS*256+TTCOLS
        jp z,sysok
        ld l,TTNARROW
        jp sysok
        ENDIF

; ---------------------------------------------------------------------
; tty input - process side (canonical line discipline, echo) DELETE erases, ENTER ends the line, EDIT = EOT
; (^D), BREAK = intr. BREAK is a key, not a polite suggestion.
; ---------------------------------------------------------------------
; ttgetc: 55 bytes. Pull one character from the line. No queue jumping.
ttgetc:                         ; → A = key; CF if interrupted (ignored). The keyboard insists on being
                                ; heard.
.l:
        IF NTTY > 1
        ld a,(cur)              ; (another terminal may have been in use
        ld hl,p_ttr             ; while this one slept: its state swapped
        call addhla             ; with interrupts on - the interrupt touches
        ld a,(hl)               ; only the rings)
        call ttsel
        ENDIF
        di
        call sigck
        jr c,.int
        TTYC
        call ttq
        ld a,(de)
        cp (hl)
        jr nz,.have
        call ttcuron
        IF NTTY > 1
        TTYC                    ; (its own terminal's channel)
        call ttwc
        ELSE
        ld a,WC_TTY
        ENDIF
        call ksleep
        ei
        jr .l
.have:  ld h,b
        ld l,c
        call addhla             ; (A: HL's low byte now)
        ld b,(hl)
        ld a,(de)               ; the tail, again
        inc a
        and TTRING-1
        ld (de),a
        ei
        call ttcuroff
        ld a,b
        or a
        ret
.int:   ei
        call ttcuroff
        scf
        ret

; ttcuron, ttcuroff: the cursor - the console's only.
        IF NTTY > 1
ttcuron:
        TTYC
        or a
        ret nz
        jp curon
ttcuroff:
        TTYC
        or a
        ret nz
        jp curoff
        ELSE
ttcuron equ curon
ttcuroff equ curoff
        ENDIF

; ttread: 244 bytes. Read the terminal line. The keyboard gets a turn.
; (A = the device: /dev/tty, the process's own; z80-ux: /dev/ttyN)
ttread:
        IF NTTY > 1
        call ttnum
        push af
        ld a,(cur)
        ld hl,p_ttr
        call addhla
        pop af
        ld (hl),a
        call ttsel
        ENDIF
        ld a,(ttymode)
        and TT_RAW
        jr z,.can
        ld a,(ttymode)          ; z80-ux: TT_NOWAIT - no key waiting, nothing read
        and TT_NOWAIT
        jr z,.raw
        TTYC
        call ttq
        ld a,(de)
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
        call ttout
        ld a,' '
        call ttout
        ld a,8
.xj0_42:
        call ttout
        jr .col
.nl:    ld a,(ttycnt)
        ld hl,TTYBUF
        call addhla
        ld (hl),10
        ld hl,ttycnt
        inc (hl)
        ld a,10
        call ttout
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
        call z,ttout
        ld a,EINTR
        scf
        ret

; ---------------------------------------------------------------------
; tty output. The keys have the last word.
; ---------------------------------------------------------------------
; ttwrite: 29 bytes. Put text on screen. Pixels have a tight schedule.
; (A = the device, as ttread's)
ttwrite:
        IF NTTY > 1
        call ttnum
        call ttsel
        ENDIF
        ld hl,(u_base)
        ld bc,(u_count)
.l:     ld a,b
        or c
        jr z,.d
        ld a,(hl)
        push hl
        push bc
        call ttout
        pop bc
        pop hl
        inc hl
        dec bc
        jr .l
.xj0_33:
.xj1_13:
.d:     ld hl,(u_count)
        jp iadv

; ttout: A to the terminal in use: the console's kputc, or for the
; others, VT52s, drivers/vt52's vtputc (the platform's ttput below it).
        IF NTTY > 1
ttout:  push af
        TTYC
        or a
        jr z,.k
        pop af
        jp vtputc
.k:     pop af
        jp kputc
        ELSE
ttout   equ kputc
        ENDIF

; kputs: 11 bytes. Print a string. The screen charges by the character.
kputs:
        IF NTTY > 1
        call ttself             ; z80-ux: the running process's terminal
        ENDIF
.l:     ld a,(hl)
        or a
        ret z
        push hl
        call ttout
        pop hl
        inc hl
        jr .l

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
; (z80-ux: a terminal - /dev/tty, /dev/ttyN - its line state loaded.
; Keeps HL, DE.)
ckty:
        IF NTTY > 1
        inc hl
        ld a,(hl)
        dec hl
        or a
        jr nz,.no
        ld a,(hl)
        cp DEV_TTY
        jr z,.y
        cp DEV_TTY1
        jr c,.no
        cp DEV_TTY1+NTTY-1
        jr nc,.no
.y:     call ttnum
        call ttsel
        or a
        ret
.no:
        ELSE
        ld a,(hl)
        dec a
        inc hl
        or (hl)
        dec hl
        ret z
        ENDIF
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
