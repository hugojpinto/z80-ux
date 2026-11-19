; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: @rfcall, the platform's float engine (platform/float.md):
; A = the operation, HL = x, DE = y, BC = the result -> CF: none.  Its
; address from system call 42, asked once.  No ROM fallback (libux's
; @fcall has one, for kernels without call 42): a kernel without the
; engine stops the program with report C; no room to load it, report 4.
        section text
        global @rfcall

@rfcall:
        push ix
        ld ix,@rws
        push af
        push hl
        ld hl,(@rfpe)
        ld a,h
        or l
        j nz,.k
        push bc
        push de
        ld a,SYS_FP
        call SYS
        pop de
        pop bc
        ld (@rfpe),hl
        j nc,.k
        cp ENOMEM               ; no room for it: 4 Out of memory
        ld a,R_OOM
        jp z,@rerr
        ld a,R_NONS             ; no float engine (a kernel without call 42)
        jp @rerr
.k:     ld (.c+1),hl
        pop hl
        pop af
.c:     call 0
        pop ix
        ret

        section bss
@rfpe:  ds 2
@rws:   ds 112
