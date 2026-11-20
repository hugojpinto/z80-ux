; =====================================================================
; ZX-UX block devices: the buffer cache and /dev/fdN, over a machine's
; sector I/O.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  The disks, as special files and as the file systems' block device
;  (HAL_BLKDEV): logical sector n (256 bytes) of drive A.  What moves a
;  sector is the machine's (its controller part):
;    fio      sector DE of drive A to or from (fwr: 0 read, 1 write) HL;
;             NC, or CF and A = EIO / EROFS
;    fprobe   what disk drive A has (its geometry, for fsize); CF, A =
;             ENXIO when none
;    fsize    HL = drive A's size in sectors (0 if never probed)
;  (the FDD3000's WD1770: fdd3000/src/fd.asm; the TC3256's TOS:
;  tc3256/src/tosdisk.asm), with DEV_FD0, NDRV (the devices), NBUF and
;  BUFMEM (the cache: NBUF sectors at BUFMEM, page aligned).
;
;  The buffer cache is shared by the drives.  Written sectors stay in it
;  only until the write call ends (write-through per call: a disk may be
;  taken out at any time).
;
;  Offsets: ZX-UX keeps a 16-bit offset per open file, 64K, less than a
;  disk.  The driver keeps a third byte for every open-file slot (fhi),
;  carried when a transfer crosses 64K; seek modes 3, 4 and 5 (from the
;  start, the current position, the end) count in 256-byte sectors, as
;  v6's 3-5 counted in blocks, and reach the whole disk.
; =====================================================================

        ASSERT (BUFMEM & 0FFh) == 0
        ASSERT (NBUF & (NBUF-1)) == 0   ; a power of two: bget's round is AND NBUF-1
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

; bdirty: buffer B was written to.  NC: callers end on it (jp bdirty
; in the file systems) - bhp's address arithmetic must not leave a carry
; (it did when a buffer's header crossed a page: a spurious error).
bdirty: call bhp
        inc hl
        inc hl
        inc hl
        ld (hl),1
        or a
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
        ld a,(hl)               ; an empty buffer has nothing to write
        inc a
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
; (Which device numbers exist: devtab, hal.asm.)

; The block interface the mount layer and the file systems use
; (platform/README.md): units are the drives, 0-3.
;   blkunit   A = a device number -> A = its unit; CF if not a disk
;   blkprobe  A = a unit: what disk is there (fprobe); CF, A
;   bget, bflush, bdirty, binval: the buffer cache (below)
blkunit: sub DEV_FD0
        cp NDRV
        ccf
        ret
blkprobe equ fprobe

; hdopen: an open of i-number L: for a disk, its buffers are dropped
; (the disk may have changed) and its geometry probed.  CF, A on an
; error.  Keeps HL, DE, BC, IX.
hdopen: ld a,h                  ; (a mounted file's i-number may end in 8-11)
        or a
        ret nz
        ld a,l
        sub DEV_FD0
        cp NDRV
        jr c,.disk
        or a                    ; not a disk
        ret
.disk:
.d1:    push hl
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
        inc hl
        ld a,(hl)               ; the i-number: a disk? (high byte 0 ...
        dec hl
        or a
        ld a,EINVAL
        jp nz,syserr
        ld a,(hl)               ; ... and 8-11)
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


; nodev: not a disk's device: EIO.
nodev:  ld a,EIO
        scf
        ret

; ---------------------------------------------------------------------
; the cache and the devices: variables
; ---------------------------------------------------------------------
fwr:    db 0
bdev:   db 0
bnext:  db 0
bhdr:                           ; the cache: drive (FFh: empty), sector,
        DUP NBUF                ;   dirty (0: clean)
        db 0FFh,0,0,0
        EDUP
fddv:   db 0                    ; fdrw: drive, direction, size, fhi
fddir:  db 0                    ;   pointer, bytes this round
fdsz:   dw 0
fdhp:   dw 0
fdn:    dw 0
fhi:    ds NFILES+1             ; the third offset byte of each open file

