; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc (libux): room in the program's BASIC memory, in place of the 48K ROM's
; MAKE-ROOM (ONE-SPACE), RECLAIM-2 and BC-SPACES (RST 30h): bytes made or
; taken back inside the area the system variables VARS .. STKEND point
; into (the workspace, the calculator stack), every one of those pointers
; above the place moved with it.  Clean room: written from what they do,
; checked against the ROM's (test/basic/romdiff.py).
        section text
        global @r1652,@r1655,@r19E8,@r30,@rptrs

; @rptrs: the pointers VARS .. STKEND above HL moved by BC.  Keeps BC, HL.
@rptrs: push hl
        ld (@rwq),hl
        ld hl,VARS
        ld a,NPTRS
.l:     push af
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = the pointer, HL at its high byte
        push hl
        ld hl,(@rwq)
        or a
        sbc hl,de
        pop hl
        j nc,.n                 ; not above the place
        ex de,hl
        add hl,bc
        ex de,hl
        ld (hl),d
        dec hl
        ld (hl),e
        inc hl
.n:     inc hl
        pop af
        dec a
        j nz,.l
        pop hl
        ret

; ONE-SPACE: a byte made at HL.  MAKE-ROOM: BC bytes made at HL (the
; bytes from HL to the old STKEND, that one too, moved up; STKEND and the
; pointers above HL with them); 4 Out of memory without the room.
; -> HL = the place - 1, DE = the place + BC - 1, BC = 0.
@r1652: ld bc,1
@r1655: push hl
        call @rroom
        pop hl
        ld de,(STKEND)
        ld (@rwe),de            ; the old end
        call @rptrs
        ld (@rwc),bc
        ex de,hl                ; DE = the place
        ld hl,(@rwe)
        push hl
        or a
        sbc hl,de
        inc hl
        ld b,h                  ; the place .. the old end
        ld c,l
        pop hl
        push hl
        ld de,(@rwc)
        add hl,de
        ex de,hl                ; DE = the old end + the count
        pop hl
        lddr
        ret

; RECLAIM-2: the BC bytes from HL taken back (the bytes above, to the old
; STKEND, that one too, moved down; STKEND and the pointers above HL with
; them).  -> HL = the place, BC = 0.
@r19E8: ld (@rwp),hl
        ld (@rwc),bc
        ld de,(STKEND)
        ld (@rwe),de
        ld a,b                  ; -BC
        cpl
        ld b,a
        ld a,c
        cpl
        ld c,a
        inc bc
        call @rptrs
        ld hl,(@rwe)            ; the place .. the old end
        ld de,(@rwp)
        or a
        sbc hl,de
        inc hl
        ld b,h
        ld c,l
        ld hl,(@rwc)
        add hl,de               ; from the place + the count, to the place
        ldir
        ld hl,(@rwp)
        ret

; BC-SPACES (RST 30h): BC bytes at the end of the workspace (below the
; calculator stack; WORKSP kept) -> DE = the first of them.
@r30:   push bc
        ld hl,(WORKSP)
        push hl
        ld hl,(STKBOT)
        dec hl
        call @r1655             ; HL = the place - 1, DE = the place + BC - 1
        pop bc
        ld (WORKSP),bc
        pop bc
        inc hl
        inc hl
        ex de,hl                ; -> DE = the place + 1, HL = the place + BC
        inc hl
        ret

        section bss
@rwp:   ds 2                    ; the place
@rwc:   ds 2                    ; the count
@rwe:   ds 2                    ; the old end
@rwq:   ds 2
