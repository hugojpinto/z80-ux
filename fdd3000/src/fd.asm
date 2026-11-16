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
;  The buffer cache: NBUF sectors in low RAM (BUFMEM), shared by the
;  drives.  Written sectors stay in it only until the write call ends
;  (write-through per call: a disk may be taken out at any time).
;
;  Offsets: ZX-UX keeps a 16-bit offset per open file, 64K, less than a
;  disk.  The driver keeps a third byte for every open-file slot (fhi),
;  carried when a transfer crosses 64K; seek modes 3, 4 and 5 (from the
;  start, the current position, the end) count in 256-byte sectors, as
;  v6's 3-5 counted in blocks, and reach the whole disk.
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
BUFMEM  equ 0100h               ; ... above the restart vectors.
RETRIES equ 5
ENXIO   equ 6
EROFS   equ 30
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

        ASSERT (BUFMEM & 0FFh) == 0 && BUFMEM + NBUF*256 <= 3F00h

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

; fdone: every drive deselected, the light off.
fdone:  ld a,LATIDLE
        out (LATCH),a
        ld (latsh),a
        ret

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
fio:    ld (fdev),a
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
fprobe: ld (fdev),a
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
; The buffer cache.  bhdr: per buffer the drive (FFh: empty), the sector
; (word) and a dirty byte; buffer B's data is at BUFMEM + 256 * B.
; ---------------------------------------------------------------------
; bget: sector DE of drive A -> HL = its data, B = the buffer; CF, A on
; an error.  Uses everything but IX, IY.
bget:   ld (bdev),a
        ld hl,bhdr
        ld b,0
.s:     ld a,(bdev)
        cp (hl)
        jr nz,.n
        inc hl
        ld a,(hl)
        inc hl
        cp e
        jr nz,.n2
        ld a,(hl)
        cp d
        jr z,.hit
.n2:    dec hl
        dec hl
.n:     inc hl
        inc hl
        inc hl
        inc hl
        inc b
        ld a,b
        cp NBUF
        jr c,.s
        ld a,(bnext)            ; a miss: the next buffer round
        ld b,a
        inc a
        and NBUF-1
        ld (bnext),a
        push de
        call bflsh1             ; written back first if dirty
        pop de
        call bhp
        ld (hl),0FFh            ; empty until the read is done
        push bc
        push hl
        ld a,b
        add a,high BUFMEM
        ld h,a
        ld l,0
        xor a
        ld (fwr),a
        ld a,(bdev)
        push de
        call fio
        pop de
        pop hl
        pop bc
        ret c
        ld a,(bdev)
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0               ; clean
.hit:   ld a,b
        add a,high BUFMEM
        ld h,a
        ld l,0
        or a
        ret

; bhp: HL = buffer B's header.  Keeps BC, DE.
bhp:    ld a,b
        add a,a
        add a,a
        ld hl,bhdr
        jp addhla

; bdirty: buffer B was written to.
bdirty: call bhp
        inc hl
        inc hl
        inc hl
        ld (hl),1
        ret

; bflsh1: buffer B to disk if dirty.  CF, A on an error (it is left
; clean all the same: the data could not be kept).  Keeps B.
bflsh1: call bhp
        push hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)
        ld (hl),0
        pop hl
        or a
        ret z
        ld a,(hl)               ; drive
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        push bc
        ld c,a
        ld a,b
        add a,high BUFMEM
        ld h,a
        ld l,0
        ld a,1
        ld (fwr),a
        ld a,c
        call fio
        pop bc
        ret

; bflush: every dirty buffer of drive A to disk.  CF, A on an error.
bflush: ld c,a
        ld b,0
        ld e,0                  ; the first error
.l:     call bhp
        ld a,(hl)
        cp c
        jr nz,.n
        push bc
        push de
        call bflsh1
        pop de
        pop bc
        jr nc,.n
        ld e,a
.n:     inc b
        ld a,b
        cp NBUF
        jr c,.l
        ld a,e
        or a
        ret z
        scf
        ret

; binval: drive A's buffers written back and forgotten.
binval: push af
        call bflush
        pop bc
        ld c,b
        ld b,0
.l:     call bhp
        ld a,(hl)
        cp c
        jr nz,.n
        ld (hl),0FFh
.n:     inc b
        ld a,b
        cp NBUF
        jr c,.l
        ret

; ---------------------------------------------------------------------
; The devices.
; ---------------------------------------------------------------------
; hdevok: A = a special i-number: Z if it is a device of this kernel
; (tty 1, mem 2, fd0-fd3 8-11).  Keeps A.
hdevok: cp DEV_TTY
        ret z
        cp DEV_MEM
        ret z
        cp DEV_FD0
        jr c,.no
        cp DEV_FD0+NDRV
        jr nc,.no
        cp a
        ret
.no:    or 0FFh                 ; NZ (A is not needed then)
        ret

; hdopen: an open of i-number L: for a disk, its buffers are dropped
; (the disk may have changed) and its geometry probed.  CF, A on an
; error.  Keeps HL, DE, BC, IX.
hdopen: ld a,l
        sub DEV_FD0
        cp NDRV
        jr c,.disk
        or a                    ; not a disk
        ret
.disk:  push hl
        push de
        push bc
        push af
        call binval
        pop af
        call fprobe
        pop bc
        pop de
        pop hl
        ret

; fhptr: HL = the high offset byte of the open file in use (u_ino is
; its file-table entry), or a spare one.  Uses A, DE.
fhptr:  ld hl,(u_ino)
        ld de,fsp
        or a
        sbc hl,de
        ld a,l
        ld e,0
.d:     sub FSPSZ
        jr c,.x
        inc e
        jr .d
.x:     ld a,e
        cp NFILES
        jr c,.ok
        ld a,NFILES             ; not a file-table entry: the spare
.ok:    ld hl,fhi
        jp addhla

; fhclr: fopen claims the file-table entry whose count byte HL points at:
; its high offset starts at 0.  Keeps everything.
fhclr:  push af
        push de
        push hl
        ld de,(u_ino)
        push de
        dec hl
        dec hl
        dec hl
        dec hl
        ld (u_ino),hl
        call fhptr
        ld (hl),0
        pop de
        ld (u_ino),de
        pop hl
        pop de
        pop af
        ret

; fdread / fdwrite: devread / devwrite for /dev/fd0-3 (IX = the special
; i-node, A its device number): u_count bytes at u_base from the file's
; position on.  Short at the end of the disk.
fdread: ld c,0
        jr fdrw
fdwrite: ld c,1
fdrw:   sub DEV_FD0
        cp NDRV
        jp nc,nodev
        ld (fddv),a
        ld a,c
        ld (fddir),a
        ld a,(fddv)
        call fsize
        ld a,h
        or l
        jr nz,.sz
        ld a,(fddv)             ; not probed (open failed?): now
        call fprobe
        ret c
        ld a,(fddv)
        call fsize
.sz:    ld (fdsz),hl
        call fhptr
        ld (fdhp),hl
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.done
        ld hl,(fdhp)            ; the sector: fhi and u_off's high byte
        ld d,(hl)
        ld a,(u_off+1)
        ld e,a
        ld hl,(fdsz)
        ex de,hl
        or a
        sbc hl,de
        jr nc,.done             ; the end of the disk
        add hl,de
        ex de,hl
        ld a,(u_off)            ; this many bytes of it: 256 - offset ...
        ld c,a
        xor a
        sub c
        ld l,a
        ld h,0
        jr nz,.n1
        inc h                   ; (offset 0: 256)
.n1:    push de
        ld de,(u_count)         ; ... or what is left
        call minhlde
        pop de
        ld (fdn),hl
        ld a,(fddv)
        call bget
        jr c,.err
        ld a,(u_off)
        call addhla             ; HL = the bytes in the buffer
        ld de,(u_base)
        ld a,(fddir)
        or a
        jr z,.cp
        ex de,hl
        call bdmark
.cp:    ld bc,(fdn)
        ldir
        ld a,(u_off+1)
        push af
        ld hl,(fdn)
        call iadv               ; u_off, u_base, u_nread, u_count
        pop af
        ld hl,u_off+1
        cp (hl)
        jr c,.l
        jr z,.l
        ld hl,(fdhp)            ; past 64K: the third byte
        inc (hl)
        jr .l
.done:  ld a,(fddir)
        or a
        ret z
        ld a,(fddv)
        call bflush
        ret nc
.err:   ld c,a
        ld hl,(u_nread)         ; some moved: say how many
        ld a,h
        or l
        ret nz
        ld a,c
        scf
        ret

; bdmark: buffer B was written to (keeps DE, HL).
bdmark: push hl
        call bdirty
        pop hl
        ret

; hseek: sysseek modes 3-5 (A, from the start, here, the end) for the
; file-table entry at u_ino: DE sectors of 256 bytes.  HL = the new
; position in sectors.
hseek:  sub 3
        jr z,.set
        dec a
        jr nz,.end
        push de                 ; here: the current sector
        call fhptr
        ld d,(hl)
        ld hl,(u_ino)
        inc hl
        inc hl
        inc hl
        ld e,(hl)
        pop hl
        add hl,de
        ex de,hl
        jr .set
.end:   dec a
        ld a,EINVAL
        jp nz,syserr
        push de
        ld hl,(u_ino)
        ld a,(hl)               ; the i-number: a disk?
        sub DEV_FD0
        cp NDRV
        ld a,EINVAL
        jp nc,syserr
        ld a,(hl)
        sub DEV_FD0
        call fsize
        pop de
        add hl,de
        ex de,hl
.set:   push de
        call fhptr
        pop de
        ld (hl),d               ; sector high byte
        ld hl,(u_ino)
        inc hl
        inc hl
        ld (hl),0               ; offset: sector low byte, 0
        inc hl
        ld (hl),e
        ex de,hl
        jp sysok

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
fwr:    db 0
fcmdb:  db 0                    ; fxfer: the command
fwcnt:  db 0                    ; fwait: turns of the loop (256 a poll),
fwpol:  dw 0                    ;   polls
fid:    ds 6                    ; a Read Address's ID field
bdev:   db 0
bnext:  db 0
bhdr:   ds NBUF*4,0FFh          ; the cache: drive, sector, dirty
fddv:   db 0                    ; fdrw: drive, direction, size, fhi
fddir:  db 0                    ;   pointer, bytes this round
fdsz:   dw 0
fdhp:   dw 0
fdn:    dw 0
fhi:    ds NFILES+1             ; the third offset byte of each open file
