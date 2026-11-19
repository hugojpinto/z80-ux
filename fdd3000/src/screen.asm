; =====================================================================
; ZX-UX on the Timex FDD3000: no screen - a terminal.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  The FDD3000's console is a VT52 terminal on the link: text, no pixels.
;  Programs that print - the stream and console kinds, a BASIC program's
;  32 columns (platform/screen-kinds.md) - run; a program that draws (the
;  bitmap or fixed kind, or older and undeclared) is refused at load
;  (ssx.asm: "this program draws: it needs a screen").  So there is no
;  display file to claim: system call 39 refuses the claim, call 41 says
;  the console is a terminal with none.
; =====================================================================

; ---------------------------------------------------------------------
; sys screen (39): HL = 1, a claim: EINVAL (none here); HL = 0, a
; release: nothing to give back.
; ---------------------------------------------------------------------
sysscreen:
        ld a,h
        or l
        jp z,sysok
        ld a,EINVAL
        jp syserr

; scrrel: the running process lets go of the screen (also when it ends:
; release): it holds none.
scrrel: ret

; mbit: A = the running slot's bit (slot 0 = 1).  Uses B.
mbit:   ld a,(cur)
        ld b,a
        inc b
        xor a
        scf
.l:     rla
        djnz .l
        ret

; sysdisp (41): HL = 0: describe -> D = 0 (no display file), E = 1 (a
; terminal), L = columns (80; 32 for a narrow console), H = rows; HL = 1,
; 40h, a claim: EINVAL.  (platform/screen-kinds.md)
sysdisp:
        ld a,h
        or l
        ld a,EINVAL
        jp nz,syserr
        call connar
        ld de,1
        ld hl,24*256+80
        jp z,sysok
        ld l,32
        jp sysok
