; =====================================================================
; ZX-UX on the Timex FDD3000: the display file, mirrored to the terminal.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  SDK programs (C48's console, BASIC, Pascal...) do not write text to
;  the terminal: they claim the screen (sys screen, 39), get ZX-UX's 4x8
;  font from it and draw 64 x 24 characters into the Spectrum's display
;  file themselves.  The FDD3000 has no display file - 4000h-5AFFh is
;  RAM left to them - and a VT52 terminal on the link.  So while a
;  program owns the screen, the kernel reads it back:
;
;    every tick (tint, or stick on the soft clock) MROWS character rows are looked at: a row whose
;    pixels' checksum has changed is read cell by cell, each cell's 8
;    rows of 4 pixels matched against the font (straight or inverse:
;    hash, then a search), and the cells that differ from what the
;    terminal shows are sent to it (ESC Y, the character).  Pixels that
;    are no character (PLOT, DRAW, UDGs) show as '#'.
;
;  When the last owner lets go (or exits) the screen is read once more
;  in full, and the console goes on below it.  The program's colours
;  (attributes) are not shown; inverse cells are (ESC L / ESC M).
; =====================================================================

MROWS   equ 2                   ; rows looked at a tick: all 24 in 12

; the 4x8 font: 96 glyphs, 4 bytes each, two pixel rows a byte (upper
; row in the high nibble).  sys screen hands its address to programs.
        ALIGN 4
FONT:   incbin "font4x8.bin", 8, 384

; ---------------------------------------------------------------------
; sys screen (39), FDD3000: HL = 1 claims the screen (-> HL = the font,
; E = the owners before: 0 for the first), HL = 0 lets it go.
; ---------------------------------------------------------------------
sysscreen:
        ld a,h
        or l
        jr z,.rel
        call dalloc             ; a display file to draw into
        jp c,syserr
        call mbit
        ld hl,scrown
        ld e,(hl)
        or e
        ld (hl),a
        ld a,e
        or a
        call z,minit            ; the first owner: the terminal is the screen
        ld hl,FONT
        jp sysok
.rel:   call scrrel
        ld hl,FONT
        jp sysok

; scrrel: the running process lets go of the screen (also when it ends:
; release); the last one out gets the console back.
scrrel: call mbit
        ld hl,scrown
        and (hl)
        jr z,.n
        xor (hl)
        ld (hl),a
        ret nz
        call mdone
.n:     ld a,(scrown)           ; nobody draws (also when a process that
        or a                    ; had one ends without claiming): the
        ret nz                  ; display file goes back to the arena
        jp dfree


; mbit: A = the running slot's bit in scrown (slot 0 = 1).  Uses B.
mbit:   ld a,(cur)
        ld b,a
        inc b
        xor a
        scf
.l:     rla
        djnz .l
        ret

; ---------------------------------------------------------------------
; minit: the terminal cleared; nothing known shown; every row to be read.
; Keeps DE.
minit:  push de
        call hcls
        ld hl,mcbuf
        ld de,mcbuf+1
        ld bc,24*64-1
        ld (hl),' '
        ldir
        ld hl,msum
        ld de,msum+1
        ld bc,24*4-1
        ld (hl),0FFh            ; (no 256 bytes sum to FFFFh: see mrow)
        ldir
        xor a
        ld (mnext),a
        pop de
        ret

; mdone: the last owner went: the whole screen once more, then the
; console's line under it.
mdone:  ld a,1
        ld (mbusy),a
        ld b,24
.l:     push bc
        call mtick1
        pop bc
        djnz .l
        xor a
        ld (mbusy),a
        ld a,'Y'
        call hesc
        ld a,23+32
        call hout
        ld a,32
        call hout
        ld a,13
        call hout
        ld a,10
        call hout
        xor a
        ld (tcol),a
        ld (ttop),a             ; the console has the whole terminal again
        ld a,TROWS-1
        ld (trow),a
        ret

; mtick: from a tick while the screen is owned: MROWS rows.
; (Sending takes time, time runs stick: not into here again meanwhile.)
mtick:  ld a,(mbusy)
        or a
        ret nz
        inc a
        ld (mbusy),a
        ld b,MROWS
.l:     push bc
        call mtick1
        pop bc
        djnz .l
        xor a
        ld (mbusy),a
        ret

; myield: sys rele (a program's yield()): 8 rows, if it owns the screen.
myield: ld a,(scrown)
        or a
        ret z
        ld a,(mbusy)
        or a
        ret nz
        inc a
        ld (mbusy),a
        ld b,8
.l:     push bc
        call mtick1
        pop bc
        djnz .l
        xor a
        ld (mbusy),a
        ret

; mpoll: one row at every 4th system call (kpoll).
mpoll:  ld hl,mpcnt
        inc (hl)
        ld a,(hl)
        and 3
        ret nz
        ld a,(mbusy)
        or a
        ret nz
        inc a
        ld (mbusy),a
        call mtick1
        xor a
        ld (mbusy),a
        ret

; mtick1: the next row (mnext, round the 24).
mtick1: ld a,(ttop)             ; the rows above the console (24: all)
        or a
        jr nz,.t
        ld a,24
.t:     ld c,a
        ld a,(mnext)
        cp c
        jr c,.a
        xor a
.a:     push af
        inc a
        cp c
        jr c,.n
        xor a
.n:     ld (mnext),a
        pop af
; mrow: character row A.  If its pixels changed (checksum), every cell
; that does not show what the terminal shows is sent.
mrow:   ld (mr),a
        call mrowad             ; HL = its first pixel line
        ld bc,0                 ; Fletcher's sums, 16 bits each, over its
        ld de,0                 ; 8 x 32 bytes: BC += byte, DE += BC (a
        ld a,8                  ; byte counts by its place, so changes in
.ln:    push af                 ; different lines cannot cancel out)
        push hl
        ld a,32
.by:    ex af,af'
        ld a,(hl)
        add a,c
        ld c,a
        jr nc,.b1
        inc b
.b1:    ld a,e
        add a,c
        ld e,a
        ld a,d
        adc a,b
        ld d,a
        inc l
        ex af,af'
        dec a
        jr nz,.by
        pop hl
        inc h
        pop af
        dec a
        jr nz,.ln
        ld a,(mr)               ; the same as last time: nothing to do
        add a,a
        add a,a
        ld hl,msum
        call addhla
        push hl
        ld a,(hl)
        cp c
        jr nz,.ch
        inc hl
        ld a,(hl)
        cp b
        jr nz,.ch
        inc hl
        ld a,(hl)
        cp e
        jr nz,.ch
        inc hl
        ld a,(hl)
        cp d
        jr nz,.ch
        pop hl
        ret
.ch:    pop hl
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,0FFh               ; the terminal's cursor: not known in this row
        ld (mcc),a
        xor a
.c:     ld (mc),a               ; each cell
        call mcell              ; A = its character (bit 7: inverse)
        ld c,a
        ld a,(mr)               ; the terminal's: mcbuf[64 r + c]
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(mc)
        call addhla
        ld de,mcbuf
        add hl,de
        ld a,c
        cp (hl)
        jr z,.nx
        ld (hl),a
        call msend
.nx:    ld a,(mc)
        inc a
        cp 64
        jr c,.c
        ret

; mrowad: HL = the first pixel line of character row A.
mrowad: ld e,a
        and 18h
        ld h,a
        ld a,(dpage)            ; the display file's page (dalloc)
        add a,h
        ld h,a
        ld a,e
        rrca
        rrca
        rrca
        and 0E0h
        ld l,a
        ret

; mcell: A = the character in cell (mr, mc): ' ' when blank, '#' when it
; is no character of the font, bit 7 set when it is drawn inverse.
mcell:  ld a,(mr)
        call mrowad
        ld a,(mc)
        srl a                   ; the byte; CF: an odd column (low nibble)
        ld c,0
        jr nc,.e
        inc c
.e:     call addhla
        ld de,mglyph            ; 8 nibbles -> 4 bytes, as the font has them
        ld b,4
.p:     call .nib               ; upper row: the high nibble
        rlca
        rlca
        rlca
        rlca
        ld (de),a
        call .nib
        ex de,hl
        or (hl)
        ld (hl),a
        ex de,hl
        inc de
        djnz .p
        ld hl,mglyph            ; blank: a space
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        ld a,' '
        ret z
        call mfind
        ret nc
        ld hl,mglyph            ; inverse?
        ld b,4
.i:     ld a,(hl)
        cpl
        ld (hl),a
        inc hl
        djnz .i
        call mfind
        jr c,.no
        or 80h
        ret
.no:    ld a,'#'
        ret
; .nib: A = this pixel line's 4 pixels (low nibble); the next line.
.nib:   ld a,(hl)
        inc h
        bit 0,c
        jr nz,.lo
        rrca
        rrca
        rrca
        rrca
.lo:    and 0Fh
        ret

; mfind: the glyph at mglyph in the font: NC, A = its character; CF if
; it is none.  The hash first, then every glyph.
mfind:  call mhashg
        ld hl,mhash
        call addhla
        ld a,(hl)
        or a
        jr z,.all
        call mcmp
        ret z
.all:   ld a,32
.l:     call mcmp
        ret z
        inc a
        cp 128
        jr c,.l
        scf
        ret

; mcmp: Z (and NC) if character A's glyph is the one at mglyph.  Keeps A.
mcmp:   ld c,a
        sub 32
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,FONT
        add hl,de
        ld de,mglyph
        ld b,4
.c:     ld a,(de)
        cp (hl)
        jr nz,.x
        inc hl
        inc de
        djnz .c
.x:     ld a,c
        ret

; mhashg: A = a hash of the 4 bytes at mglyph.
mhashg: ld hl,mglyph
        ld a,(hl)
        ld b,3
.l:     inc hl
        rlca
        xor (hl)
        djnz .l
        ret

; mhinit: the hash table of the font's glyphs (hinit, once).
mhinit: ld a,32
.l:     push af
        sub 32
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,FONT
        add hl,de
        ld de,mglyph
        ld bc,4
        ldir
        call mhashg
        ld hl,mhash
        call addhla
        pop af
        ld b,(hl)
        inc b
        dec b
        jr nz,.n                ; taken: mfind's search finds it
        ld (hl),a
.n:     inc a
        cp 128
        jr c,.l
        ret

; msend: character A (bit 7: inverse) to cell (mr, mc) of the terminal.
msend:  ld c,a
        ld a,(mcc)              ; just right of the last one sent: no ESC Y
        ld b,a
        ld a,(mc)
        cp b
        jr z,.put
        ld a,'Y'
        call hesc
        ld a,(mr)
        add a,32
        call hout
        ld a,(mc)
        add a,32
        call hout
.put:   ld a,c
        bit 7,a
        jr z,.pl
        ld a,'L'
        call hesc
        ld a,c
        and 7Fh
        call .ch
        ld a,'M'
        call hesc
        jr .adv
.pl:    call .ch
.adv:   ld a,(mc)
        inc a
        ld (mcc),a
        ret
.ch:    cp 7Fh                  ; the Spectrum's (c): a c will do
        jr nz,.c1
        ld a,'c'
.c1:    jp hout

; ---------------------------------------------------------------------
mr:     db 0                    ; the cell being looked at
mc:     db 0
mcc:    db 0                    ; where the terminal's cursor is, in mr
mnext:  db 0                    ; the next row for mtick
mbusy:  db 0                    ; mtick at work
mpcnt:  db 0                    ; mpoll's system calls
mglyph: ds 4
msum:   ds 24*4                 ; each row's pixel checksum (two words)
mcbuf:  ds 24*64                ; what the terminal shows
mhash:  ds 256,0                ; glyph hash -> character

; sysdisp (41): the console - the terminal, 80 x 24 - and a display file
; for a program that draws: the old display file at 4000h, mirrored.
; HL = 0: describe; 1, 40h: claim.  -> D = page, E = 1 (a terminal),
; L = columns, H = rows.  (platform/screen-kinds.md)
sysdisp:
        ld a,h
        or l
        jr z,.d
        ld a,l
        cp 40h                  ; exactly 4000h: resident programs live there
        ld a,EBUSY
        jp z,syserr
        call dalloc
        jp c,syserr
.d:     ld a,(dpage)
        ld d,a
        ld e,1
        ld hl,24*256+80
        jp sysok

; dalloc: the display file, if there is none: 6,912 bytes on a page
; boundary, a fixed arena block (K_DISP), shared by every program that
; draws.  -> A = its page; CF, A = ENOMEM.
K_DISP  equ 7
dalloc: ld a,(dpage)
        or a
        ret nz
        ld bc,6912+255
        ld a,K_DISP
        call aalloc
        ret c
        push hl
        ld de,6912+255          ; not in a window lent to a big program
        add hl,de
        ld de,WINDOW+1
        call cphlde
        pop hl
        jr c,.ok
        call afree
        ld a,ENOMEM
        scf
        ret
.ok:    ld (dblk),hl
        ld de,255
        add hl,de
        ld a,h
        ld (dpage),a
        or a
        ret

; dfree: the display file back to the arena.
dfree:  ld hl,(dblk)
        ld a,h
        or l
        ret z
        call afree
        ld hl,0
        ld (dblk),hl
        xor a
        ld (dpage),a
        ret

dblk:   dw 0                    ; the display file's arena block
dpage:  db 0                    ; its page (0: none)
