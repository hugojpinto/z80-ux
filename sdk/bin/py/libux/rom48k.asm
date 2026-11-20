; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; zx-ux (libux, rcc --rom48k): what of the C48 runtime may use the 48K
; ROM - its calculator when the kernel has no float engine (call 42), and
; its BEEP.  A program linked with these needs the ROM (SSX1 flags bit 5);
; norom.asm is the same without it.
ERRSP   equ 5C3Dh
STKBOT  equ 5C63h
STKEND  equ 5C65h
MEMV    equ 5C68h
MEMBOT  equ 5C92h
SYS     equ 6003h
        section text
        global @fpget,@inrom,_beep
; @inrom: 88 bytes. Borrow the ROM calculator, trap errors in carry, and restore its state.
@inrom: di
        push ix
        ex de,hl
        ld hl,(ERRSP)
        ld (@sv),hl
        ld hl,(STKBOT)
        ld (@sv+2),hl
        ld hl,(STKEND)
        ld (@sv+4),hl
        ld hl,(MEMV)
        ld (@sv+6),hl
        ld hl,@cstk
        ld (STKBOT),hl
        ld (STKEND),hl
        ld hl,@cmem
        ld (MEMV),hl
        ld hl,.err
        push hl
        ld (ERRSP),sp
        ld hl,.ret
        push hl
        ex de,hl
        jp (hl)
.err:   scf                     ; (the ROM reset SP to the trap's slot)
        push hl
.ret:   pop hl                  ; drop the trap address
        ld hl,(@sv)
        ld (ERRSP),hl
        ld hl,(@sv+2)
        ld (STKBOT),hl
        ld hl,(@sv+4)
        ld (STKEND),hl
        ld hl,(@sv+6)
        ld (MEMV),hl
        pop ix
        ei
        ret

; @fpush: 14 bytes. Push a five-byte value into the ROM calculator stack.
@fpush: ld de,(STKEND)
        ld bc,5
        ldir
        ld (STKEND),de
        ret
; @fpop: 18 bytes. Pop the calculator result into the address in @fx.
@fpop:  ld hl,(STKEND)
        ld bc,-5
        add hl,bc
        ld de,(@fx)
        ld bc,5
        ldir
        or a
        ret

; @fpget: system call 42 -> HL = the engine (@romfp without it).  Keeps
; BC, DE.
@fpget: push bc
        push de
        ld hl,0
        ld a,42
        call SYS
        j nc,.k
        ld hl,@romfp
.k:     ld (@fpe),hl
        pop de
        pop bc
        ret
; @romfp: the engine's interface on the 48 ROM's calculator, for a
; kernel without call 42 (the kernel's own: drivers/rom48).  IX: the
; four calculator pointers (8), its memory (30), its stack (60).
@romfp: push iy
        push bc
        push af
        ld iy,5C3Ah
        di
        push hl
        ld hl,(ERRSP)
        ld (ix+0),l
        ld (ix+1),h
        ld hl,(STKBOT)
        ld (ix+2),l
        ld (ix+3),h
        ld hl,(STKEND)
        ld (ix+4),l
        ld (ix+5),h
        ld hl,(MEMV)
        ld (ix+6),l
        ld (ix+7),h
        push ix
        pop hl
        ld bc,38
        add hl,bc
        ld (STKBOT),hl
        ld (STKEND),hl
        push ix
        pop hl
        ld bc,8
        add hl,bc
        ld (MEMV),hl
        pop hl
        push de
        call @fpush
        pop de
        pop af
        push af
        cp 6
        j nc,.one
        ex de,hl
        call @fpush
.one:   pop af
        ld hl,.err
        push hl
        ld (ERRSP),sp
        cp 18
        j z,.int
        ld hl,@ftab-1
        add a,l
        ld l,a
        j nc,.nc
        inc h
.nc:    ld a,(hl)
        ld (.code),a
        rst 28h
.code:  db 0,38h
        pop hl
        pop de
        ld hl,(STKEND)
        ld bc,-5
        add hl,bc
        ld bc,5
        ldir
        or a
        j .x
.int:   rst 28h
        db 3Ah,38h
        call 2DA2h              ; FP-TO-BC
        pop hl
        pop hl
        j c,.x
        ld a,0
        j z,.ip
        dec a
.ip:    or a
        j .x
.err:   pop hl
        scf
.x:     push af
        ld l,(ix+0)
        ld h,(ix+1)
        ld (ERRSP),hl
        ld l,(ix+2)
        ld h,(ix+3)
        ld (STKBOT),hl
        ld l,(ix+4)
        ld h,(ix+5)
        ld (STKEND),hl
        ld l,(ix+6)
        ld h,(ix+7)
        ld (MEMV),hl
        pop af
        pop iy
        ei
        ret
; @ftab: 17 data bytes. ROM operations 1..17, in C48 order.
@ftab:  db 0Fh,03h,04h,05h,06h,2Ah,1Bh,3Ah,26h,25h,1Fh,20h,21h,22h,23h,24h,28h

; _beep: 65 bytes. Play a ROM BEEP; return zero or one and yield an interrupt frame.
_beep:  ex de,hl
        pop bc
        pop hl
        push bc
        ld (@fx),hl
        ld (@fy),de
        ld hl,.go
        call @inrom
        ld hl,@mem0             ; Put the five saved MEMBOT bytes back after BEEP.
        ld de,MEMBOT            ; ROM reads this from 5C92h, not our scratch buffer.
        ld bc,5                 ; Preserve the entire five-byte system slot.
        ldir
        ei                      ; Let the clock and keyboard have their turn.
        halt                    ; One interrupt frame between notes.
        ld hl,0                 ; Zero means BEEP succeeded; carry says otherwise.
        ret nc
        inc l
        ret
; ROM BEEP reads pitch from MEMBOT (5C92h), even with MEM redirected.
; Save the caller's full five-byte slot before ROM BEEP overwrites it.
.go:    ld hl,MEMBOT
        ld (MEMV),hl
        ld de,@mem0
        ld bc,5
        ldir
        ld hl,(@fx)
        call @fpush
        ld hl,(@fy)
        call @fpush
        jp 03F8h                ; BEEP (ends in BEEPER: EI, RET)
        section bss
; @fx: 2 BSS bytes. Pointer to the first float operand.
@fx:    ds 2
; @fy: 2 BSS bytes. Pointer to the second float operand.
@fy:    ds 2
; @fo: 1 BSS byte. ROM calculator operation selector.
@fo:    ds 1
; @sv: 8 BSS bytes. Saved ROM error, stack and memory pointers.
@sv:    ds 8
; @mem0: 5 BSS bytes. Backup of the ROM's borrowed MEMBOT slot.
@mem0:  ds 5                    ; Restore this copy before interrupts get another turn.
; @cmem: 30 BSS bytes. Temporary ROM calculator workspace.
@cmem:  ds 30                   ; MEMV points here during ROM arithmetic.
; @cstk: 60 BSS bytes. Scratch stack for the ROM calculator.
@cstk:  ds 60                   ; The ROM calculator stack is private to this call.
