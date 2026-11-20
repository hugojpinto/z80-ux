; =====================================================================
; ZX-UX on the Timex TC3256: phase 0's probe (platform/tc3256.md §7).
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; TC3256 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; A BOOT file for the boot menu's "4. Disk start": 16 KB that the shadow
; ROM loads at 8000h, copies to 0000h (FIRMWARE: RAM there) and enters at
; 0001h.  It records, at RES, what tc3256run.py reads back:
;   +00  "P0" when it got to the end
;   +02  SP as it came;  +04 the flags (P/V: IFF2) and I, from LD A,I
;   +06  port EEh as it reads in user mode
;   +08  the 4 bytes at C000h before anything wrote there: the file's
;        bytes past 16 KB if LOADP loaded more than it was asked for
;   +10  TOS's version (GETVER, 17h): CF (FFh: the link failed), status;
;        +20 the reply (13 bytes: function, AF, BC, DE, HL, IX, IY)
;   +30  RXSEC (1Bh) drive 0, track 0, sector 0: CF, status, data length;
;        +100h its 256 bytes
;   +33  RXSEC track 4 (TOS's directory), sector 0: CF, status, length;
;        +200h its bytes
;   +36  TXSEC (1Ch) drive 0, track WTRACK, sector WSEC (an unused one):
;        CF, status; then RXSEC of it: CF, status, length; +300h its bytes
;        (written: 0, 1, 2 ... 255)
;   +40  the gateway (CALL 0008h with IY = 0, from 4000h up): EEh in
;        system mode, the byte at 0000h there (the shadow ROM's), the byte
;        at 0001h back in user mode (this file's), AAh when back
; - all in user mode, the link driven by tc3256/src/link.asm.
; =====================================================================

        DEVICE NOSLOT64K
RES     equ 0C100h
GW      equ 0C800h              ; the gateway's code: at 4000h or above
WTRACK  equ 39                  ; a sector to write: the last track's last
WSEC    equ 15                  ; (a new disk's: unused)

        org 0
        db 0                    ; 0000h: a fetch here is RST 0 (the shadow ROM)
        jp start                ; 0001h: Disk start's entry
        ds 0038h-$
        ei                      ; 0038h: the frame interrupt (IM 1)
        ret
        ds 0066h-$
        retn                    ; (an NMI traps into the shadow ROM anyway)
        ds 0100h-$

start:  ld (RES+2),sp
        ld sp,0FF00h
        ld hl,(0C000h)          ; past 16 KB: before anything writes there
        ld (RES+8),hl
        ld hl,(0C002h)
        ld (RES+10),hl
        ld a,i
        push af
        pop hl
        ld (RES+4),hl
        in a,(0EEh)
        ld (RES+6),a
        ld hl,5800h             ; to see it ran: the attributes cyan
        ld de,5801h
        ld bc,767
        ld (hl),28h
        ldir

        call clrcom             ; TOS's version
        ld a,17h
        ld (lkcom+LKC_F),a
        call lkcmd
        ld hl,RES+10h
        call result
        ld hl,lkcom
        ld de,RES+20h
        ld bc,LKCLEN
        ldir

        call clrcom             ; drive 0, track 0, sector 0
        ld a,1Bh
        ld (lkcom+LKC_F),a
        call lkcmd
        ld hl,RES+30h
        call result
        ld a,(lkdlen)
        ld (RES+32h),a
        ld hl,lkdat
        ld de,RES+100h
        ld bc,256
        ldir

        call clrcom             ; track 4, sector 0
        ld a,1Bh
        ld (lkcom+LKC_F),a
        ld a,4
        ld (lkcom+LKC_D),a
        call lkcmd
        ld hl,RES+33h
        call result
        ld a,(lkdlen)
        ld (RES+35h),a
        ld hl,lkdat
        ld de,RES+200h
        ld bc,256
        ldir

        ld hl,lkdat             ; a sector written: 0, 1, ... 255
        xor a
.fill:  ld (hl),a
        inc hl
        inc a
        jr nz,.fill
        ld a,LK_DATA            ; the data first, then the command
        ld b,0
        ld hl,lkdat
        call lksend
        jr c,.wf
        call clrcom
        ld a,1Ch
        ld (lkcom+LKC_F),a
        ld a,WTRACK
        ld (lkcom+LKC_D),a
        ld a,WSEC
        ld (lkcom+LKC_E),a
        call lkcmd
.wf:    ld hl,RES+36h
        call result
        ld hl,lkdat             ; and read back
        ld b,0
.clr:   ld (hl),0FFh
        inc hl
        djnz .clr
        call clrcom
        ld a,1Bh
        ld (lkcom+LKC_F),a
        ld a,WTRACK
        ld (lkcom+LKC_D),a
        ld a,WSEC
        ld (lkcom+LKC_E),a
        call lkcmd
        ld hl,RES+38h
        call result
        ld a,(lkdlen)
        ld (RES+3Ah),a
        ld hl,lkdat
        ld de,RES+300h
        ld bc,256
        ldir

        ld hl,gwsrc             ; the gateway
        ld de,GW
        ld bc,gwlen
        ldir
        call GW

        ld hl,'P'+256*'0'
        ld (RES),hl
.halt:  jr .halt

; result: CF and A of lkcmd -> (HL) = FFh / 0, (HL+1) = A
result: push af
        sbc a,a
        ld (hl),a
        inc hl
        pop af
        ld (hl),a
        ret

; clrcom: lkcom all 0
clrcom: ld hl,lkcom
        ld b,LKCLEN
.c:     ld (hl),0
        inc hl
        djnz .c
        ret

gwsrc:
        DISP GW
gw:     push iy
        ld iy,0
        call 0008h              ; system mode, interrupts off
        pop iy
        in a,(0EEh)
        ld (RES+40h),a
        ld a,(0000h)
        ld (RES+41h),a
        ld hl,.back
        push hl
        jp 0604h                ; its RET: user mode again
.back:  ld a,(0001h)
        ld (RES+42h),a
        ld a,0AAh
        ld (RES+43h),a
        ret
        ENT
gwlen   equ $-gwsrc

        include "../src/link.asm"
lktick: ret                     ; (no kernel here: lkint stays 0)

pend:
        ASSERT pend <= 4000h
        ds 4000h-$
        SAVEBIN "probe.bin", 0, 4000h
