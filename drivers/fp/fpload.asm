; =====================================================================
; z80-ux: the float interface (platform/float.md) on a machine without
; the 48 ROM.  The engine (fp.asm) is a module on the system disk
; (HAL_FPMOD, made by fsmod.py), loaded at a process's first system call
; 42 into a fixed arena block and shared; each process holding it has a
; bit in fpown (a child inherits its parent's); the block goes back to
; the arena when the last of them ends or execs.  Needs HAL_VFS (the
; module loader: fsmod.asm mhdr, mimg) and conbit (the slot's bit: unix.asm).
; =====================================================================

K_FPM   equ 8                   ; arena kind: the float engine (fixed)

; fpget: sys 42 -> HL = the engine; CF, A.
fpget:  ld hl,(fpblk)
        ld a,h
        or l
        jr nz,.own
        ld hl,s_fpmod
        call mhdr
        ret c
        ld a,K_FPM
        call mimg
        ret c
        ld (fpblk),hl
.own:   call conbit
        ld hl,fpown
        or (hl)
        ld (hl),a
        ld hl,(fpblk)
        or a
        ret

; fprel: the running process lets go (it ends, or execs).
fprel:  call conbit
        cpl
        ld hl,fpown
        and (hl)
        ld (hl),a
        ret nz
        ld hl,(fpblk)
        ld a,h
        or l
        ret z
        call afree
        ld hl,0
        ld (fpblk),hl
        ret

; fpfork: the child in slot C holds it if the parent does.  Keeps BC,
; DE, HL.
fpfork: push bc
        push hl
        call conbit
        ld hl,fpown
        and (hl)
        jr z,.x
        ld b,c
        inc b
        xor a
        scf
.l:     rla
        djnz .l
        or (hl)
        ld (hl),a
.x:     pop hl
        pop bc
        ret

fpblk:  dw 0                    ; the engine's block (0: not loaded)
fpown:  db 0                    ; the processes holding it, a bit each
s_fpmod: db HAL_FPMOD,0
