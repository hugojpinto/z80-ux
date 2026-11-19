; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  The 48K Spectrum's machine part: the frame ISR (IM 2 through the ROM's
;  FFh bytes at 3900h-3A00h and the trampoline at FFF4h) and the boot
;  set-up (sp_init, from HAL_INIT).  A tick: the keys (rom48's r48keys),
;  the console's (screen64's s64tick), the kernel's (ktick).  A machine
;  with screen64 but another keyboard (TC2068, a native TC3256) writes its
;  own keys routine for ttrawin and ttintr and keeps the rest.
; =====================================================================

TRAMP   equ HAL_TOP         ; the JP isr, above the kernel (platform.inc)

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
        ld iy,KIY               ; (rom48's routines need the ROM's IY)
        exx
        ex af,af'
        push af
        push bc
        push de
        push hl
        call r48keys            ; keys and BREAK (rom48)
        call s64tick            ; the status line and the cursor (screen64)
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

; devtab: the Spectrum's devices (dev.asm).
devtab: db DEV_TTY, DEV_TTY
        dw ttread, ttwrite, 0
        db DEV_MEM, DEV_MEM
        dw memrd, memwr, 0
        db DEV_TAP, DEV_TAP     ; /dev/tap, /dev/cassette (rom48)
        dw taprd, tapwr, 0
        db 0
