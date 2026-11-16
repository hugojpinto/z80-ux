; =====================================================================
; ZX-UX on the Timex FDD3000: the boot sector (track 0, sector 0).
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; The FDD3000 boot ROM restores drive A, reads sector 0 of track 0 to
; 3F00h and jumps here: interrupts off, SP = 3EFFh, the ROM still paged
; in at 0000h-07FFh.  As TOS's first sector does, this loads the system
; and hands over to it.
;
; The system image is the FDD3000's memory from IMGBASE (4000h: the
; hardware layer, the kernel's low data, the kernel, the root file
; system), IMGSECS sectors of 256 bytes from track IMGTRK on, sector IDs
; 0-15 in order.  Each track is read in two turns of the disk, even IDs
; then odd ones (2:1, so the next sector is never just gone by), which
; any disk in the standard 16 x 256 format allows.
;
; Polled throughout, as the FDD3000-MSDOS boot sector is (which ran on a
; real FDD3000): no interrupts, 0038h is not used.  A read error restores
; the drive and starts again, 8 times at most, then it stops (HALT).
; bootparm.inc (build.py): IMGBASE, IMGSECS, IMGTRK, ENTRY.

        DEVICE NOSLOT64K
        include "bootparm.inc"

        org 3F00h
ipl:    ld a,5Eh                ; drive A, side 0, MFM, ROM out, head loaded
        out (0E0h),a
ipl0:   ld sp,3EFFh
        ld a,01h                ; restore
        call cmd
        ld b,IMGTRK
.step:  ld a,51h                ; step in, to the first track of the image
        call cmd
        djnz .step
        ld hl,IMGBASE           ; HL = this track's sector 0 in memory
        xor a                   ; A = its number in the image
.trk:   ld (tbase),a
        ld de,ilv               ; the sectors, in the order they are read
.sec:   ld a,(de)
        cp 0FFh
        jr z,.next
        ld c,a
        ld a,(tbase)
        add a,c
        cp IMGSECS              ; past the end of the image: skip
        jr nc,.skip
        push hl
        ld a,h
        add a,c
        ld h,a                  ; HL = where sector C goes
        ld a,c
        call read
        pop hl
.skip:  inc de
        jr .sec
.next:  ld a,(tbase)
        add a,16
        cp IMGSECS
        jp nc,ENTRY             ; the whole image is in: start ZX-UX
        ld bc,16*256
        add hl,bc
        push af
        ld a,51h                ; step in
        call cmd
        pop af
        jr .trk

; read: sector ID A of this track to HL (256 bytes).
read:   out (0C2h),a
        ld bc,00C3h             ; B = 256 bytes, C = the data register
        ld a,80h                ; read sector
        out (0C0h),a
        ld a,6                  ; let the FDC raise BUSY
.d:     dec a
        jr nz,.d
.w:     in a,(2Fh)              ; bit 7 = DRQ
        rla
        jr c,.b
        in a,(0C0h)
        rra
        jr c,.w
        jr err                  ; it ended without data
.b:     ini
        jr nz,.w
.e:     in a,(0C0h)
        rra
        jr c,.e
        in a,(0C0h)
        and 1Ch                 ; not found, CRC, lost data
        ret z
err:    ld hl,tries
        dec (hl)
        jp nz,ipl0
        halt                    ; interrupts are off: stop here

; cmd: type I command A, polled until not BUSY.
cmd:    out (0C0h),a
        push bc
        ld b,12h
.d:     djnz .d
        pop bc
.w:     in a,(0C0h)
        rra
        jr c,.w
        ret

ilv:    db 0,2,4,6,8,10,12,14,1,3,5,7,9,11,13,15,0FFh
tries:  db 8
tbase:  db 0
        db "ZX-UX"
iplend:
        ASSERT iplend - ipl <= 256
        SAVEBIN "boot.bin", ipl, iplend - ipl
