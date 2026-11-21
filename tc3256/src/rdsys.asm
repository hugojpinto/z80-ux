; =====================================================================
; ZX-UX on the Timex TC3256: the RAM disk's system-mode part.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
; The RAM disk's 4 KB sectors are seen only in system mode, one at a time
; at 3000h-3FFFh, the shadow ROM at 0000h-2FFFh (the MMU guide, §4, §9.2):
; this code and the 256 bytes it moves through are above 4000h, here -
; assembled after the kernel (HAL_DRIVERS).  rdsys: in through the
; gateway (CALL 0008h with IY = 0: system mode, interrupts off), the
; sector chosen (port EDh), the window opened (EEh bit 6, read-modify-
; write), 256 bytes copied, the window closed again (the next entry would
; find it open, hiding the shadow ROM's own code: rule 5), out through
; 0604h.  Interrupts stay off: the caller turns them on (lkei).
; =====================================================================

MMU_EE  equ 0EEh                ; the MMU: what is on the stage
MMU_ED  equ 0EDh                ; ... the RAM disk's sector in the window
MMU_SEC equ 40h                 ; EEh bit 6: the window open
RD_WIN  equ 3000h               ; the window (system mode)
RD_GATE equ 0008h               ; the shadow ROM: the gateway's trap
RD_OUT  equ 0604h               ; ... its RET, out of system mode

; rdsys: rdbounce <-> 256 bytes of RAM disk sector (rdsec), at block
; rdoff (0-15) of it: rddir 0 reads into rdbounce, 1 writes from it.
rdsys:  push iy
        ld iy,0
        call RD_GATE
        pop iy
        ld a,(rdsec)
        out (MMU_ED),a
        in a,(MMU_EE)
        or MMU_SEC
        out (MMU_EE),a
        ld a,(rdoff)
        add a,high RD_WIN
        ld h,a
        ld l,0
        ld de,rdbounce
        ld a,(rddir)
        or a
        jr z,.cp
        ex de,hl
.cp:    ld bc,256
        ldir
        in a,(MMU_EE)
        and ~MMU_SEC & 0FFh
        out (MMU_EE),a
        jp RD_OUT               ; RET: rdsys's caller, in user mode

rdsec:  db 0
rdoff:  db 0
rddir:  db 0
rdbounce: ds 256
