; =====================================================================
; ZX-UX on the Timex FDD3000: ZXFS, the disk file system (type 1).
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
;  The format is fdd3000/tools/zxdfs.py's (its docstring is the
;  specification; that tool makes, fills and checks these file systems on
;  the host).  In short: 256-byte blocks (a sector); block 0 the
;  superblock, then a bitmap of the blocks, then the i-nodes (8 a block,
;  in the kernel's own 32-byte form, block pointers in bytes 6-21: six
;  direct, one single and one double indirect), then data.  Directories
;  are the RAM file system's 10-byte entries, with this file system's own
;  i-numbers: made global (vfs.asm) on the way in, local on the way out.
;
;  The operations of vfs.asm's vector; IY = the mount, IX = the i-node.
;  Blocks are read through the buffer cache (fd.asm bget): never keep a
;  buffer's address across another bget - the cache may reuse it.
; =====================================================================

ZNDIR   equ 6                   ; direct block pointers ...
ZI_DIR  equ 6                   ; ... at i-node offset 6
ZI_IND  equ 18                  ; single indirect
ZI_DIND equ 20                  ; double indirect
ZS_FREE equ 20                  ; superblock: free blocks, free i-nodes
ZS_IFREE equ 22

ZBLKVOL = 0                     ; the machine says where volumes are (zmount;
        IF EXIST HAL_BLKVOL     ; built as a module: kabi.inc only, no)
ZBLKVOL = HAL_BLKVOL
        ENDIF
zfsops: dw zmount, ziload, zistore, zread, zwrite, ztrunc, zialloc, zifree
        dw zsync

; zbget: block HL of mount IY -> HL = its data, B = the buffer; CF, A.
zbget:  ld e,(iy+M_BASE)
        ld d,(iy+M_BASE+1)
        add hl,de
        ex de,hl
        ld a,(iy+M_DRV)
        jp bget

; zbgw: zbget for writing: the buffer is kept in (zf_buf) for zdirty.
zbgw:   call zbget
        ret c
        ld a,b
        ld (zf_buf),a
        ret

; zdirty: the buffer of the last zbgw was written to.  Keeps DE, HL.
zdirty: push hl
        ld a,(zf_buf)
        ld b,a
        call bdirty
        pop hl
        ret

; zmagic: Z if HL points at "ZXFS", version 1, type 1.  Keeps HL.
zmagic: push hl
        push de
        ld de,zsig
        ld b,6
.c:     ld a,(de)
        cp (hl)
        jr nz,.x
        inc hl
        inc de
        djnz .c
.x:     pop de
        pop hl
        ret
zsig:   db "ZXFS",1,1

; ---------------------------------------------------------------------
; zmount: is a ZXFS on drive (vdrv)?  Its superblock is at sector 0 of
; the disk, or where a ZX-UX system disk's boot sector says ("FS" at
; F8h, then the first sector), or (HAL_BLKVOL) where the machine says one
; is (blkvol: A = the drive -> DE = the first sector; CF none).  Fills
; IY's entry; CF if not.
zmount: ld a,(vdrv)
        ld (iy+M_DRV),a
        xor a
        ld (iy+M_BASE),a
        ld (iy+M_BASE+1),a
        ld hl,0
        call zbget
        ret c
        call zmagic
        jr z,.sb
        ld de,0F8h
        add hl,de
        ld a,(hl)
        cp 'F'
        jr nz,.vol
        inc hl
        ld a,(hl)
        cp 'S'
        jr nz,.vol
        inc hl
        ld a,(hl)
        ld (iy+M_BASE),a
        inc hl
        ld a,(hl)
        ld (iy+M_BASE+1),a
        jr .chk
.vol:
        IF ZBLKVOL
        ld a,(iy+M_DRV)         ; the machine's say: where a volume is
        call blkvol             ; on it (the TC3256: in a TOS file)
        jr c,.no
        ld (iy+M_BASE),e
        ld (iy+M_BASE+1),d
        ELSE
        jr .no
        ENDIF
.chk:   ld hl,0
        call zbget
        ret c
        call zmagic
        jr nz,.no
.sb:    ld de,6                 ; blocks, i-nodes, bitmap
        add hl,de
        ld de,M_BLKS
        call .w
        call .w
        call .w
        inc hl                  ; (bitmap blocks, 0)
        inc hl
        call .w                 ; i-node table
        inc hl                  ; (its blocks)
        inc hl
        call .w                 ; first data block
        or a
        ret
.no:    ld a,EINVAL
        scf
        ret
; .w: the word at HL to entry field E; HL += 2, E += 2.
.w:     push iy
        ex (sp),hl
        ld a,l
        add a,e
        ld l,a
        jr nc,.w1
        inc h
.w1:    ex (sp),hl
        pop bc                  ; BC = the field
        ld a,(hl)
        ld (bc),a
        inc hl
        inc bc
        ld a,(hl)
        ld (bc),a
        inc hl
        inc e
        inc e
        ret

; zsync: the buffers to the disk.
zsync:  ld a,(iy+M_DRV)
        jp bflush

; ---------------------------------------------------------------------
; I-nodes.
; ---------------------------------------------------------------------
; ziloc: own i-number HL -> HL = its block, A = its offset in it.
ziloc:  dec hl
        ld a,l
        and 7
        rrca                    ; x 32
        rrca
        rrca
        push af
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ld e,(iy+M_ITAB)
        ld d,(iy+M_ITAB+1)
        add hl,de
        pop af
        ret

; ziload: own i-number HL into the 32 bytes at DE.
ziload: push de
        call ziloc
        push af
        call zbget
        pop bc
        pop de
        ret c
        ld a,b
        call addhla
        ld bc,32
        ldir
        or a
        ret

; zistore: the 32 bytes at DE to own i-number HL.
zistore:
        push de
        call ziloc
        push af
        call zbgw
        pop bc
        pop de
        ret c
        ld a,b
        call addhla
        ex de,hl
        ld bc,32
        ldir
        jp zdirty

; zialloc: HL = a free own i-number, marked in use on the disk (the
; kernel fills it in; vsync writes it).  CF, A = ENOSPC.
zialloc:
        ld hl,1
.l:     ld (zf_ino),hl
        ex de,hl
        ld l,(iy+M_INOS)
        ld h,(iy+M_INOS+1)
        or a
        sbc hl,de
        jr c,.full
        ex de,hl
        call ziloc
        push af
        call zbgw
        pop bc
        ret c
        ld a,b
        call addhla
        inc hl
        bit 7,(hl)              ; IALLOC
        jr z,.got
        ld hl,(zf_ino)
        inc hl
        jr .l
.got:   set 7,(hl)
        call zdirty
        ld a,ZS_IFREE
        ld bc,-1
        call zsbadj
        ld hl,(zf_ino)
        or a
        ret
.full:  ld a,ENOSPC
        scf
        ret

; zifree: own i-number HL was freed: one more free i-node.
zifree: ld a,ZS_IFREE
        ld bc,1
; zsbadj: the superblock's count at offset A += BC.
zsbadj: push af
        push bc
        ld hl,0
        call zbgw
        pop bc
        pop de
        ret c
        ld a,d
        call addhla
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        add hl,bc
        ex de,hl
        ld (hl),d
        dec hl
        ld (hl),e
        jp zdirty

; ---------------------------------------------------------------------
; Blocks.
; ---------------------------------------------------------------------
; zballoc: HL = a free block, now in use and zeroed.  CF, A = ENOSPC.
zballoc:
        ld hl,0
        ld (zf_b0),hl
        ld l,(iy+M_BMAP)
        ld h,(iy+M_BMAP+1)
        ld (zf_bk),hl
.blk:   ld hl,(zf_b0)
        ld e,(iy+M_BLKS)
        ld d,(iy+M_BLKS+1)
        call cphlde
        jr nc,.full
        ld hl,(zf_bk)
        call zbgw
        ret c
        ld c,0                  ; the byte
.by:    ld a,(hl)
        inc a
        jr nz,.fnd              ; not FFh: a free block in it
        inc hl
        inc c
        jr nz,.by
        ld hl,(zf_bk)             ; the next bitmap block
        inc hl
        ld (zf_bk),hl
        ld hl,(zf_b0)
        ld de,2048
        add hl,de
        ld (zf_b0),hl
        jr .blk
.fnd:   ld a,(hl)
        ld b,0                  ; the bit, its mask
        ld e,1
.bit:   rrca
        jr nc,.b1
        inc b
        sla e
        jr .bit
.b1:    push hl
        ld a,(hl)
        or e
        ld (hl),a
        ld l,c                  ; block = zf_b0 + 8 * byte + bit
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,b
        call addhla
        ld de,(zf_b0)
        add hl,de
        ld e,(iy+M_BLKS)
        ld d,(iy+M_BLKS+1)
        call cphlde
        pop de
        jr nc,.full             ; past the end of the file system
        push hl
        call zdirty
        ld a,ZS_FREE
        ld bc,-1
        call zsbadj
        pop hl
        push hl
        call zbgw               ; zeroed
        jr c,.e
        ld b,0
.z:     ld (hl),0
        inc hl
        djnz .z
        call zdirty
        pop hl
        or a
        ret
.e:     pop hl
        scf
        ret
.full:  ld a,ENOSPC
        scf
        ret

; zbfree: block HL is free again (0: nothing).
zbfree: ld a,h
        or l
        ret z
        push hl
        ld a,l                  ; its bit
        and 7
        ld b,a
        ld a,1
        inc b
.m:     dec b
        jr z,.m1
        rlca
        jr .m
.m1:    ld (zf_mask),a
        ld a,h                  ; its bitmap block: block / 2048
        rrca
        rrca
        rrca
        and 1Fh
        ld e,(iy+M_BMAP)
        ld d,(iy+M_BMAP+1)
        ld l,a
        ld h,0
        add hl,de
        call zbgw
        pop de
        ret c
        srl d                   ; its byte: (block / 8) mod 256
        rr e
        srl d
        rr e
        srl d
        rr e
        ld a,e
        call addhla
        ld a,(zf_mask)
        cpl
        and (hl)
        ld (hl),a
        call zdirty
        ld a,ZS_FREE
        ld bc,1
        jp zsbadj

; zbmap: block A (0-255) of file IX -> HL = its block (0: a hole).  With
; (zf_alloc) set, a hole gets a new block.  CF, A on an error.
zbmap:  cp ZNDIR
        jr nc,.ind
        add a,a
        add a,ZI_DIR
        push ix
        pop hl
        call addhla
        jp zslot
.ind:   sub ZNDIR
        cp 128
        jr nc,.dbl
        ld (zf_k),a
        push ix
        pop hl
        ld de,ZI_IND
        add hl,de
        call zslot
        ret c
        ld a,h
        or l
        ret z
        ld a,(zf_k)
        jp zindir
.dbl:   sub 128                 ; (at most 121: files end at 64K)
        ld (zf_k),a
        push ix
        pop hl
        ld de,ZI_DIND
        add hl,de
        call zslot
        ret c
        ld a,h
        or l
        ret z
        xor a
        call zindir
        ret c
        ld a,h
        or l
        ret z
        ld a,(zf_k)
        jp zindir

; zslot: HL = the address of a block pointer in memory -> HL = the block
; (allocated if a hole and (zf_alloc)).
zslot:  ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or e
        jr nz,.have
        ld a,(zf_alloc)
        or a
        jr z,.have
        push hl
        call zballoc
        ex de,hl
        pop hl
        ret c
        ld (hl),d
        dec hl
        ld (hl),e
.have:  ex de,hl
        or a
        ret

; zindir: entry A of indirect block HL -> HL = the block it names
; (allocated if a hole and (zf_alloc)).
zindir: ld (zf_ib),hl
        ld (zf_ix),a
        call zbget
        ret c
        ld a,(zf_ix)
        add a,a
        call addhla
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or e
        jr nz,.have
        ld a,(zf_alloc)
        or a
        jr z,.have
        call zballoc
        ret c
        push hl
        ld hl,(zf_ib)             ; the cache may have moved it: again
        call zbgw
        pop de
        ret c
        ld a,(zf_ix)
        add a,a
        call addhla
        ld (hl),e
        inc hl
        ld (hl),d
        call zdirty
.have:  ex de,hl
        or a
        ret

; ---------------------------------------------------------------------
; readi, writei, itrunc.
; ---------------------------------------------------------------------
; zread: u_count bytes from u_off of file IX to u_base, up to its end.
zread:  ld hl,0
        ld (u_nread),hl
        xor a
        ld (zf_alloc),a
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        call isize              ; left in the file
        ld de,(u_off)
        or a
        sbc hl,de
        jr z,.ok
        jr c,.ok
        push hl
        call zchunk             ; HL = min(the block's rest, u_count)
        pop de
        call minhlde
        ld (zf_n),hl
        ld a,(u_off+1)
        call zbmap
        jr c,.err
        ld a,h
        or l
        jr z,.hole
        call zbget
        jr c,.err
        ld a,(u_off)
        call addhla
        ld de,(u_base)
        ld bc,(zf_n)
        ldir
        jr .adv
.hole:  ld hl,(u_base)
        ld bc,(zf_n)
.hz:    ld (hl),0
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.hz
.adv:   bit 6,(ix+1)            ; a directory: global i-numbers
        jr z,.a1
        ld hl,(u_base)
        ld (zf_mem),hl
        call vmhi
        ld c,a
        ld b,0F0h               ; (high byte: clear, then set C)
        call zdirx
.a1:    ld hl,(zf_n)
        call iadv
        jr .l
.ok:    or a
        ret
.err:   ld c,a
        ld hl,(u_nread)
        ld a,h
        or l
        ret nz
        ld a,c
        scf
        ret

; zwrite: u_count bytes from u_base to file IX at u_off.
zwrite: ld hl,0
        ld (u_nread),hl
        ld a,1
        ld (zf_alloc),a
        ld hl,(u_count)
        ld de,(u_off)
        add hl,de
        ld a,EFBIG
        ret c
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        call zchunk
        ld (zf_n),hl
        ld a,(u_off+1)
        call zbmap
        jr c,.err
        call zbgw
        jr c,.err
        ld a,(u_off)
        call addhla
        ld (zf_mem),hl
        ex de,hl
        ld hl,(u_base)
        ld bc,(zf_n)
        ldir
        bit 6,(ix+1)            ; a directory: own i-numbers
        jr z,.w1
        ld c,0
        ld b,0F0h
        call zdirx
.w1:    call zdirty
        ld hl,(zf_n)
        call iadv
        ld hl,(u_off)           ; longer?
        ld e,(ix+I_SIZE)
        ld d,(ix+I_SIZE+1)
        call cphlde
        jr c,.l
        jr z,.l
        ld (ix+I_SIZE),l
        ld (ix+I_SIZE+1),h
        jr .l
.ok:    call setmtim
        or a
        ret
.err:   push af
        call setmtim
        pop af
        ld c,a
        ld hl,(u_nread)
        ld a,h
        or l
        ret nz
        ld a,c
        scf
        ret

; zchunk: HL = what fits in u_off's block: min(256 - offset, u_count).
zchunk: ld a,(u_off)
        ld c,a
        xor a
        sub c
        ld l,a
        ld h,0
        jr nz,.n
        inc h
.n:     ld de,(u_count)
        jp minhlde

; zdirx: directory entries in the (zf_n) bytes at (zf_mem), which are file
; bytes from u_off on: each i-number (file offset = 0 mod 10, both of
; its bytes in the chunk) that is not 0 gets its high byte AND NOT B,
; OR C - made global (B = F0h, C = the mount's nibble) or own (C = 0).
zdirx:  push bc
        ld hl,(u_off)           ; the first entry at or after u_off
        ld de,0
        ld c,10
        call div32
        pop bc
        or a
        jr z,.f
        neg
        add a,10
.f:     ld l,a
        ld h,0
.e:     push hl                 ; HL = its distance from u_off
        inc hl
        ld de,(zf_n)
        call cphlde
        pop hl
        ret nc                  ; not wholly in the chunk
        push hl
        ld de,(zf_mem)
        add hl,de
        ld e,(hl)
        inc hl
        ld a,(hl)
        or e
        jr z,.n                 ; a free entry
        ld a,b
        cpl
        and (hl)
        or c
        ld (hl),a
.n:     pop hl
        ld de,10
        add hl,de
        jr .e

; ztrunc: free every block of file IX; it is empty.
ztrunc: ld b,ZNDIR
        ld de,ZI_DIR
        push ix
        pop hl
        add hl,de
.d:     push bc
        push hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        call zbfree
        pop hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        pop bc
        djnz .d
        ld l,(ix+ZI_IND)
        ld h,(ix+ZI_IND+1)
        call zfrind
        ld l,(ix+ZI_DIND)
        ld h,(ix+ZI_DIND+1)
        ld a,h
        or l
        jr z,.s
        ld (zf_ib2),hl
        xor a
.dl:    ld (zf_ix2),a
        ld hl,(zf_ib2)
        call zbget
        jr c,.dx
        ld a,(zf_ix2)
        add a,a
        call addhla
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        call zfrind
        ld a,(zf_ix2)
        inc a
        cp 128
        jr c,.dl
.dx:    ld hl,(zf_ib2)
        call zbfree
.s:     xor a
        ld (ix+ZI_IND),a
        ld (ix+ZI_IND+1),a
        ld (ix+ZI_DIND),a
        ld (ix+ZI_DIND+1),a
        ld (ix+I_SIZE),a
        ld (ix+I_SIZE+1),a
        ret

; zfrind: free indirect block HL and every block it names (0: nothing).
zfrind: ld a,h
        or l
        ret z
        ld (zf_ib),hl
        xor a
.l:     ld (zf_ix),a
        ld hl,(zf_ib)
        call zbget
        jr c,.x
        ld a,(zf_ix)
        add a,a
        call addhla
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        call zbfree
        ld a,(zf_ix)
        inc a
        cp 128
        jr c,.l
.x:     ld hl,(zf_ib)
        jp zbfree

; ---------------------------------------------------------------------
zf_buf:   db 0
zf_alloc: db 0
zf_ino:   dw 0
zf_b0:    dw 0
zf_bk:    dw 0
zf_mask:  db 0
zf_k:     db 0
zf_ib:    dw 0
zf_ix:    db 0
zf_ib2:   dw 0
zf_ix2:   db 0
zf_n:     dw 0
zf_mem:   dw 0
