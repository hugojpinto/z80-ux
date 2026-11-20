; =====================================================================
; ZX-UX platform driver: IM 2 from a vector table in RAM.
; zx-ux+ (platform/README.md: interrupt vectors).
; =====================================================================
;
;  The 48K Spectrum's IM 2 needs no table: its ROM has 257 FFh bytes at
;  3900h-3A00h (rom48.inc IM2I) and spectrum48/machine.asm puts a JR at
;  FFFFh to the JP at FFF4h.  A machine with no such ROM - the TC2068 /
;  TS2068, a native TC3256, a 128K not trusting its ROMs, a 128K paging
;  RAM at 0000h - builds the table in RAM: 257 bytes of one value V at
;  page HAL_IM2TAB, and JP isr at V*257 (the address any vector there
;  reads).  With HAL_IM2TAB = 0FEh: the table at FE00h-FF00h, V = FDh, the
;  JP at FDFDh-FDFFh; the platform sets HAL_TOP to FDFDh, so the kernel's
;  CORE ends below it.
;
;  The platform sets HAL_IM2TAB, defines isr, includes this file in its
;  drivers, and calls im2init from its HAL_INIT, interrupts off.
; =====================================================================

IM2V    equ HAL_IM2TAB-1        ; the vector byte, filling the table
IM2JP   equ IM2V*257            ; where every vector points: JP isr
        ASSERT HAL_TOP <= IM2JP ; the kernel (CORE) stays below the JP ...
        ASSERT IM2JP+3 <= HAL_IM2TAB*256  ; ... which stays below the table

; im2init: the table, the JP, I, IM 2.
im2init:
        ld hl,HAL_IM2TAB*256
        ld (hl),IM2V
        ld d,h
        ld e,l
        inc de
        ld bc,256
        ldir
        ld a,0C3h               ; jp isr
        ld (IM2JP),a
        ld hl,isr
        ld (IM2JP+1),hl
        ld a,HAL_IM2TAB
        ld i,a
        im 2
        ret
