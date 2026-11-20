; =====================================================================
; ZX-UX on the Timex FDD3000: the floppy disk driver.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  /dev/fd0 - /dev/fd3: the FDD3000's four drives, A to D, as special
;  files.  Each reads and writes as a stream of bytes over the whole
;  disk: logical sector n (256 bytes) is track n / (16 x heads), head
;  (n / 16) mod heads, sector ID n mod 16 - the TOS / TMX CP/M format,
;  16 sectors of 256 bytes a track, MFM.
;
;  Geometry: probed when the device is opened (the WD1770 has no disk
;  change line, so an open is when a new disk may be in): a Read Address
;  on head 1 tells one side from two, a verified seek to track 44 tells
;  40 tracks from 80.  The head position of every drive is remembered;
;  the WD1770 has one track register, reloaded when the drive changes.
;
;  This file is the controller's part - fio (a sector in or out), fprobe,
;  fsize; the buffer cache, the devices as byte streams and their seeks
;  are drivers/blk/blk.asm's, shared with machines that reach their disks
;  otherwise (the TC3256: through TOS).
;
;  The WD1770 is polled throughout (CBIOS A1.1's transfer loop: DRQ is
;  bit 7 of port 2Fh), with interrupts off while a sector moves; every
;  wait times out (about 3 s), so an empty drive gives an error, not a
;  hang.  Errors retry RETRIES times, the drive restored in between.
; =====================================================================

DEV_FD0 equ 8                   ; special i-nodes 8-11: /dev/fd0 - /dev/fd3.
NDRV    equ 4
SPT     equ 16
NBUF    equ 8                   ; the cache: 8 sectors, 2K ...
BUFMEM  equ 1000h               ; ... above the ROM trap zone (hinit).
RETRIES equ 5
FIOCOST equ 1000                ; a sector's transfer, 256 x 32 us (16 T units).
FWCOST  equ 256*100/16          ; 256 turns of a wait loop (fwait).
FWMAX   equ 3*4000000/100/256   ; ... about 3 s of them, in polls.

FC_REST equ 01h                 ; restore, 12 ms steps
FC_SEEK equ 15h                 ; seek, verify, 12 ms steps
FC_RD   equ 80h                 ; read sector (motor spin-up)
FC_WR   equ 0A0h                ; write sector
FC_RDA  equ 0C0h                ; read address (6 ID bytes)
FC_INT  equ 0D0h                ; force interrupt, no condition
FDCTRK  equ 0C1h
FDCSEC  equ 0C2h
FDCDAT  equ 0C3h

        ASSERT (BUFMEM & 0FFh) == 0 && BUFMEM + NBUF*256 <= HALBASE

; ---------------------------------------------------------------------
; The controller.
; ---------------------------------------------------------------------
; fsel: drive A, head C (0/1): select it, the head loaded, the light on.
; The FDC's track register follows the drive.  Keeps BC, DE, HL.
fsel:   push bc
        push hl
        ld b,a
        ld hl,fdrv
        cp (hl)
        jr z,.same
        ld (hl),a
        ld hl,dcur
        call addhla
        ld a,(hl)
        out (FDCTRK),a          ; (FFh, unknown: fseek restores first)
.same:  ld a,0FEh               ; the drive's select bit, low
        inc b
.m:     dec b
        jr z,.mk
        rlca
        jr .m
.mk:    and 04Fh                ; ROM out, MFM, light on, head 1 ...
        bit 0,c
        jr nz,.h1
        or 10h                  ; ... or head 0
.h1:    out (LATCH),a
        ld (latsh),a
        pop hl
        pop bc
        ret

; fdone: the light off, the drive still selected - as CBIOS A1.1's LIGHTOF
; leaves it: the WD1770 drops MOTOR ON (common to all drives) only after 9
; index pulses, and only a selected drive gives them (HFD305S 5(5)).  Then
; the clock again (tmr.asm).
fdone:  ld a,(latsh)
        or 80h
        out (LATCH),a
        ld (latsh),a
        jp tresume

; fcmd1: type I command A, polled until done: NC, A = status; CF on a
; timeout (the command is stopped).  While it waits (a seek, a spin-up:
; up to seconds) the terminal is served and time goes on: fwait.
; Keeps BC, DE, HL.
fcmd1:  out (FDCST),a
        push bc
        push de
        push hl
        ld b,12h                ; let the FDC raise BUSY
.d:     djnz .d
        call fwset
.w:     in a,(FDCST)
        rra
        jr nc,.ok
        call fwait
        jr nz,.w
        ld a,FC_INT
        out (FDCST),a
        scf
        jr .x
.ok:    in a,(FDCST)            ; the status (it drops INTRQ)
        or a
.x:     pop hl
        pop de
        pop bc
        ret

; fwset / fwait: a wait of at most about 3 s.  fwait counts one turn of
; a polling loop: NZ while time is left; every 256 turns (some 12000 T)
; it looks for a key and puts the time on the clock.  Uses A, HL.
fwset:  xor a
        ld (fwcnt),a
        ld h,a
        ld l,a
        ld (fwpol),hl
        ret
fwait:  ld hl,fwcnt
        inc (hl)
        jr nz,.n
        push bc
        push de
        call hkeys
        ld hl,FWCOST
        call htime
        pop de
        pop bc
        ld hl,(fwpol)
        inc hl
        ld (fwpol),hl
        ld a,h
        cp high FWMAX
        jr c,.n
        ld a,l
        cp low FWMAX
        jr nc,.z
.n:     or 1
        ret
.z:     xor a
        ret

; dcurp: HL = the current drive's head position (dcur).  Uses A.
dcurp:  ld a,(fdrv)
        ld hl,dcur
        jp addhla

; frest: restore the current drive to track 0: Z if it got there.
frest:  push hl
        call dcurp
        ld (hl),0FFh
        ld a,FC_REST
        call fcmd1
        jr c,.no
        and 04h                 ; track 0
        jr z,.no
        ld (hl),0
        xor a
        pop hl
        ret
.no:    or 1
        pop hl
        ret

; fseek: to track B on the current drive, verified: Z if there.
fseek:  push hl
        call dcurp
        ld a,(hl)
        cp b
        jr z,.x                 ; there already (Z)
        inc a
        jr nz,.go
        call frest              ; position unknown: from track 0
        jr nz,.x
        call dcurp
.go:    ld (hl),0FFh
        ld a,b
        out (FDCDAT),a
        ld a,FC_SEEK
        call fcmd1
        jr c,.f
        and 18h                 ; seek error, CRC
        jr nz,.x
        ld (hl),b
.x:     pop hl
        ret
.f:     or 1
        pop hl
        ret

; fxfer: command A (read, write, read address) for B bytes (0 = 256)
; at HL; the sector register is set.  NC, A = status; CF on a timeout.
; Waiting for the first byte (a spin-up, the sector coming round) is
; fwait's; once data flows it is CBIOS A1.1's loop, nothing else - a
; byte comes every 32 us.
fxfer:  ld c,FDCDAT
        push hl
        out (FDCST),a
        ld (fcmdb),a
        call fwset
        pop hl
.w0:    in a,(LINK)             ; bit 7: DRQ - the data has come
        rla
        jr c,.go
        in a,(FDCST)
        rra
        jr nc,.st               ; it ended without data
        push hl
        call fwait
        pop hl
        jr nz,.w0
        ld a,FC_INT
        out (FDCST),a
        scf
        ret
.go:    di
        ld a,(fcmdb)
        cp FC_WR
        jr z,.wb
.rb:    ini
        jr z,.end
.rw:    in a,(LINK)
        rla
        jr c,.rb
        in a,(FDCST)
        rra
        jr c,.rw
        jr .end
.wb:    outi
        jr z,.end
.ww:    in a,(LINK)
        rla
        jr c,.wb
        in a,(FDCST)
        rra
        jr c,.ww
.end:   in a,(FDCST)            ; the CRC, the end of the command
        rra
        jr c,.end
        ei
.st:    in a,(FDCST)
        or a
        ret

; fio: sector DE of drive A to or from (fwr: 0 read, 1 write) HL.
; NC; or CF, A = EIO / EROFS.  Uses everything but IX, IY.
fio:    call tsusp              ; the FDC is the driver's now (tmr.asm)
        ld (fdev),a
        ld (fsec),de
        ld (fbuf),hl
        ld a,RETRIES
        ld (ftry),a
.t:     ld hl,(fsec)            ; track = n / 16, sector = n mod 16
        ld a,l
        and SPT-1
        ld (fsid),a
        ld b,4
.sh:    srl h
        rr l
        djnz .sh
        ld c,0                  ; two heads: head = track mod 2
        ld a,(fdev)
        push hl
        ld hl,dhead
        call addhla
        ld a,(hl)
        pop hl
        cp 2
        jr nz,.h1
        srl h
        rr l
        rl c
.h1:    ld b,l                  ; cylinder
        ld a,(fdev)
        call fsel
        call fseek
        jr nz,.again
        ld a,(fsid)
        out (FDCSEC),a
        ld hl,(fbuf)
        ld b,0
        ld a,(fwr)
        or a
        ld a,FC_RD
        jr z,.c
        ld a,FC_WR
.c:     call fxfer
        jr c,.again
        and 5Ch                 ; protected, not found, CRC, lost data
        jr z,.ok
        bit 6,a
        jr nz,.prot
.again: ld hl,ftry
        dec (hl)
        jr z,.fail
        call dcurp              ; restore before the next try
        ld (hl),0FFh
        jr .t
.ok:    call fdone
        ld hl,FIOCOST
        call htime
        or a
        ret
.prot:  call fdone
        ld a,EROFS
        scf
        ret
.fail:  call fdone
        ld a,EIO
        scf
        ret

; fprobe: find the geometry of drive A (dhead, dcyl).  CF, A = ENXIO
; for no drive, EIO for no readable disk.
fprobe: cp TDRV                 ; drive D: the clock's select line, if
        jr nz,.d1               ; it took it (tmr.asm tinit)
        ld a,(tmuse)
        or a
        ld a,TDRV
        jr z,.d1
        ld a,ENXIO
        scf
        ret
.d1:    call tsusp
        ld (fdev),a
        ld hl,dcyl
        call addhla
        ld (hl),0
        ld a,(fdev)
        ld c,0
        call fsel
        call frest
        ld a,ENXIO
        jr nz,.err
        call .rda               ; an ID on head 0?
        ld a,EIO
        jr nz,.err
        ld a,(fdev)
        ld c,1
        call fsel
        call .rda               ; ... and on head 1?  A one-sided drive
        ld e,1                  ; ignores the side line and reads head 0's
        jr nz,.s                ; IDs: the ID must say head 1.
        ld a,(fid+1)
        dec a
        jr nz,.s
        inc e
.s:     ld a,(fdev)
        ld hl,dhead
        call addhla
        ld (hl),e
        ld c,0
        ld a,(fdev)
        call fsel
        ld b,44                 ; eighty tracks?
        call fseek
        ld e,40
        jr nz,.c
        ld e,80
.c:     ld a,(fdev)
        ld hl,dcyl
        call addhla
        ld (hl),e
        call fdone
        or a
        ret
.err:   push af
        call fdone
        pop af
        scf
        ret
.rda:   ld hl,fid
        ld b,6
        ld a,FC_RDA
        call fxfer
        jr c,.rn
        and 1Ch
        ret
.rn:    or 1
        ret

; fsize: HL = drive A's size in sectors (0 if never probed).
fsize:  push af
        ld hl,dcyl
        call addhla
        ld e,(hl)
        pop af
        ld hl,dhead
        call addhla
        ld a,(hl)
        ld d,0
        ex de,hl                ; HL = cylinders
        add hl,hl               ; x 16 sectors
        add hl,hl
        add hl,hl
        add hl,hl
        cp 2
        ret nz
        add hl,hl               ; x 2 heads
        ret

; ---------------------------------------------------------------------
; driver variables
; ---------------------------------------------------------------------
fdrv:   db 0FFh                 ; the drive selected last
dcur:   db 0FFh,0FFh,0FFh,0FFh  ; each drive's track (FFh: unknown)
dhead:  db 1,1,1,1              ; heads, probed at open
dcyl:   db 0,0,0,0              ; tracks, probed at open (0: not yet)
fdev:   db 0                    ; fio: drive, sector, buffer, tries,
fsec:   dw 0                    ;   sector ID, direction
fbuf:   dw 0
ftry:   db 0
fsid:   db 0
fcmdb:  db 0                    ; fxfer: the command
fwcnt:  db 0                    ; fwait: turns of the loop (256 a poll),
fwpol:  dw 0                    ;   polls
fid:    ds 6                    ; a Read Address's ID field
