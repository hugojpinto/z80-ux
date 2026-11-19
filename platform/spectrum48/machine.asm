; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  The 48K Spectrum's machine part: the frame ISR (IM 2 through the ROM's
;  FFh bytes at 3900h-3A00h and the trampoline at FFF4h) and the boot
;  set-up (sp_init, from HAL_INIT).  Keys, BREAK and the tape are rom48's,
;  the console screen64's; the rest of a tick is the kernel's ktick.
; =====================================================================

; sp_init: boot - IM 2, the ROM error trap, the keyboard's mode.
sp_init:
; IM 2: vector FFFFh from the ROM, JR at FFFF → JP isr at FFF4.
        ld a,0C3h
        ld (TRAMP),a
        ld hl,isr
        ld (TRAMP+1),hl
        ld a,018h
        ld (0FFFFh),a
        ld a,IM2I
        ld i,a
        im 2
; catch ROM errors (RST 8) instead of returning to BASIC. No victory lap on the error path.
        ld hl,rom_error
        ld (kerrsp),hl
        ld hl,kerrsp
        ld (SV_ERRSP),hl
; keyboard: L mode (lower case), repeat rates.
        set 3,(iy+1)            ; FLAGS: L mode.
        xor a
        ld (SV_MODE),a
        ret

; isr: 207 bytes. The frame clock gets its turn.
isr:
        push af
        push bc
        push de
        push hl
        push ix
        push iy
        ld iy,05C3Ah            ; ROM KEYBOARD / KEY-INPUT need it.
        exx
        ex af,af'
        push af
        push bc
        push de
        push hl
; keyboard - ROM KEYBOARD scans, KEY-INPUT decodes (modes, caps).
        call ROM_KEYBOARD
        ld a,(SV_TVFLAG)
        and 0D7h                ; never let KEY-INPUT touch the editor.
        ld (SV_TVFLAG),a
        set 3,(iy+1)            ; L mode.
        call ROM_KEYINPUT
        call c,ttrawin
; BREAK (CAPS SHIFT + SPACE) = interrupt (v1 DEL).
        call ROM_BREAKKEY       ; NC = pressed.
        sbc a,a                 ; FF released / 00 pressed.
        inc a                   ; 00 released / 01 pressed.
        ld hl,brkst
        cp (hl)
        ld (hl),a
        jr z,.b2
        or a
        call nz,ttintr
.b2:
; status line, cursor (not while programs own the whole screen).
        ld a,(ttop)             ; owners 1-0Fh, ttop 0 or 21.
        ld hl,scrown
        cp (hl)
        jr c,.nost
        ld a,(stdirty)
        or a
        call nz,stdraw
        call cblnk
.nost:
        call ktick              ; the kernel's part of the tick.
.x:
        pop hl
        pop de
        pop bc
        pop af
        ex af,af'
        exx
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        reti
