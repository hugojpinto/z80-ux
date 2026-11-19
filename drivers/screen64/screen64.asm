; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  screen64: the console as 64 x 24 characters of 4 x 8 pixels drawn into
;  a Spectrum display file at 4000h - kputc, kcls, curon, curoff, the
;  cursor blink (cblnk), the status line (stdraw) - and sys screen (39)
;  for programs that draw there themselves (sysscreen, scrrel, cstrip).
; =====================================================================

; kputc: 182 bytes. A = character or AT/INVERSE control; print through the 4x8 screen path. No ROM printer.
kputc:
        push hl
        push de
        push bc
        push af
        call cstrip             ; silent while this process owns the screen. The cursor has places to be.
        jr nz,.q
        ld hl,cbusy             ; the blinking cursor keeps off while. The screen has no spare row for our
                                ; feelings.
        ld (hl),1               ; the screen changes.
        call cxoff
        pop af
        ld hl,ttat
        inc (hl)
        dec (hl)
        jp nz,.prm
        cp 16h                  ; AT row,col.
        jp z,.ctl2
        cp 14h                  ; INVERSE n.
        jp z,.ctl1
        cp 10h                  ; INK n, PAPER n, BRIGHT n (the Spectrum's
        jp z,.ctl1              ; own codes: the attribute of what follows)
        cp 11h
        jp z,.ctl1
        cp 13h
        jp z,.ctl1
        cp 10
        jp z,.nl
        cp 9
        jp z,.tab
        cp 7
        jp z,.bel
        cp 8
        jp z,.bs
        cp 12
        jp z,.ff
        cp 7Fh+1                ; 20h-7Fh printable.
        jp nc,.x
        cp 20h
        call nc,tput
.x:     xor a
        ld (cbusy),a
.xj0_56:
        pop bc
        pop de
        pop hl
        ret
.q:     pop af
        jr .xj0_56
.nl:    call tnl
        jr .x
.bs:    call connar             ; backspace (narrow: a column is two)
        ld hl,tcol
        ld b,1
        jr z,.bs1
        inc b
.bs1:   ld a,(hl)
        sub b
        jr c,.x
        ld (hl),a
        jr .x
.tab:   ld a,' '
        call tput
        ld a,(tcol)
        and 7
        jr nz,.tab
        jr .x
.bel:   ld hl,0300h             ; BEEPER: ~ 560 Hz, 0.1 s.
        ld de,056h
        push ix
        call snd_beep
        pop ix
        ei
        jr .x
.ff:    call kcls
        jr .x
.ctl2:  ld (hl),2
        jr .ctl
.ctl1:  ld (hl),1
.ctl:   ld (ttcc),a
        jr .x
.prm:   dec (hl)                ; a parameter byte.
        jr z,.pend
        ld (ttp1),a
        jr .x
.pend:  ld c,a
        ld a,(ttcc)
        cp 16h
        jr z,.pat
        cp 14h
        jr z,.pinv
        ld hl,tattr             ; INK, PAPER, BRIGHT: the attribute
        cp 11h
        ld a,c
        jr z,.ppap
        jr c,.pink
        res 6,(hl)              ; BRIGHT 0/1
        rrca
        jp nc,.x
        set 6,(hl)
        jp .x
.pink:  and 7
        ld c,a
        ld a,(hl)
        and 0F8h
        or c
        ld (hl),a
        jp .x
.ppap:  and 7
        rlca
        rlca
        rlca
        ld c,a
        ld a,(hl)
        and 0C7h
        or c
        ld (hl),a
        jp .x
.pinv:  ld a,c                  ; INVERSE 0/1.
        rrca
        sbc a,a
        and 0F0h
        ld (tinv),a
        jp .x
.pat:   ld a,(ttp1)             ; AT: text rows and columns only.
        cp TROWS
        jp nc,.x
        ld b,a                  ; B row, C column
        push bc
        call connar             ; (narrow: 32 columns, each two wide)
        pop bc
        ld a,c
        jr z,.paw
        cp 32
        jp nc,.x
        add a,a
.paw:   cp 64
        jp nc,.x
        ld (tcol),a
        ld a,b
        ld (trow),a
        jp .x

; tput: 19 bytes. A = printable char; draw and advance, wrapping after column 63. No spare row.
; (A narrow console's: tput8.)
tput:   push af
        call connar
        jr nz,tput8
        pop af
        ld de,(trow)            ; E = row, D = column.
        ld hl,tinv
        ld b,(hl)
        call glyph
        ld de,(trow)            ; its cell takes the attribute (a cell is
        call tatt               ; two characters wide: they share it)
        ld a,(tattr)
        ld (hl),a
        ld hl,tcol
        inc (hl)
        ld a,(hl)
        cp 64
        ret c
        jr tnl
; tput8: z80-ux: a narrow console's character (32 columns: platform/
; screen-kinds.md): the platform's 8x8 font (HAL_FONT8) on a whole cell,
; at an even column (after a wide one: the next), its own attribute.
tput8:  ld hl,tcol
        ld a,(hl)
        inc a
        and 0FEh
        cp 64
        jr c,.k
        call tnl
        xor a
.k:     ld (tcol),a
        ld de,(trow)
        call scradr             ; HL = the cell's first byte
        pop af
        sub 20h
        cp 60h                  ; not printable: a space
        jr c,.g
        xor a
.g:     push hl
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,HAL_FONT8
        add hl,de
        ex de,hl
        pop hl
        ld a,(tinv)             ; INVERSE: the whole byte
        or a
        jr z,.i
        ld a,0FFh
.i:     ld c,a
        ld b,8
.r:     ld a,(de)
        xor c
        ld (hl),a
        inc de
        inc h
        djnz .r
        ld de,(trow)
        call tatt
        ld a,(tattr)
        ld (hl),a
        ld hl,tcol              ; (past the last column: the next line when
        inc (hl)                ; a character comes, as BASIC's PRINT does -
        inc (hl)                ; not a scroll at the bottom now)
        ret
; tnl: 14 bytes. Advance the text row, scrolling when needed. Twenty-three rows are the whole deal.
tnl:    xor a
        ld (tcol),a
        ld hl,trow
        ld a,(hl)
        cp TROWS-1
        jr nc,tscrl
        inc (hl)
        ret

; tscrl: 39 bytes. Scroll text rows ttop+1..22 and clear row 22. Pixels get new seats.
tscrl:  ld a,(ttop)
.r:     push af
        inc a
        call rowadr             ; source row.
        pop af
        push af
        push hl
        call rowadr
        ex de,hl                ; destination row.
        pop hl
        ld b,8
.p:     push bc                 ; Copy 32 pixels bytes per scanline.
        push hl                 ; INC H/D moves down the ULA display.
        push de
        ld bc,32
        ldir
        pop de
        pop hl
        pop bc
        inc h
        inc d
        djnz .p
        pop af
        inc a
        cp TROWS-1
        jr c,.r
        push af                 ; the attributes go up with the pixels
        call .atr
        pop af
        jr clrrow
.atr:   ld a,(ttop)
        ld e,a
        ld d,0
        call tatt               ; HL = the top row's attributes
        ld a,(ttop)
        neg
        add a,TROWS-1           ; rows that move
        ret z
        ld d,h
        ld e,l
        ld b,0
        ld c,a
        ld hl,32
        add hl,de
        sla c                   ; x 32
        rl b
        sla c
        rl b
        sla c
        rl b
        sla c
        rl b
        sla c
        rl b
        ldir
        ld h,d                  ; the new bottom row: plain
        ld l,e
        ld (hl),7
        inc de
        ld bc,31
        ldir
        ret
; clrrow: 18 bytes. A = row → clear its pixels. No rag required.
clrrow: call rowadr
        ld c,8
.c:     push hl
        xor a
        ld b,32
        call zfill
        pop hl
        inc h
        dec c
        jr nz,.c
        ret

; rowadr: 3 bytes. A = row → HL = its first display byte. The screen is not a flat map.
rowadr: ld e,a
        ld d,0
; scradr: 25 bytes. E = row, D = col (0-63); HL = first pixel byte, C = nibble mask. Spectrum rows misbehave.
scradr: ld a,e
        and 18h
        or 40h
        ld h,a
        ld a,e
        rrca
        rrca
        rrca
        and 0E0h
        ld l,a
        ld a,d
        srl a
        ld c,0F0h
        jr nc,.e
        ld c,0Fh
.e:     or l
        ld l,a
        ret

; glyph: 60 bytes. A = char, E/D = row/col, B = inverse mask; draw paired 4x8 font rows. Tiny art.
glyph:  push af
        call scradr
        pop af
        sub 20h
        cp 60h                  ; not printable: a space.
        jr c,.ok
        xor a
.ok:    push hl
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,FONT
        add hl,de
        ex de,hl
        pop hl
.l:     ld a,(de)               ; upper row of the pair.
        call .row
        ld a,(de)               ; lower row.
        rlca
        rlca
        rlca
        rlca
        call .row
        inc de
        ld a,e                  ; the font is 4-aligned: 4 bytes a glyph.
        and 3
        jr nz,.l
        ret
.row:   and 0F0h
        xor b
        bit 0,c
        jr z,.r1
        rrca                    ; odd column: the low nibble.
        rrca
        rrca
        rrca
.r1:    xor (hl)                ; replace just this column's nibble.
        and c
        xor (hl)
        ld (hl),a
        inc h                   ; the ULA's next pixel line.
        ret

; kcls: 24 bytes. Clear the console. Fresh slate, same tiny screen.
kcls:   ld hl,4000h
        ld bc,1800h
        call zero               ; Clear the bitmap, and the console's
        ld hl,5800h             ; attributes to white on black (INK and
        ld bc,TROWS*32          ; PAPER may have coloured them)
        ld a,7
        ld (tattr),a
.ka:    ld (hl),a
        inc hl
        dec bc
        ld e,a
        ld a,b
        or c
        ld a,e
        jr nz,.ka
        xor a
        ld (trow),a
        ld (tcol),a
        ld (cdrawn),a
        inc a
.xj0_55:
.xj1_25:
.xj0_0:
        ld (stdirty),a
        ret

; ---------------------------------------------------------------------
;  cursor: a 4 x 8 block XORed into the display file at the print
;  position, blinking from the clock interrupt while a process waits
;  for the keyboard.  It is taken off before anything is drawn (cbusy
;  holds the blink off meanwhile), so it never leaves a mark.
; The key buffer is no bottomless bag.
; ---------------------------------------------------------------------
; cxor: 23 bytes. XOR the cursor block at the print position. Blinking has to come from somewhere.
cxor:   ld de,(trow)
        call scradr
        ld b,8
.l:     ld a,(hl)
        xor c
        ld (hl),a
        inc h
        djnz .l
        ld hl,cdrawn
        ld a,(hl)
        xor 1
        ld (hl),a
        ret
; cxoff: 7 bytes. Remove the cursor from the display. End of its solo.
cxoff:  ld a,(cdrawn)
        or a
        ret z
        jr cxor
; curon: 20 bytes. With interrupts off, show the cursor while waiting for input. Tiny flashing star.
curon:  call cstrip              ; this process owns the screen: no cursor.
        ret nz
        ld a,1
        ld (cvis),a
        xor a
        ld (cblink),a
        ld a,(cdrawn)
        or a
        ret nz
        jr cxor
; curoff: 12 bytes. A key arrived; remove the cursor. No encore.
curoff: push bc
        di
        xor a
        ld (cvis),a
        call cxoff
        ei
        pop bc
        ret
; cblnk: 21 bytes. On the frame interrupt, toggle the cursor every 16 frames. Time to blink.
cblnk:  ld hl,cblink
        inc (hl)
        ld a,(hl)
        and 15
        ret nz
        ld a,(cbusy)
        or a
        ret nz
        ld a,(cvis)
        or a
        jr nz,cxor
        jr cxoff

; stdraw: 124 bytes. Paint status. The screen loves a little gossip.
stdraw:
        xor a
        ld (stdirty),a
        ld a,23
        call clrrow
        ld hl,03010h            ; red/yellow clock cells.
        ld (05AFCh),hl
        ld hl,02820h            ; green/cyan clock cells.
        ld (05AFEh),hl
        xor a
        ld d,a                  ; column.
        ld c,a                  ; slot: a 12 column cell each.
.p:     push bc
        ld a,c
        ld l,a                  ; p_stat is page aligned (KV).
        ld h,p_stat >> 8
        ld e,(hl)
        ld a,(cur)              ; the running process in inverse.
        cp c
        ld b,0
        jr nz,.p0
        ld b,0F0h
.p0:    ld a,e
        or a
        jr z,.pn
        cp SZOMB                ; Zombies stay off the status line.
        jr z,.pn                ; Parents may still have to wait.
        ld a,c
        add a,'1'
        call stc
        ld a,e
        ld e,':'
        cp SRUN
        jr z,.p1
        ld e,'.'                ; SSLEEP.
.p1:    ld a,e
        call stc
        ld a,c
        call stname
        ld c,8
.n:     ld a,(hl)
        inc hl
        call stc
        dec c
        jr nz,.n
.pn:    pop bc
        ld a,c
        inc a
        ld c,a
        add a,a
        add a,c
        add a,a
        add a,a
        ld d,a                  ; 12 * slot.
        ld a,c
        cp NPROC
        jr c,.p
        ld d,56                 ; time hh:mm:ss at column 56.
        ld b,0
        ld a,(tod_h)
        call st2d
        ld a,':'
        call stc
        ld a,(tod_m)
        call st2d
        ld a,':'
        call stc
        ld a,(tod_s)
; st2d: 15 bytes. A = 0-99 → two digits on the status line at column D. Leading zero included.
st2d:   ld e,'0'-1
.d:     inc e
        sub 10
        jr nc,.d
        add a,'0'+10
        push af
        ld a,e
        call stc
        pop af
; stc: 13 bytes. A = glyph, B = inverse, D = column; print it and advance D. BC/E/HL stay put.
stc:    push hl
        push de
        push bc
        ld e,23
        call glyph
        pop bc
        pop de
        pop hl
        inc d
        ret

; sysscreen: 33 bytes. Claim the screen (E = 0 for first owner); the console returns after the last release.
; Share the pixels, not the throne.
sysscreen:
        ld a,h
        or l
        jr z,.rel
        di
        xor a
        ld (cvis),a
        call cxoff              ; the cursor goes.
        ei
        call curbit
        ld hl,scrown
        ld e,(hl)               ; E = the owners before.
        or e
        ld (hl),a
        jr .ok
.rel:   call scrrel
.ok:    ld hl,FONT
        jp sysok

; curbit: 11 bytes. Return the bit for the running slot in A (slot 0 = 1). Four voters, no favorites.
curbit: ld a,(cur)
        ld b,a
        inc b
        xor a
        scf
.l:     rla
        djnz .l
        ret

; scrrel: 11 bytes. Release the current job's screen bit; the last owner restores the console. Shared rent.
scrrel: call curbit
        ld hl,scrown
        and (hl)
        ret z
        xor (hl)
        ld (hl),a
        ret nz

; scrfree: 44 bytes. Restore console rows and the white-on-black screen, then start on a new bottom row. No
; deposit.
scrfree:
        ld hl,ttop
        ld b,(hl)
        xor a
        ld (hl),a
        ld (scrown),a
        ld (cdrawn),a
        out (0FEh),a
        ld a,7                  ; ... and stays black (key click, beep): A stray key can still start a
                                ; riot.
        ld (SV_BORDCR),a        ; BORDCR as the ROM's BORDER 0 leaves it.
        ld a,TT_ECHO
        ld (ttymode),a
        ld hl,5800h
        call attr7
        inc b
        dec b
        ld a,TROWS-1
        ld (stdirty),a
        ret nz                  ; the console was at the bottom already.
        ld (trow),a
        jp tnl

; cstrip: 39 bytes. Z permits console output; NZ means a screen owner has it. Rows 21-22 and status 23 still
; work.
cstrip: call curbit
        ld hl,scrown
        and (hl)
        ret nz
        or (hl)
        ret z
        ld a,(ttop)
        or a
        jr nz,attr7.z
        ld a,21
        ld (ttop),a
        ld (stdirty),a
        ld hl,TROWS-1           ; row 22, column 0.
        ld (trow),hl
        call tscrl              ; clear rows 21 and 22.
        call tscrl
        ld hl,5800h+21*32       ; white on black, the status row too.
; attr7: 10 bytes. Fill attributes from HL onward with white on black; return A = 0, Z. Paint by numbers.
attr7:  ld (hl),7
        inc hl
        ld a,h
        cp 5Bh
        jr nz,attr7
.z:     xor a
        ret

        ALIGN 4
FONT:   incbin "font4x8.bin", 8, 384
FONTEND:

; s64tick: the tick's console part - the status line when it changed, the
; cursor's blink - unless a program owns the whole screen.  From the
; frame ISR.
s64tick:
; status line, cursor (not while programs own the whole screen).
        ld a,(ttop)             ; owners 1-0Fh, ttop 0 or 21.
        ld hl,scrown
        cp (hl)
        ret c
        ld a,(stdirty)
        or a
        call nz,stdraw
        call cblnk
        ret

; tatt: E = row, D = column -> HL = its attribute cell (5800h + 32 *
; row + column / 2).
tatt:   ld a,e
        and 7
        rrca
        rrca
        rrca
        ld l,a
        ld a,e
        rrca
        rrca
        rrca
        and 3
        add a,58h
        ld h,a
        ld a,d
        srl a
        or l
        ld l,a
        ret

tattr:  db 7                    ; INK, PAPER, BRIGHT of what kputc draws

; sysdisp (41): the console, and a display file for a program that draws.
; HL = 0: describe; HL = 1 or 40h: claim one (the screen: always 4000h
; here).  -> D = the display file's page, E = 0 (a screen the kernel draws
; on), L = columns, H = rows.  (platform/screen-kinds.md)
sysdisp:
        call connar             ; (a narrow console: 32 columns)
        ld de,4000h
        ld hl,24*256+64
        jp z,sysok
        ld l,32
        jp sysok
