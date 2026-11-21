; =====================================================================
; ZX-UX on the Timex TC3256, started from disk: the machine layer.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
; The boot menu's "4. Disk start" has TOS load the file BOOT's first
; 16 KB at 8000h, sets FIRMWARE (the MMU's port EEh, bit 7: RAM at
; 0000h-3FFFh) and copies them to 0000h, entering at 0001h with
; interrupts off (platform/tc3256.md).  Those 16 KB are this layer and
; the resident programs placed with it; tcboot reads the rest of BOOT -
; the low kernel, the kernel, the root file system - through TOS into
; place, and starts the kernel.
;
; The machine as the layer drives it:
;  - an opcode fetch at 0000h, 0008h or 0066h pages the shadow ROM in:
;    nothing here runs there, and no program may RST 0 or RST 8;
;  - the SCLD's frame interrupt, 50 a second, IM 1 at 0038h: the keys
;    (kbd.asm), the console (screen64's s64tick), the kernel (ktick);
;  - the keyboard: the Spectrum's matrix on port FEh (kbd.asm), clean
;    room; the display at 4000h (screen64); the speaker FEh bit 4;
;  - the FDD3000, TOS's disk server, over the link on port EFh
;    (link.asm, user mode).
; =====================================================================

        org 0
        db 0                    ; 0000h: never run (a fetch here is RST 0)
        jp tcboot               ; 0001h: Disk start enters here
        ds 0010h-$              ; 0008h: RST 8 is the shadow ROM's
        di                      ; RST 10h-30h: a program wants the ROM
        ld a,10h
        jp htrap
        ds 0018h-$
        di
        ld a,18h
        jp htrap
        ds 0020h-$
        di
        ld a,20h
        jp htrap
        ds 0028h-$
        di
        ld a,28h
        jp htrap
        ds 0030h-$
        di
        ld a,30h
        jp htrap
        ds 0038h-$
        jp isr                  ; 0038h: the frame interrupt (IM 1)
        ds 0068h-$              ; 0066h: the network's NMI, the shadow ROM's
halstart:

; ---------------------------------------------------------------------
; tcboot: Disk start's entry.  The rest of BOOT (past the 16 KB TOS
; gave, and past its CODE header) is the memory from LOWK up: read it
; there, block by block, to the file's end; then the kernel.  A link
; failure: the border red, stopped.
; ---------------------------------------------------------------------
TC_FREECH equ 12h               ; TOS's functions (TOS_Technical_Reference_v2.md §10)
TC_OPENF  equ 00h
TC_CLOSEF equ 01h
TC_READF  equ 10h
TC_MORE   equ 48h               ; READF's status: 0, or this: both a block read
TC_LEN    equ 1                 ; the CODE header: type, then the length
TC_READ   equ 0101h             ; OPENF's DE: for reading
TC_HDR    equ 5                 ; a CODE file's header: type, length, start
TC_LOW    equ 4000h             ; what Disk start loads of BOOT
TC_RED    equ 2
tcboot: di
        ld sp,0                 ; (the window's page: nothing loaded there)
        call clrcom
        ld a,TC_FREECH
        ld (lkcom+LKC_F),a
        call lkcmd
        jp nz,.fail
        jp c,.fail
        ld a,(lkcom+LKC_B)
        ld (tcchan),a
        ld hl,s_boot            ; the name
        ld de,lkdat
        ld bc,s_bootl
        ldir
        ld a,LK_DATA
        ld b,s_bootl
        ld hl,lkdat
        call lksend
        jp c,.fail
        call clrcom
        ld a,TC_OPENF
        ld (lkcom+LKC_F),a
        ld a,(tcchan)
        ld (lkcom+LKC_A),a
        ld hl,TC_READ
        ld (lkcom+LKC_E),hl
        call lkcmd
        jp nz,.fail
        jp c,.fail
        ld de,TC_HDR            ; the CODE header: its length
        call tcread
        jp c,.fail
        ld hl,(lkdat+TC_LEN)
        ld de,TC_LOW            ; less what Disk start loaded
        or a
        sbc hl,de
        jp c,.fail
        ld (tcleft),hl
        ld hl,TC_LOW            ; pass over that
.skip:  ld a,h
        or l
        jr z,.rest
        call tcchunk
        push hl
        push de
        call tcread
        pop de
        pop hl
        jp c,.fail
        or a
        sbc hl,de
        jr .skip
.rest:  ld de,LOWK              ; the rest into place
.r:     ld hl,(tcleft)
        ld a,h
        or l
        jr z,.done
        push de
        call tcchunk
        or a
        sbc hl,de
        ld (tcleft),hl
        call tcread
        pop de
        jp c,.fail
        ld hl,lkdat
        ld a,b
        or c
        jp z,.fail              ; nothing: the file is shorter than it says
        ldir
        jr .r
.done:
        call clrcom
        ld a,TC_CLOSEF
        ld (lkcom+LKC_F),a
        ld a,(tcchan)
        ld (lkcom+LKC_A),a
        call lkcmd
        jp boot
.fail:  ld a,TC_RED
        out (0FEh),a
.h:     jr .h

; tcchunk: DE = HL, or 256 if HL is more (a READF's most).  Keeps HL.
tcchunk: ld de,256
        ld a,h
        or a
        ret nz
        ld e,l
        ld d,0
        ret

; tcread: READF of DE bytes (256 at most) on tcchan -> the bytes in lkdat,
; BC = how many; CF: the link failed or TOS refused (its status neither 0
; nor TC_MORE: the shadow ROM's RDMEM takes both, and counts the bytes).
tcread: call clrcom
        ld a,TC_READF
        ld (lkcom+LKC_F),a
        ld a,(tcchan)
        ld (lkcom+LKC_B),a
        ld (lkcom+LKC_E),de
        call lkcmd
        ret c
        ld bc,(lkcom+LKC_E)     ; the count
        cp TC_MORE
        ret z
        or a
        ret z
        scf
        ret

; clrcom: lkcom all 0
clrcom: ld hl,lkcom
        ld b,LKCLEN
.c:     ld (hl),0
        inc hl
        djnz .c
        ret

s_boot: db "BOOT",0             ; Disk start's file
s_bootl equ $-s_boot
tcchan: db 0
tcleft: dw 0                    ; the rest's bytes still to read

; ---------------------------------------------------------------------
; hinit: the kernel's boot (HAL_INIT): the frame interrupt, IM 1; the
; border black, as a terminal's (the boot menu left it white) - BORDCR
; too, which the click and the beeper write the port with.
; ---------------------------------------------------------------------
TC_BORDER equ 0                 ; black
TC_INK    equ 7                 ; BORDCR's ink, white (bits 2-0; the border 5-3)
hinit:  im 1
        ld a,1                  ; the link may let interrupts in between blocks
        ld (lkint),a
        ld a,TC_BORDER
        out (0FEh),a
        ld a,TC_BORDER << 3 | TC_INK
        ld (SV_BORDCR),a
        ret

; isr: the frame interrupt (IM 1, 0038h).  While a link block moves
; (lkbusy, link.asm) only its tick is counted, for lktick.
isr:    push af
        ld a,(lkbusy)
        or a
        jr nz,.held
        push bc
        push de
        push hl
        push ix
        push iy
        ld iy,KIY
        exx
        ex af,af'
        push af
        push bc
        push de
        push hl
        call rstx               ; RS-232 bytes out: first (rs232.asm)
        call kbtick             ; the keys and BREAK (kbd.asm)
        call s64tick            ; the status line and the cursor (screen64)
        call ktick              ; the kernel's part of the tick
        pop hl
        pop de
        pop bc
        pop af
        ex af,af'
        exx
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        ret
.held:  push bc                  ; the keys: their matrix queued (kbd.asm)
        push de
        push hl
        call kbheld
        pop hl
        pop de
        pop bc
        ld a,(lkpend)
        inc a
        ld (lkpend),a
        pop af
        ei
        ret

; lktick: the frames a link command held (lkpend), now that it is done
; (TOS waits for the next): the keys they queued (kbdrain), then the
; kernel's tick for each.  Interrupts off (lkei turns them on).  Keeps
; every register.
lktick: di
        push bc
        push de
        push hl
        push ix
        push iy
        ld iy,KIY
        exx
        ex af,af'
        push af
        push bc
        push de
        push hl
        call kbdrain
.t:     ld a,(lkpend)
        or a
        jr z,.e
        dec a
        ld (lkpend),a
        call ktick
        jr .t
.e:     pop hl
        pop de
        pop bc
        pop af
        ex af,af'
        exx
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        ret

; ---------------------------------------------------------------------
; The speaker: port FEh bit 4, the border's colour kept.
; kclick: the key click (ttrawin).  snd_beep: a tone - DE cycles, HL the
; half cycle's length in the 48K ROM's BEEPER's units (about 4 T-states
; each: the console's bell, screen64).
; ---------------------------------------------------------------------
SPKR    equ 10h
CLICKT  equ 40                  ; the click's length (DJNZ passes)
BEEPSH  equ 3                   ; BEEPER's units to delay-loop passes (26 T): / 8
kclick: ld a,(SV_BORDCR)
        rrca
        rrca
        rrca
        and 7
        or SPKR
        out (0FEh),a
        ld b,CLICKT
.c:     djnz .c
        and 7
        out (0FEh),a
        ret

snd_beep:
        di
        ld b,BEEPSH
.sh:    srl h
        rr l
        djnz .sh
        ld a,h
        or l
        jr nz,.h
        inc l
.h:     ld (sbhalf),hl
        ld a,(SV_BORDCR)
        rrca
        rrca
        rrca
        and 7
        ld c,a
.cy:    ld a,d
        or e
        ret z
        ld a,c
        or SPKR
        out (0FEh),a
        call .half
        ld a,c
        out (0FEh),a
        call .half
        dec de
        jr .cy
.half:  ld hl,(sbhalf)
.dl:    dec hl
        ld a,h
        or l
        jr nz,.dl
        ret
sbhalf: dw 0

; ---------------------------------------------------------------------
; htrap: RST n (A = n), n from 10h: a program wants the Spectrum's ROM -
; stopped with a message; in the kernel, a panic.
; ---------------------------------------------------------------------
htrap:  push af
        ld a,(inkern)
        or a
        jr nz,.k
        pop af
        ld hl,trapmsg+4
        call hhex
        ld hl,trapmsg
        call kputs
        call kmode
        jp sigck.xj0_11         ; exit, as if killed
.k:     pop af
        ld sp,KSTACK
        ld hl,trapmsg+4
        call hhex
        ld hl,trapmsg
        jp panic
trapmsg: db "rst ??h: no Spectrum ROM here",10,0

; hhex: A -> two hex digits at HL.
hhex:   push af
        rrca
        rrca
        rrca
        rrca
        call .d
        pop af
.d:     and 0Fh
        add a,90h
        daa
        adc a,40h
        daa
        ld (hl),a
        inc hl
        ret

; devtab: the TC3256's devices (dev.asm)
devtab: db DEV_TTY, DEV_TTY
        dw ttread, ttwrite, 0
        db 0
        db DEV_MEM, DEV_MEM
        dw memrd, memwr, 0
        db 0
        db DEV_TTY1, DEV_TTY1           ; /dev/tty1: RS-232 (rs232.asm)
        dw ttread, ttwrite, ttopen
        db 0
        db DEV_FD0, DEV_FD0+NDRV-1      ; /dev/fd0-3 (tosdisk.asm, blk.asm)
        dw fdread, fdwrite, hdopen
        db 0
        db 0

        include "kbd.asm"       ; the keyboard, clean room
        include "vt52.asm"      ; the terminals' language (drivers/vt52)
        include "rs232.asm"     ; the second terminal, RS-232
        include "screen64.asm"  ; the console on the screen; sys screen
        include "link.asm"      ; the FDD3000 link: the boot, the disks
        include "tosdisk.asm"   ; the disks through TOS ...
        include "blk.asm"       ; ... their cache and devices (drivers/blk)
        include "vfs.asm"       ; mounted file systems ...
        include "fsmod.asm"     ; ... of types built in or loaded ...
        include "zfs.asm"       ; ... ZXFS, built in.
        include "ssx.asm"       ; SSX1 programs from files.
        include "fpload.asm"    ; the float engine, a module (sys 42).
        include "font8.inc"     ; the 8x8 font (drivers/font8)

        ALIGN 256
BUFMEM:                         ; the disks' cache (blk.asm): NBUF sectors
        ds NBUF*256
proctab: ds PTSZ                ; the process table (kvars.inc): a page's start
ttyarea: ds TTSZ                ; the terminals' rings and line states (kvars.inc)

halend:

; ---------------------------------------------------------------------
; Resident program text: the rest of the low 16 KB (build.py place()).
; ---------------------------------------------------------------------
TX0     equ halend
TX0_LIM equ TC_LOW
        org TX0
        include "text0.inc"
tx0end:
        ASSERT tx0end <= TX0_LIM
        SAVEBIN "low.bin", 0, tx0end
