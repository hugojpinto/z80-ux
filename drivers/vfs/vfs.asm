; =====================================================================
; ZX-UX on the Timex FDD3000: mounted file systems.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
;  The root file system stays ZX-UX's own, in RAM.  A disk file system is
;  mounted on one of its directories (sys mount, 21; sys umount, 22).
;  This layer knows mounts, not formats: each mount names a file system
;  type, and each type is a vector of operations (FO_*) in the type table
;  (fstab).  ZXFS (zfs.asm) is built in, type 1; the others are modules
;  loaded from files when a mount asks for them, and unloaded when their
;  last mount goes (fsmod.asm).
;
;  I-numbers.  RAM files, devices and resident programs keep theirs
;  (below 100h).  The file system mounted in slot k has i-numbers
;  1000h * (k+1) + n, n its own (1 = its root, up to 0FFFh); so the high
;  nibble of an i-number says where it lives, and nothing else changes:
;  the open-file table, u_cdir, stat all carry the number as before.
;
;  I-nodes.  The kernel works on 32-byte in-core i-nodes through IX.
;  A mounted file's lives in the i-node cache (micache), filled by the
;  type's ILOAD, with a shadow copy of what is on the disk; at the end
;  of every system call that touched one, changed i-nodes go back (ISTORE)
;  and the disks are flushed (SYNC).  So the kernel's own code - namei,
;  link, unlink, mkdir, stat, chmod - works on mounted files unchanged.
;  The kernel calls in here where it would touch RAM (all IF HAL_VFS):
;    iget      i-number >= 1000h            -> vfs_iget
;    readi, writei, itrunc  IX in micache   -> the type's READ, WRITE, TRUNC
;    ialloc    in a mounted directory       -> vfs_ialloc
;    ifree     i-number >= 1000h            -> vfs_ifree
;    namei     a name found                 -> vfscross (mount points, ..;
;                                              a disk's directory can be
;                                              mounted on too)
;    link      across file systems          -> EXDEV
;    unlink    a mount point                -> EBUSY
;    sysx      every system call's end      -> vsync
; =====================================================================

NMOUNT  equ 4
MNTSZ   equ 16
M_TYPE  equ 0                   ; 0: free; else the file system type
M_DRV   equ 1                   ; the drive (0-3)
M_BASE  equ 2                   ; its first sector on the disk
M_BLKS  equ 4                   ; type-specific from here (ZXFS: blocks,
M_INOS  equ 6                   ;   i-nodes, bitmap, i-node table and
M_BMAP  equ 8                   ;   first data block)
M_ITAB  equ 10
M_DATA  equ 12
M_COVER equ 14                  ; the RAM directory it is mounted on

NMI     equ 8                   ; the i-node cache
MI_NUM  equ 0                   ; i-number (0: free)
MI_AGE  equ 2                   ; last use (vclock)
MI_CORE equ 3                   ; the i-node the kernel works on
MI_SHAD equ 35                  ; ... and as it is on the disk
MISZ    equ 67

ENOTBLK equ 15
EXDEV   equ 18

; The operations of a file system type (offsets in its vector).  IY is
; the mount entry; IX, where there is one, the in-core i-node.
FO_MOUNT  equ 0                 ; (vdrv) = drive: is this type's file system
                                ;   on it?  Fill IY's entry; CF if not.
FO_ILOAD  equ 2                 ; HL = own i-number, DE = 32 bytes: read it
FO_ISTORE equ 4                 ; HL = own i-number, DE = 32 bytes: write it
FO_READ   equ 6                 ; readi (IX; u_off, u_base, u_count)
FO_WRITE  equ 8                 ; writei
FO_TRUNC  equ 10                ; itrunc (IX): free the contents
FO_IALLOC equ 12                ; -> HL = a free own i-number, claimed; CF
FO_IFREE  equ 14                ; HL = own i-number: it was freed
FO_SYNC   equ 16                ; to the disk, now

; vop: operation A of mount IY's file system (the other registers pass).
vop:    push hl
        push af
        ld a,(iy+M_TYPE)
        call vfst
        call ldind
        pop af
        call addhla
        call ldind
        ex (sp),hl
        ret

; vmnt: i-number HL -> IY = its mount entry; CF if none.  Keeps BC, DE, HL.
vmnt:   ld a,h
        rrca
        rrca
        rrca
        rrca
        and 0Fh
        dec a
        cp NMOUNT
        jr nc,.no
        push hl
        push de
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,mtab
        add hl,de
        push hl
        pop iy
        pop de
        pop hl
        ld a,(iy+M_TYPE)
        or a
        ret nz
.no:    scf
        ret

; vmhi: A = the high nibble of mount IY's i-numbers (10h * (k+1)).
vmhi:   push hl
        push de
        push iy
        pop hl
        ld de,mtab
        or a
        sbc hl,de
        ld a,l                  ; 16 * k
        add a,10h
        pop de
        pop hl
        ret

; vfsix: Z if IX is an in-core i-node of a mounted file.  Keeps all but A.
vfsix:  push hl
        push de
        push ix
        pop hl
        ld de,micache
        or a
        sbc hl,de
        jr c,.no
        ld de,NMI*MISZ
        sbc hl,de
        jr nc,.no
        xor a
        jr .x
.no:    or 1
.x:     pop de
        pop hl
        ret

; vixe: IX in the cache -> IY = its mount.  Keeps BC, DE, HL.
vixe:   push hl
        push ix
        pop hl
        push de
        ld de,-MI_CORE
        add hl,de
        pop de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call vmnt
        pop hl
        ret

; readi / writei / itrunc on a mounted file: the type's own.
vfs_readi:
        call vixe
        ld a,FO_READ
        jp vop
vfs_writei:
        call vixe
        ld a,FO_WRITE
        jp vop
vfs_trunc:                      ; (itrunc keeps HL: unlink and close rely on it)
        push hl
        push de
        push bc
        call vixe
        ld a,FO_TRUNC
        call vop
        pop bc
        pop de
        pop hl
        ret

; vfs_iget: i-number HL (>= 1000h) -> IX, as iget does: keeps HL, DE,
; BC; CF, A = ENOENT if there is no such i-node.
vfs_iget:
        push de
        push bc
        push iy
        call vmnt
        jr c,.bad
        ld a,h
        and 0Fh
        ld d,a
        ld e,l
        or e
        jr z,.bad               ; i-node 0
        push hl
        ld l,(iy+M_INOS)
        ld h,(iy+M_INOS+1)
        or a
        sbc hl,de
        pop hl
        jr c,.bad               ; past the last
        ld ix,micache           ; in the cache?
        ld b,NMI
.s:     ld a,(ix+MI_NUM)
        cp l
        jr nz,.n
        ld a,(ix+MI_NUM+1)
        cp h
        jr z,.hit
.n:     ld de,MISZ
        add ix,de
        djnz .s
        call vvict              ; no: a slot for it (IX), from the disk
        ld (ix+MI_NUM),l
        ld (ix+MI_NUM+1),h
        push hl
        ld a,h
        and 0Fh
        ld h,a
        push ix
        pop de
        ld a,e
        add a,MI_CORE
        ld e,a
        jr nc,.c
        inc d
.c:     ld a,FO_ILOAD
        call vop
        jr c,.lerr
        call vshad              ; the shadow: as on the disk
        pop hl
.hit:   ld a,(vclock)
        inc a
        ld (vclock),a
        ld (ix+MI_AGE),a
        ld de,MI_CORE
        add ix,de
        ld a,1
        ld (vdirty),a
        pop iy
        pop bc
        pop de
        or a
        ret
.lerr:  pop hl
        xor a
        ld (ix+MI_NUM),a
        ld (ix+MI_NUM+1),a
.bad:   pop iy
        pop bc
        pop de
        ld a,ENOENT
        scf
        ret

; vshad: cache slot IX: shadow = core.  Keeps IX.
vshad:  push ix
        pop hl
        ld de,MI_CORE
        add hl,de
        push hl
        ld de,32
        add hl,de
        ex de,hl
        pop hl
        ld bc,32
        ldir
        ret

; vvict: IX = a cache slot to load into: a free one, or the one used
; longest ago (its i-node written back first).  Keeps HL, IY.
vvict:  push hl
        push iy
        ld ix,micache
        ld iy,micache           ; the best so far ...
        ld c,0                  ; ... and how long ago it was used
        ld b,NMI
.l:     ld a,(ix+MI_NUM)
        or (ix+MI_NUM+1)
        jr z,.take
        ld a,(vclock)
        sub (ix+MI_AGE)
        cp c
        jr c,.n
        ld c,a
        push ix
        pop iy
.n:     ld de,MISZ
        add ix,de
        djnz .l
        push iy
        pop ix
        call vwb1
.take:  pop iy
        pop hl
        ret

; vwb1: cache slot IX: if its i-node changed, to the disk.  Keeps IX, IY.
vwb1:   ld a,(ix+MI_NUM)
        or (ix+MI_NUM+1)
        ret z
        push ix
        pop hl
        ld de,MI_CORE
        add hl,de
        ld d,h
        ld e,l
        ld bc,32
        add hl,bc               ; HL: shadow, DE: core
        ld b,32
.c:     ld a,(de)
        cp (hl)
        jr nz,.w
        inc hl
        inc de
        djnz .c
        ret                     ; the same
.w:     push iy
        ld l,(ix+MI_NUM)
        ld h,(ix+MI_NUM+1)
        call vmnt
        jr c,.x
        ld a,h
        and 0Fh
        ld h,a
        push ix
        pop de
        ld a,e
        add a,MI_CORE
        ld e,a
        jr nc,.s
        inc d
.s:     ld a,FO_ISTORE
        call vop
        call vshad
.x:     pop iy
        ret

; vsync: at the end of every system call (sysx): if mounted i-nodes were
; used, the changed ones to the disk, and every mounted disk flushed.
; Keeps every register.
vsync:  push af
        ld a,(vdirty)
        or a
        jr z,.x0
        xor a
        ld (vdirty),a
        push bc
        push de
        push hl
        push ix
        push iy
        ld ix,micache
        ld b,NMI
.i:     push bc
        call vwb1
        pop bc
        ld de,MISZ
        add ix,de
        djnz .i
        ld iy,mtab
        ld b,NMOUNT
.m:     ld a,(iy+M_TYPE)
        or a
        jr z,.mn
        push bc
        ld a,FO_SYNC
        call vop
        pop bc
.mn:    ld de,MNTSZ
        add iy,de
        djnz .m
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
.x0:    pop af
        ret

; vfs_ialloc: ialloc for a new file in a mounted directory (u_pdir):
; HL = its i-number, IX = a cleared in-core i-node; CF, A = ENOSPC.
; Keeps DE, BC.
vfs_ialloc:
        push de
        push bc
        push iy
        ld hl,(u_pdir)
        call vmnt
        jr c,.e
        ld a,FO_IALLOC
        call vop
        jr c,.e
        call vmhi
        or h
        ld h,a
        pop iy
        call vfs_iget
        jr c,.e2
        push hl
        push ix
        pop hl
        ld b,32
.z:     ld (hl),0
        inc hl
        djnz .z
        pop hl
        pop bc
        pop de
        or a
        ret
.e:     pop iy
.e2:    pop bc
        pop de
        ld a,ENOSPC
        scf
        ret

; vfs_ifree: ifree of a mounted i-node HL.
vfs_ifree:
        call vfs_iget
        ret c
        ld (ix+0),0
        ld (ix+1),0
        push iy
        call vmnt
        jr c,.x
        ld a,h
        and 0Fh
        ld h,a
        ld a,FO_IFREE
        call vop
.x:     pop iy
        ret

; vfscross: namei found i-number HL for u_name in directory u_pdir.
; ".." in the root of a mounted file system is the parent of the
; directory it is mounted on; a directory something is mounted on is the
; root of what is mounted there.  HL = the i-number to go on with.
vfscross:
        ld a,(u_name)
        cp '.'
        jr nz,vcover
        ld a,(u_name+1)
        cp '.'
        jr nz,vcover
        ld a,(u_name+2)
        or a
        jr nz,vcover
        push hl
        push iy
        ld hl,(u_pdir)
        ld a,h
        and 0Fh
        or a
        jr nz,.np               ; not i-node 1 of a mount ...
        dec l
        jr nz,.np
        inc l
        call vmnt
        jr c,.np                ; ... or not a mount at all
        ld l,(iy+M_COVER)       ; the covered directory's own "..": its
        ld h,(iy+M_COVER+1)     ; second entry (RAM or disk alike)
        call iget
        jr c,.np
        ld hl,10
        ld de,u_dirbuf
        ld bc,2
        xor a
        call iio
        jr c,.np
        ld hl,(u_dirbuf)
        pop iy
        pop af
        jr vcover               ; (mounted on in its turn?)
.np:    pop iy
        pop hl
; vcover: HL is a directory something is mounted on: Z, HL = the root
; mounted there.  Else NZ, HL as it was.  Uses A, B, DE.
vcover: push iy
        ld iy,mtab
        ld b,NMOUNT
.m:     ld a,(iy+M_TYPE)
        or a
        jr z,.n
        ld a,(iy+M_COVER)
        cp l
        jr nz,.n
        ld a,(iy+M_COVER+1)
        cp h
        jr nz,.n
        call vmhi               ; the mounted root: i-node 1
        ld h,a
        ld l,1
        pop iy
        xor a
        ret
.n:     ld de,MNTSZ
        add iy,de
        djnz .m
        pop iy
        or 1
        ret

; vbusy: Z if i-number HL has something mounted on it.  Keeps HL.
vbusy:  push hl
        call vcover
        pop hl
        ret

; ---------------------------------------------------------------------
; sys mount (21): HL = a disk (/dev/fd0-3), DE = a directory, BC = the
;   file system type: 0 (any in the type table), a name, or a module's
;   path (fsmod.asm).
; sys umount (22): HL = the disk.
; ---------------------------------------------------------------------
sysmnt: ld (u_tmp),de
        ld (vdev),hl
        ld a,b                  ; a file system type asked for?
        or c
        ld (vwant),a
        jr z,.any
        ld h,b
        ld l,c
        call vtype              ; built in, loaded, or loaded now
        jp c,vmerr
        ld (vwant),a
.any:   ld hl,(vdev)
        call vdisk
        jp c,vmerr
        call vfind              ; mounted already?
        ld a,EBUSY
        jp nc,vmerr
        ld hl,(u_tmp)
        call nami
        jp c,vmerr
        bit 6,(ix+1)
        ld a,ENOTDIR
        jp z,vmerr
        ld a,EBUSY              ; not the root, nor a mounted root, nor
        ld de,ROOTINO           ; mounted on already
        call cphlde
        jp z,vmerr
        ld a,h
        and 0Fh
        or a
        jr nz,.nr
        ld a,h
        or a
        jr z,.nr
        ld a,l
        dec a
        ld a,EBUSY
        jp z,vmerr
.nr:    call vbusy
        ld a,EBUSY
        jp z,vmerr
        ld (vcov),hl
        ld iy,mtab              ; a free entry
        ld b,NMOUNT
.f:     ld a,(iy+M_TYPE)
        or a
        jr z,.got
        ld de,MNTSZ
        add iy,de
        djnz .f
        ld a,EBUSY
        jp vmerr
.got:   ld a,(vdrv)             ; the disk, afresh
        call binval
        ld a,(vdrv)
        call blkprobe           ; what disk is in it (the platform's)
        jp c,vmerr
        ld a,(vwant)            ; which type is it?  The one asked for,
        ld b,a                  ; or each known one in turn
        or a
        jr nz,.t
        inc b
.t:     ld a,b
        call vfst
        ld a,(hl)
        inc hl
        or (hl)
        jr z,.tn                ; (a free entry of the type table)
        ld (iy+M_TYPE),b
        push bc
        ld a,FO_MOUNT
        call vop
        pop bc
        jr nc,.ok
.tn:    ld a,(vwant)
        or a
        jr nz,.no
        inc b
        ld a,b
        cp NFST+1
        jr c,.t
.no:    ld (iy+M_TYPE),0
        ld a,EINVAL             ; no file system we know
        jp vmerr
.ok:    ld a,(vdrv)
        ld (iy+M_DRV),a
        ld hl,(vcov)
        ld (iy+M_COVER),l
        ld (iy+M_COVER+1),h
        ld a,b                  ; one more mount of its type
        call vfst
        inc hl                  ; (FT_REF)
        inc hl
        inc hl
        inc hl
        inc (hl)
        jp sysok
; vmerr: sys mount fails with A: a type loaded for it goes again.
vmerr:  push af
        call vgc
        pop af
        jp syserr

sysumnt:
        call vdisk
        jp c,syserr
        call vfind
        ld a,EINVAL
        jp c,syserr             ; not mounted
        call vmhi
        ld c,a
        ld hl,fsp               ; open files on it?
        ld b,NFILES
.o:     push hl
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)               ; count
        pop hl
        or a
        jr z,.on
        inc hl
        ld a,(hl)
        dec hl
        and 0F0h
        cp c
        jp z,.busy
.on:    ld de,FSPSZ
        add hl,de
        djnz .o
        push iy                 ; another file system mounted in it?
        ld iy,mtab
        ld b,NMOUNT
.mi:    ld a,(iy+M_TYPE)
        or a
        jr z,.mn
        ld a,(iy+M_COVER+1)
        and 0F0h
        cp c
        jr z,.mb
.mn:    ld de,MNTSZ
        add iy,de
        djnz .mi
        pop iy
        ld a,(u_cdir+1)         ; a current directory in it?
        and 0F0h
        cp c
        jr z,.busy
        ld b,0
.p:     ld a,(cur)
        cp b
        jr z,.pn
        ld a,b
        ld l,a
        ld h,p_stat >> 8
        ld a,(hl)
        or a
        jr z,.pn
        ld a,b
        ld hl,p_save
        push bc
        call getw2
        pop bc
        ld a,h
        or l
        jr z,.pn
        inc hl
        inc hl
        inc hl
        ld a,(hl)               ; its saved u_cdir, high byte
        and 0F0h
        cp c
        jr z,.busy
.pn:    call nxslot
        jr c,.p
        ld a,1                  ; all of it to the disk
        ld (vdirty),a
        call vsync
        ld ix,micache           ; its i-nodes leave the cache
        ld b,NMI
.c:     ld a,(ix+MI_NUM+1)
        and 0F0h
        cp c
        jr nz,.cn
        xor a
        ld (ix+MI_NUM),a
        ld (ix+MI_NUM+1),a
.cn:    ld de,MISZ
        add ix,de
        djnz .c
        ld a,(iy+M_DRV)
        call binval
        ld a,(iy+M_TYPE)        ; one mount fewer of its type: the
        call vfst               ; last one of a loaded type unloads it
        inc hl                  ; (FT_REF)
        inc hl
        inc hl
        inc hl
        dec (hl)
        ld (iy+M_TYPE),0
        call vgc
        jp sysok
.mb:    pop iy
.busy:  ld a,EBUSY
        jp syserr

; vdisk: path HL -> (vdrv) = the unit of a block device; CF, A else.
vdisk:  call nami
        ret c
        ld a,h
        or a
        jr nz,.nb
        ld a,l
        call blkunit            ; a block device: its unit (the platform's)
        jr c,.nb
        ld (vdrv),a
        or a
        ret
.nb:    ld a,ENOTBLK
        scf
        ret

; vfind: IY = the mount of drive (vdrv); CF if it is not mounted.
vfind:  ld iy,mtab
        ld b,NMOUNT
.l:     ld a,(iy+M_TYPE)
        or a
        jr z,.n
        ld a,(vdrv)
        cp (iy+M_DRV)
        ret z
.n:     ld de,MNTSZ
        add iy,de
        djnz .l
        scf
        ret

; ---------------------------------------------------------------------
vdirty: db 0                    ; mounted i-nodes used since the last vsync
vclock: db 0
vdrv:   db 0
vcov:   dw 0
vdev:   dw 0                    ; sys mount: the disk's path
vwant:  db 0                    ; sys mount: the type asked for (0: any)
mtab:   ds NMOUNT*MNTSZ, 0
micache: ds NMI*MISZ, 0
