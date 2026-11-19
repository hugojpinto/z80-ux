; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  C support calls (ZX-UX v1, for programs from the ZX-UX SDK)
;   38 ticks    HL = 50 Hz frame counter
;   39 screen   HL = 1: the caller owns the screen (no status line, no
;               cursor) -> HL = the 4x8 font; HL = 0: give it back
;  Floats and BEEP need no kernel help: a program calls the ROM's
;  calculator itself, interrupts off, with STKBOT/STKEND/MEM pointing
;  into its own memory and ERR_SP at its own error handler (the kernel
;  never uses the calculator).  See sdk/lib/float.asm.
; =====================================================================

; systicks: 9 bytes. Ask the frame clock. It never takes sick leave.
systicks:
        ld hl,(fticks)
        ld de,0
        jp sysok

; sys screen (39): sysscreen, scrrel, cstrip are the console driver's
; (drivers/screen64; the FDD3000's display mirror, mirror.asm).

