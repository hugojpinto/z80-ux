; =====================================================================
; ZX-UX on the Timex FDD3000: /etc/mkfs.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
;   mkfs /dev/fdN [blocks [inodes]]
;                           a new, empty ZXFS on the disk, from its first
;                           sector: all of it, or so many blocks; i-nodes
;                           one for every 10 blocks (16 to 1024)
;
;  mkfs writes the layout fdd3000/tools/zxdfs.py makes: the superblock,
;  the bitmap (the system blocks and the root directory's block in use),
;  the i-node table (i-node 1 the root, "." and ".." both itself), the
;  root's block - in that order, which is the order on the disk.
;  (In the kernel image: the hardware layer's spare room took dd, mount
;  and umount; t_fs.asm.)
; =====================================================================

; ------------------------------------------------------------- mkfs
MK_FD   equ TV                  ; the disk
MK_BLK  equ TV+2                ; blocks, i-nodes
MK_INO  equ TV+4
MK_NBM  equ TV+6                ; bitmap blocks, i-node table blocks
MK_NIT  equ TV+8
MK_DATA equ TV+10               ; the first data block (the root's)
MK_N    equ TV+12               ; the block being written
MK_TIME equ TV+14               ; 4
MK_BUF  equ TV+18               ; one block
MK_END  equ TV+18+256

t_mkfs: db 18h,6
        dw STKRES, MK_END-UDATA, mkfs_m
mkfs_m: pop hl
        call args
        ld a,1
        call argn
        ld hl,s_mkfsu
        jp z,usage
        ld a,1
        call argn
        ld de,2
        call sc_open
        jp c,.err
        ld (MK_FD),hl
        ld de,0                 ; its size: seek to the end, in sectors
        ld bc,5
        call sc_seek
        jp c,.err
        ld (MK_BLK),hl
        ld a,2                  ; or as many as asked
        call argn
        jr z,.b1
        call atoi
        jp c,.use
        ld hl,(MK_BLK)
        call cphlde
        jp c,.use               ; more than the disk
        ld (MK_BLK),de
.b1:    ld hl,(MK_BLK)          ; i-nodes: blocks / 10, a multiple of 8
        ld de,10
        call udiv16
        ld de,7
        add hl,de
        ld a,l
        and 0F8h
        ld l,a
        ld de,16                ; 16 ...
        call cphlde
        jr nc,.i1
        ex de,hl
.i1:    ld de,1024+1            ; ... to 1024
        call cphlde
        jr c,.i2
        ld hl,1024
.i2:    ld (MK_INO),hl
        ld a,3
        call argn
        jr z,.i3
        call atoi
        jp c,.use
        ld hl,7
        add hl,de
        ld a,l
        and 0F8h
        ld l,a
        ld (MK_INO),hl
.i3:    ld hl,(MK_BLK)          ; the layout
        ld de,2047
        add hl,de
        ld a,h
        rrca
        rrca
        rrca
        and 1Fh
        ld l,a
        ld h,0
        ld (MK_NBM),hl
        ld hl,(MK_INO)
        ld de,7
        add hl,de
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ld (MK_NIT),hl
        ld de,(MK_NBM)
        add hl,de
        inc hl
        ld (MK_DATA),hl
        inc hl
        inc hl
        ld de,(MK_BLK)
        call cphlde
        jp nc,.use              ; no room for data
        SC _time
        ld (MK_TIME),hl
        ld (MK_TIME+2),de
        ld hl,(MK_FD)           ; from sector 0
        ld de,0
        ld bc,3
        call sc_seek
        jp c,.err
        ld hl,0
        ld (MK_N),hl
.blk:   call .clr               ; block MK_N
        ld hl,(MK_N)
        ld a,h
        or l
        call z,.super
        call .bitmap
        call .inodes
        ld hl,(MK_N)
        ld de,(MK_DATA)
        call cphlde
        call z,.root
        ld hl,(MK_FD)
        ld de,MK_BUF
        ld bc,256
        call sc_write
        jp c,.err
        ld a,h
        or a
        jp z,.err               ; short: the end of the disk
        ld hl,(MK_N)
        inc hl
        ld (MK_N),hl
        ld de,(MK_DATA)
        call cphlde
        jr c,.blk
        jr z,.blk
        ld hl,(MK_BLK)
        call putdec
        ld hl,s_mkfs1
        call puts
        ld hl,(MK_INO)
        call putdec
        ld hl,s_mkfs2
        call puts
        jp exit0
.use:   ld hl,s_mkfsu
        jp usage
.err:   ld hl,1
        call argn
        ld de,s_eio
        call perr
        ld hl,1
        jp exitc

; .clr: the buffer, zero.
.clr:   ld hl,MK_BUF
        ld b,0
.c:     ld (hl),0
        inc hl
        djnz .c
        ret

; .super: block 0.
.super: ld hl,zfsig
        ld de,MK_BUF
        ld bc,6
        ldir
        ld hl,MK_BLK
        ld bc,4                 ; blocks, i-nodes
        ldir
        ld hl,1                 ; the bitmap: block 1, MK_NBM blocks
        call .w
        ld a,(MK_NBM)
        ld (de),a
        inc de
        inc de
        ld hl,(MK_NBM)          ; the i-node table, after it
        inc hl
        call .w
        ld hl,(MK_NIT)
        call .w
        ld hl,(MK_DATA)
        call .w
        ld hl,(MK_BLK)          ; free: all but the system and the root's
        ld bc,(MK_DATA)
        or a
        sbc hl,bc
        dec hl
        call .w
        ld hl,(MK_INO)          ; free i-nodes: all but the root
        dec hl
        call .w
        ld hl,MK_TIME
        ld bc,4
        ldir
        ret
.w:     ex de,hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ex de,hl
        ret

; .bitmap: if MK_N is a bitmap block (1 .. MK_NBM), blocks 0 to MK_DATA
; are in use: those of them it holds.
.bitmap:
        ld hl,(MK_N)
        ld a,h
        or l
        ret z
        ld de,(MK_NBM)
        call cphlde
        jr z,.bm
        ret nc
.bm:    dec hl                  ; its first block: 2048 * (n - 1)
        ld a,l
        add a,a
        add a,a
        add a,a
        ld d,a
        ld e,0                  ; DE = the first block it holds
        ld hl,(MK_DATA)
        inc hl                  ; blocks 0 .. MK_DATA in use
        or a
        sbc hl,de
        ret c
        ret z                   ; none of them here
        ld de,2048
        call minhlde            ; HL = how many bits to set
        ld de,MK_BUF
.bb:    ld a,h
        or a
        jr nz,.b8
        ld a,l
        cp 8
        jr c,.bl
.b8:    ld a,0FFh               ; eight at a time
        ld (de),a
        inc de
        ld bc,-8
        add hl,bc
        jr .bb
.bl:    or a
        ret z
        ld b,a                  ; the last few
        xor a
.bs:    scf
        rla
        djnz .bs
        ld (de),a
        ret

; .inodes: if MK_N is the first i-node table block: the root, i-node 1.
.inodes:
        ld hl,(MK_NBM)
        inc hl
        ld de,(MK_N)
        or a
        sbc hl,de
        ret nz
        ld hl,MK_BUF
        ld (hl),00Fh            ; rw- rw- (o+w as /tmp), a directory,
        inc hl
        ld (hl),0C0h            ; in use
        inc hl
        ld (hl),2               ; links: . and ..
        inc hl
        inc hl
        ld (hl),20              ; two entries
        inc hl
        inc hl
        ld de,(MK_DATA)         ; its first block
        ld (hl),e
        inc hl
        ld (hl),d
        ld de,MK_BUF+22         ; ctime, mtime
        ld hl,MK_TIME
        ld bc,4
        ldir
        ld hl,MK_TIME
        ld bc,4
        ldir
        ret

; .root: the root directory's block: "." and "..", both i-node 1.
.root:  ld hl,MK_BUF
        ld (hl),1
        inc hl
        inc hl
        ld (hl),'.'
        ld hl,MK_BUF+10
        ld (hl),1
        inc hl
        inc hl
        ld (hl),'.'
        inc hl
        ld (hl),'.'
        ret

s_mkfsu: db "mkfs /dev/fdN [blocks [inodes]]",0
s_mkfs1: db " blocks, ",0
s_mkfs2: db " i-nodes",10,0
zfsig:  db "ZXFS",1,1
e_mkfs:
