; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; z80-ux: the stream and console kinds (platform/screen-kinds.md).
; =====================================================================
; C48 text through the terminal: the program writes to file 1, the kernel's
; console draws it (screen64 on a Spectrum, the terminal on the FDD3000).
; No display file, no glyphs here.  putchar and puts are buffered (64
; bytes, flushed at a newline, a full buffer, a read, a sleep, a yield,
; exit); cls, cursor_at, print_at, ink, paper, bright, inverse send the
; console's codes: 12, 16h r c, 10h n, 11h n, 13h n, 14h n.  The cursor
; is followed here (64 columns, 24 rows, as the console wraps) so that
; print_at puts it back where it was.  Arguments as the screen's own
; routines take them (console.asm).  This archive is linked before
; libc48.ssa for a program that draws no pixels (rcc (libux)).
SYS     equ 6003h
        section text
        global @scrstart,_putchar,_puts,_cls,_cursor_at,_print_at
        global _ink,_paper,_bright,_inverse,_getchar,_sleep,_yield,_exit,@tflush
; @scrstart: crt0's: a text program claims no display file.
@scrstart:
        ret
; _putchar: print one character; return its byte value.
_putchar:
        push hl
        ld a,l
        call @tchr
        pop hl
        ld h,0
        ret
; _puts: print a string, then a newline; return 0.
_puts:  ld a,(hl)
        or a
        j z,.e
        push hl
        call @tchr
        pop hl
        inc hl
        j _puts
.e:     ld a,10
        call @tchr
        j @tok
; _cls: clear the console; return 0.
_cls:   ld a,12
        call @tchr
        j @tok
; _cursor_at: (row, col): move the cursor; 1 if outside 24 x 64.
_cursor_at:
        ld d,h
        ld e,l                  ; col (the last argument)
        pop bc
        pop hl                  ; row
        push bc
        call @tpos
        j c,@tbad
        call @tat
        j @tok
; _print_at: (row, col, string): print there, then put the cursor back.
_print_at:
        ld (@ttmp),hl
        pop bc
        pop de                  ; col
        pop hl                  ; row
        push bc
        call @tpos
        j c,@tbad
        push hl
        ld hl,(@trow)           ; where the cursor was (L row, H col)
        ex (sp),hl
        call @tat
        ld hl,(@ttmp)
.s:     ld a,(hl)
        or a
        j z,.b
        push hl
        call @tchr
        pop hl
        inc hl
        j .s
.b:     pop hl                  ; back there
        ld e,h
        call @tat
        j @tok
; @tpos: HL = row, DE = col -> L = row, E = col in 24 x 64; CF if not.
@tpos:  ld a,h
        or d
        scf
        ret nz
        ld a,l
        cp 24
        ccf
        ret c
        ld a,e
        cp 64
        ccf
        ret
; @tat: the cursor to row L, column E: 16h L E.
@tat:   ld a,1
        ld (@tplc),a            ; (placed: exit leaves the cursor below)
        ld a,l
        call @tlow
        ld a,l
        ld (@trow),a
        ld a,e
        ld (@tcol),a
        ld a,16h
        call @tbuf
        ld a,l
        call @tbuf
        ld a,e
        j @tbuf
; _ink, _paper: (n) 0-7; _bright, _inverse: (b) 0 or 1.  1 if not.
_ink:   ld c,10h
        j @tcol7
_paper: ld c,11h
@tcol7: ld a,h
        or a
        j nz,@tbad
        ld a,l
        cp 8
        j nc,@tbad
        j @tcode
_bright:
        ld c,13h
        j @tflag
_inverse:
        ld c,14h
@tflag: ld a,h
        or a
        j nz,@tbad
        ld a,l
        cp 2
        j nc,@tbad
; @tcode: the code C, then its parameter L; return 0.
@tcode: ld a,c
        call @tbuf
        ld a,l
        call @tbuf
@tok:   ld hl,0
        ret
@tbad:  ld hl,1
        ret
; @tchr: a character A: follow the cursor, then into the buffer.
@tchr:  push af
        ld hl,@tcol
        cp 10
        j z,.nl
        cp 13
        j z,.cr
        cp 12
        j z,.ff
        cp 8
        j z,.bs
        cp 9
        j z,.tab
        cp 32
        j c,.x
        inc (hl)                ; a character: the next column
        ld a,(hl)
        cp 64
        j c,.x
.nl:    ld (hl),0               ; (wraps as the console does)
        dec hl                  ; @trow
        ld a,(hl)
        cp 23
        j nc,.x
        inc (hl)
        ld a,(hl)
        call @tlow
        j .x
.cr:    ld (hl),0
        j .x
.ff:    ld (hl),0
        dec hl
        ld (hl),0
        j .x
.bs:    ld a,(hl)
        or a
        j z,.x
        dec (hl)
        j .x
.tab:   ld a,(hl)
        add a,8
        and 0F8h
        ld (hl),a
        cp 64
        j nc,.nl
.x:     pop af
        push af
        call @tbuf
        pop af
        cp 10                   ; a newline: what is buffered is seen now
        ret nz
        j @tflush
; @tlow: row A was written to: the lowest so far.  Keeps HL.
@tlow:  push hl
        ld hl,@tmax
        cp (hl)
        j c,.k
        ld (hl),a
.k:     pop hl
        ret
; @tbuf: A into the buffer (a character or a code's byte); flushed when
; full.
@tbuf:  push hl
        push af
        ld hl,@tn
        ld a,(hl)
        inc (hl)
        ld hl,@tob
        add a,l
        ld l,a
        j nc,.n
        inc h
.n:     pop af
        ld (hl),a
        pop hl
        ld a,(@tn)
        cp 64
        ret c
; @tflush: what is buffered to file 1.  Keeps BC, DE, HL.
@tflush:
        ld a,(@tn)
        or a
        ret z
        push hl
        push de
        push bc
        ld c,a
        ld b,0
        ld hl,1
        ld de,@tob
        ld a,4                  ; write
        call SYS
        xor a
        ld (@tn),a
        pop bc
        pop de
        pop hl
        ret
; _getchar: flush, then read a raw key as console.asm's does.
_getchar:
        call @tflush
        ld a,(@israw)
        or a
        call z,@raw
        ld hl,0
        ld de,@key
        ld bc,1
        ld a,3                  ; read
        call SYS
        j c,.e
        ld a,h
        or l
        j z,.e
        ld hl,(@key)
        ld h,0
        ret
.e:     ld hl,-1
        ret
; _yield, _sleep: flush first: what was printed is seen while it waits.
_yield: call @tflush
        xor a
        call SYS
        ld hl,0
        ret
_sleep: call @tflush
        ld a,h
        or l
        ret z
        ld a,34
        call SYS
        ld hl,0
        ret
; _exit: flush, the keyboard back to cooked, exit with status L (no
; display file to give back).
_exit:  push hl
        ld a,(@tplc)            ; it placed text: the cursor goes below
        or a                    ; the lowest row it wrote, column 0, so
        j z,.f                  ; the shell's prompt does not land on it
        ld a,(@tmax)
        inc a
        cp 24
        j c,.r
        ld a,23
.r:     ld l,a
        ld e,0
        call @tat
.f:     call @tflush
        ld a,(@israw)
        or a
        ld a,10h
        call nz,@stty
        pop hl
        ld h,0
        ld a,1
        call SYS
        j _exit
        section bss
@tn:    ds 1                    ; bytes in the buffer
@tob:   ds 64                   ; the buffer
@trow:  ds 1                    ; the cursor (row, then column: one word)
@tcol:  ds 1
@ttmp:  ds 2
@tplc:  ds 1                    ; the program placed text (cursor_at, print_at)
@tmax:  ds 1                    ; the lowest row it wrote
