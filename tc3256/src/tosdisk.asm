; =====================================================================
; ZX-UX on the Timex TC3256: the disks, through TOS.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
;  /dev/fd0 - /dev/fd3: the FDD3000's drives A to D, which TOS serves:
;  the controller's part for drivers/blk/blk.asm (the cache, the devices
;  as byte streams, their seeks).  Logical sector n is TOS's logical
;  track n / 16, sector ID n mod 16 - TOS folds a two-sided disk's
;  logical tracks into cylinder and side itself (TOS_Technical_Reference
;  §5).  A sector moves with TOS's RXSEC (1Bh: C, D, E = drive, track,
;  sector; a D0h block comes back, then the reply) and TXSEC (1Ch: the
;  D0h block first, then the command), over link.asm in user mode.
;
;  /dev/rd, the fifth unit (RD_UNIT): the TC3256's RAM disk, its RD_SECS
;  sectors of 4 KB as blocks of 256 (rdsys.asm moves them, in system
;  mode, through a bounce buffer above 4000h - the cache here is below,
;  hidden then).  ZX-UX owns the RAM disk: the shadow ROM's own RAM-disk
;  files (SAVE!, LOAD!) are not kept.  Nothing mounts it: /etc/mkfs
;  /dev/rd, /etc/mount /dev/rd DIR - or leave it.
;
;  The geometry: a disk is there if logical track 0 reads.  Its size is
;  never found by reading past it (TOS does not come back from a track a
;  disk has not got - nor should a 40-track drive be stepped there): a
;  TOS system disk says it is two-sided (TD_TRKS * 2 logical tracks) in
;  its first sector (the flag TOS's own loader reads, TD_DSFLAG); any
;  other disk is the FDD3000's 40-track format.
;
;  A ZXFS volume on a TOS disk (blkvol, HAL_BLKVOL; zfs.asm's zmount asks
;  when sector 0 is TOS's): the TOS file ZXFS, put on the disk first so
;  that it starts at a track and covers whole tracks - read here as
;  plain sectors from its first track's first (TOS's 7:1 interleave is
;  inside the tracks it covers, which are all the file's).  TOS keeps
;  those tracks as its file's: nothing else is written there.
; =====================================================================

DEV_FD0 equ 8                   ; special i-nodes 8-11: /dev/fd0 - /dev/fd3,
NDRV    equ 5                   ; 12: /dev/rd
RD_UNIT equ 4
RD_SECS equ 34h                 ; the RAM disk's sectors, 256 KB mode (MMU guide §8)
RD_BLKS equ 4096/256            ; blocks a sector
SPT     equ 16
NBUF    equ 4                   ; the cache: 4 sectors, 1 KB (BUFMEM, hal.asm)
TOS_RXSEC equ 1Bh               ; TOS's functions (TOS_Technical_Reference_v2.md §10)
TOS_TXSEC equ 1Ch
TD_TRKS equ 40                  ; a disk's tracks (logical: two-sided, twice)
TD_DSFLAG equ 0Eh               ; track 0 sector 0: TOS's two-sided flag
                                ; (TOS_Technical_Reference: DOUBLE_SIDED_FLAG)
TD_DIRTRK equ 4                 ; a TOS system disk's directory: after TOS's 4 tracks
TD_AUSEC equ 4                  ; an allocation unit's sectors (1 KB)
TD_ENT  equ 32                  ; a directory entry: parent, name 8, ext 3,
TD_PART equ 12                  ;   its part, ...
TD_AU   equ 16                  ;   its allocation units
TD_ROOT equ 0                   ; the root directory's id (a parent)

; fio: sector DE of drive A to or from (fwr: 0 read, 1 write) HL.  NC; or
; CF, A = EIO.  Uses everything but IX, IY.
fio:    cp RD_UNIT
        jp z,rdfio
        ld (tdbuf),hl
        push af
        push de
        call clrcom
        pop de
        pop af
        ld (lkcom+LKC_C),a      ; the drive
        ld a,e
        and SPT-1
        ld (lkcom+LKC_E),a      ; the sector ID
        ld b,4                  ; the track: n / 16
.sh:    srl d
        rr e
        djnz .sh
        ld a,e
        ld (lkcom+LKC_D),a
        ld a,(fwr)
        or a
        jr nz,.w
        ld a,TOS_RXSEC
        ld (lkcom+LKC_F),a
        call lkcmd
        jr c,.e
        jr nz,.e
        ld hl,lkdat
        ld de,(tdbuf)
        ld bc,256
        ldir
        or a
        ret
.w:     ld hl,(tdbuf)           ; the data, then the command
        ld de,lkdat
        ld bc,256
        ldir
        ld a,TOS_TXSEC
        ld (lkcom+LKC_F),a
        ld a,LK_DATA
        ld b,0
        ld hl,lkdat
        call lksend
        jr c,.e
        call lkcmd
        jr c,.e
        ret z
.e:     ld a,EIO
        scf
        ret

; fprobe: what disk drive A has: its logical tracks (dtrk).  CF, A =
; ENXIO when its first sector does not read.
fprobe: cp RD_UNIT              ; the RAM disk: always there
        jr nz,.fd
        ld a,RD_SECS
        ld (dtrk+RD_UNIT),a
        or a
        ret
.fd:    ld (tdprb),a
        xor a
        ld (fwr),a
        ld de,0
        ld a,(tdprb)
        ld hl,lkdat             ; (into the link's own buffer)
        call fio
        jr c,.none
        ld a,(lkdat+TD_DSFLAG)
        or a
        ld a,TD_TRKS
        jr z,.s
        add a,a                 ; two-sided: twice the logical tracks
.s:     push af
        ld a,(tdprb)
        ld hl,dtrk
        call addhla
        pop af
        ld (hl),a
        or a
        ret
.none:  ld a,ENXIO
        scf
        ret

; fsize: HL = drive A's size in sectors (0 if never probed): its logical
; tracks (the RAM disk's: its sectors, RD_BLKS blocks each) x 16.
fsize:  ld hl,dtrk
        call addhla
        ld l,(hl)
        ld h,0
        add hl,hl               ; x 16 sectors
        add hl,hl
        add hl,hl
        add hl,hl
        ret

; blkvol: drive A's ZXFS in a TOS file -> DE = its first sector; CF if
; none (or not starting at a track).
blkvol: ld (tdprb),a
        ld de,TD_DIRTRK*SPT     ; the directory's 16 sectors
.sec:   push de
        ld a,(tdprb)
        call bget
        pop de
        ret c
        ld b,256/TD_ENT
.ent:   push hl
        push bc
        ld a,(hl)
        cp TD_ROOT              ; a file of the root (not free, no directory)
        jr nz,.nx
        push hl
        ld bc,TD_PART
        add hl,bc
        ld a,(hl)
        pop hl
        or a                    ; its first part
        jr nz,.nx
        inc hl
        push de
        ld de,td_vol
        ld b,td_voll
.n:     ld a,(hl)
        and 7Fh                 ; (bit 7: TOS's attributes)
        ex de,hl
        cp (hl)
        ex de,hl
        jr nz,.nn
        inc hl
        inc de
        djnz .n
        pop de
        pop bc
        pop hl
        ld bc,TD_AU
        add hl,bc
        ld a,(hl)               ; its first allocation unit
        ld c,a
        and TD_AUSEC-1
        scf
        ret nz                  ; not at a track: not ours
        ld a,c
        srl a
        srl a
        add a,TD_DIRTRK         ; its track
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ex de,hl
        or a
        ret
.nn:    pop de
.nx:    pop bc
        pop hl
        push bc
        ld bc,TD_ENT
        add hl,bc
        pop bc
        djnz .ent
        inc de
        ld a,e
        and SPT-1
        jr nz,.sec
        scf
        ret

td_vol: db "ZXFS       "        ; the volume's TOS file: name, extension
td_voll equ $-td_vol
tdbuf:  dw 0
tdprb:  db 0
dtrk:   ds NDRV                 ; each drive's logical tracks (0: not probed)

; rdfio: fio for the RAM disk: block DE, HL, fwr as fio's.
rdfio:  ld (tdbuf),hl
        ld hl,RD_SECS*RD_BLKS-1 ; past the end?
        or a
        sbc hl,de
        jr c,.e
        ld a,e
        and RD_BLKS-1
        ld (rdoff),a
        ld b,4                  ; its sector: n / 16
.sh:    srl d
        rr e
        djnz .sh
        ld a,e
        ld (rdsec),a
        ld a,(fwr)
        ld (rddir),a
        or a
        jr z,.go
        ld hl,(tdbuf)           ; written: into the bounce buffer first
        ld de,rdbounce
        ld bc,256
        ldir
.go:    call rdsys
        call lkei               ; (system mode left them off)
        ld a,(rddir)
        or a
        ret nz
        ld hl,rdbounce          ; read: out of it
        ld de,(tdbuf)
        ld bc,256
        ldir
        or a
        ret
.e:     ld a,EIO
        scf
        ret
