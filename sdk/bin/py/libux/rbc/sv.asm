; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: @rsv, the BASIC system variables, in the program: the
; Spectrum's layout (its 5C00h + n at @rsv + n; rbc/ux.py rewrites the
; compiled program's references), IY = @rsv + ERRNR.  Each program its
; own: two at once do not share them, and a machine without the ROM's
; memory map has nothing at 5C00h to share.  @rinit sets them up.
        section bss
        global @rsv
@rsv:   ds SVSIZE
