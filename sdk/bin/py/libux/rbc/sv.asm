; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: @rsv, the BASIC system variables (the Spectrum's layout: 5C00h
; + n).  The compiled program and libux/rbc's routines name them as @rsv+n
; (IY = @rsv+3Ah).  Here still the ROM's own place, while routines of the
; ROM are still linked (librom.ssa); then a block in the program.
        global @rsv
@rsv     equ 5C00h
