; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; zx-ux: the resident programs' system call macro, out of ulib.asm and
; assembled before any of them - so that ulib, like the others, may be
; placed anywhere (build.py place()): a macro must be defined before its
; first use, wherever that is assembled.
; =====================================================================

        MACRO SC num
        ld a,num
        call SYS
        ENDM
