; =====================================================================
; ZX-UX's console language on a VT52 terminal: shared.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; zx-ux: LoadZX Museum.  Non-commercial use only: see ../../LICENSE.
; =====================================================================
;
;  A terminal, not a screen (platform/terminals.md): the FDD3000's console
;  (the Timex terminal on the link) and any machine's serial terminals
;  (/dev/tty1 ...).  ZX-UX writes 64 columns and 23 text rows; a VT52 has
;  80 x 24, so the text keeps its Spectrum geometry (lines wrap at column
;  64) and AT row,col lands where it did.
;    16h AT r,c  -> ESC Y r+32 c+32      14h INVERSE n -> ESC L / ESC M
;    0Ch (cls)   -> ESC H ESC J          0Ah -> CR LF     08h, 07h as they are
;    09h TAB to the next column of 8     7Fh (the Spectrum's (c)) -> "(c)"
;    10h, 11h, 13h INK, PAPER, BRIGHT n: no colour - taken and dropped
;  The terminal is the one whose line state is loaded (ttyc: dev.asm's
;  ttsel swaps the AT state, ttat .. ttp1, with the rest); its position
;  is kept here (vtpos: not trow and tcol, which are a screen console's,
;  its cursor's in the frame interrupt).  Its bytes go out through the
;  platform's ttput (A to terminal C, as it is).  Its keys come in
;  through vtkey.
; =====================================================================

VT_COLS equ 64                  ; the Spectrum console's columns

; vtputc: A = a character or a control (kputc's language) to the terminal
; in use.  Keeps every register.
vtputc: push hl
        push de
        push bc
        push af
        ld hl,ttat
        inc (hl)
        dec (hl)
        jr nz,.prm
        cp 16h                  ; AT row,col.
        jr z,.at
        cp 14h                  ; INVERSE n.
        jr z,.inv
        cp 10h                  ; INK, PAPER, BRIGHT n: no colour on the
        jr z,.inv               ; terminal - taken, and dropped
        cp 11h
        jr z,.inv
        cp 13h
        jr z,.inv
        cp 10
        jr z,.nl
        cp 9
        jr z,.tab
        cp 8
        jr z,.bs
        cp 12
        jr z,.ff
        cp 7
        jr z,.raw
        cp 7Fh
        jr z,.copy
        jr nc,.x
        cp 20h
        call nc,vtcol
.x:     pop af
        pop bc
        pop de
        pop hl
        ret
.nl:    call vtnl
        jr .x
.ff:    call vtcls
        jr .x
.raw:   call vtout
        jr .x
.bs:    call vtpc
        ld a,(hl)
        or a
        jr z,.x
        dec (hl)
        ld a,8
        jr .raw
.tab:   ld a,' '
        call vtcol
        call vtpc
        ld a,(hl)
        and 7
        jr nz,.tab
        jr .x
.copy:  ld hl,s_copy
.cp:    ld a,(hl)
        or a
        jr z,.x
        push hl
        call vtcol
        pop hl
        inc hl
        jr .cp
.at:    ld (hl),2
        jr .ctl
.inv:   ld (hl),1
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
        jr nz,.x                ; (INK, PAPER, BRIGHT)
        ld a,c                  ; INVERSE 0/1: bit 0.
        rrca
        ld a,'M'
        jr nc,.esc
        ld a,'L'
.esc:   call vtesc
        jr .x
.pat:   ld a,(ttp1)             ; AT: text rows and columns only.
        cp TROWS
        jr nc,.x
        ld b,a
        ld a,c
        cp VT_COLS
        jr nc,.x
        call vtp
        ld (hl),b
        inc hl
        ld (hl),c
        ld a,'Y'
        call vtesc
        ld a,b
        add a,32
        call vtout
        ld a,c
        add a,32
        jr .raw
s_copy: db "(c)",0

; vtcol: print A in the next column; wrap after the last.
vtcol:  call vtout
        call vtpc
        inc (hl)
        ld a,(hl)
        cp VT_COLS
        ret c
; vtnl: a new line.
vtnl:   call vtp
        ld a,(hl)
        inc hl
        ld (hl),0               ; column 0
        dec hl
        cp TROWS-1
        jr nc,.b
        inc (hl)
.b:     ld a,13
        call vtout
        ld a,10
        jr vtout

; vtcls: clear the terminal, home the cursor.
vtcls:  call vtp
        xor a
        ld (hl),a
        inc hl
        ld (hl),a
        ld a,'H'
        call vtesc
        ld a,'J'
; vtesc: ESC, then A.
vtesc:  push af
        ld a,1Bh
        call vtout
        pop af
; vtout: A to the terminal in use, as it is (the platform's ttput).
; Keeps BC, DE, HL.
vtout:  push bc
        push de
        push hl
        ld c,a
        IF NTTY > 1
        ld a,(ttyc)
        ELSE
        xor a
        ENDIF
        ld b,a
        ld a,c
        ld c,b
        call ttput
        pop hl
        pop de
        pop bc
        ret

; vtp: HL = the terminal in use's position, its row (then its column:
; vtpc).  Keeps the rest.
vtpc:   call vtp
        inc hl
        ret
vtp:    push af
        IF NTTY > 1
        ld a,(ttyc)
        add a,a
        ELSE
        xor a
        ENDIF
        ld hl,vtpos
        call addhla
        pop af
        ret
vtpos:  ds 2*NTTY               ; each terminal's row, column

; ---------------------------------------------------------------------
; Keys.  A VT52's codes become the ones ZX-UX's line discipline knows
; (dev.asm ttrawn):
;   CR, LF -> 0Dh ENTER     BS, DEL -> 0Ch DELETE
;   ESC, ^D -> 07h (EDIT: vi's escape, end of file on a line)
;   ^C -> BREAK: the terminal's live processes get the interrupt (ttintn).
; ---------------------------------------------------------------------
; vtkey: key A from terminal E.  Uses A, BC, DE, HL.
vtkey:  cp 03h
        jp z,ttintn
        ld hl,vtkeys
.k:     ld c,(hl)
        inc c
        dec c
        jp z,ttrawn
        inc hl
        cp c
        ld c,(hl)
        inc hl
        jr nz,.k
        ld a,c
        jp ttrawn
vtkeys: db 0Dh,0Dh, 0Ah,0Dh, 08h,0Ch, 7Fh,0Ch, 1Bh,07h, 04h,07h, 0
