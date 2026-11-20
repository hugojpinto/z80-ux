; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): @rsv, the BASIC system variables, in the program: the
; Spectrum's layout (its 5C00h + n at @rsv + n; rbc/ux.py rewrites the
; compiled program's references), IY = @rsv + ERRNR.  Each program its
; own: two at once do not share them, and a machine without the ROM's
; memory map has nothing at 5C00h to share.  @rinit sets them up.
        section text
        global @rsvini
; @rsvini: the system variables as a Spectrum has them after CLS - KSTATE
; no key, the lower screen two lines, the colours ATTR_INIT - with the
; workspace and the calculator stack from the program's end (towards its
; stack; a wrapper with its own area sets that).
@rsvini:
        ld hl,@rsv              ; the system variables: as a Spectrum
        ld b,SVSIZE             ; has them after CLS - KSTATE no key, the
.z:     ld (hl),0               ; lower screen two lines, the positions
        inc hl                  ; top left (the display file's own page
        djnz .z                 ; first, below)
        ld hl,KSTATE
        ld b,8
.ks:    ld (hl),0FFh
        inc hl
        djnz .ks
        ld a,0FFh
        ld (ERRNR),a
        ld a,LOWER
        ld (DFSZ),a
        ld a,ATTR_INIT
        ld (BORDCR),a
        ld (ATTRP),a
        ld a,1
        ld (SCRCT),a
        ld hl,MEMBOT
        ld (MEMV),hl
        ld hl,@end              ; the workspace and the calculator stack:
        ld (WORKSP),hl          ; past the program, up towards its stack
        ld (STKBOT),hl          ; (a wrapper with its own area sets that)
        ld (STKEND),hl
        ret

        section bss
        global @rsv
@rsv:   ds SVSIZE
