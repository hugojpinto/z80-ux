; =====================================================================
; ZX-UX on the Timex FDD3000: TOS disks, a file system module.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  mount -t tos /dev/fdN dir: the disks of TOS, the FDD3000's own system,
;  read and written.  A module (fsmod.asm; fdd3000/tools/fsmod.py makes
;  /etc/fs/tos from this file); fdd3000/tools/tosfs.py is its reference
;  on the host.
;
;  The format (tos40; TOS4's, with no system tracks, as well).  Tracks of
;  16 sectors of 256 bytes; logical sector L of a track is the sector
;  whose ID is tskew[L] (TOS's 7:1 interleave, directory and data alike;
;  the table is its own inverse).  After TOS's 4 system tracks - none on a
;  TOS4 disk - one track holds the directory: 128 entries of 32 bytes.
;  Space is given in allocation units (AU) of 1K, 4 sectors, numbered
;  from the directory track (AUs 0-3 are the directory).  An entry:
;     0  parent: the directory's id (0: the root; 1-15 subdirectories),
;        bit 7 set if the entry is a directory itself - its own id is in
;        its first AU byte; E5h: a free entry; FFh: entry 0, the disk
;     1  name (8), 9 extension (3), space-padded; bit 7 of extension byte
;        0 read only, of byte 1 hidden
;    12  part: a file is one entry for each 16K, parts 0, 1, ...
;    13  bytes in the part's last sector (0: 256)
;    14  the part's size in 128-byte records, high, low
;    16  its AUs, 16 bytes (0: none)
;
;  How it looks to ZX-UX.  I-numbers: 1 the root, 100h + n the file or
;  directory whose (first) entry is entry n.  A directory reads as 129
;  10-byte entries: ".", "..", then one for each entry of the table, the
;  ones of this directory filled in: "name.ext" in lower case, or, if
;  that is longer than 8, the name's first 5 letters, "~" and n in hex
;  (biomas2.bas: bioma~11).  The kernel's own directory writes become
;  changes of the table:
;    - an i-number written into an entry names that file - its own table
;      entry, wherever the kernel writes it (a new name is split at its
;      last dot and put in upper case);
;    - a second name for a file that has one is refused (EPERM): TOS has
;      no links (mv copies instead);
;    - an entry cleared: a file loses its name (parent 7Fh, its name its
;      entry's number) until its last close frees it; an empty directory
;      is freed at once; one that is not empty stays;
;    - "." and ".." are always there: written, nothing happens.
;  Files are their bytes on the disk, TOS's 7-byte header included.
;  Writing past the end fills with zeros (TOS has no holes).  The free
;  AUs are a bitmap made at mount time.  Times are not kept.
; =====================================================================

TE_PAR  equ 0                   ; an entry's fields
TE_NAME equ 1
TE_EXT  equ 9
TE_PART equ 12
TE_TAIL equ 13
TE_SZHI equ 14
TE_SZLO equ 15
TE_AU   equ 16
TFREE   equ 0E5h
TORPH   equ 07Fh                ; a file with no name, still open
TDSIZE  equ 129*10              ; a directory's size
TMODE   equ 0Eh                 ; rw for the owner, r for others
TMAPSZ  equ 20                  ; the AU bitmap of a mount: 160 AUs

tfsops: dw tmount, tiload, tistore, tread, twrite, ttrunc, tialloc, tifree
        dw tsync

; ---------------------------------------------------------------------
; The table.
; ---------------------------------------------------------------------
; tent: entry A of mount IY -> HL = it, in a buffer (tf_buf); CF, A.
; Keeps IX, IY.  (Another bget may reuse the buffer.)
tent:   ld (tf_e),a
        rrca
        rrca
        rrca
        and 0Fh
        ld hl,tskew             ; (the directory is interleaved too)
        call addhla
        ld l,(hl)
        ld h,0
        ld e,(iy+M_BASE)
        ld d,(iy+M_BASE+1)
        add hl,de
        ex de,hl
        ld a,(iy+M_DRV)
        call bget
        ret c
        ld a,b
        ld (tf_buf),a
        ld a,(tf_e)
        and 7
        rrca
        rrca
        rrca
        call addhla
        or a
        ret

; tdirty: the buffer of the last tent was written.  Keeps HL, DE.
tdirty: push hl
        ld a,(tf_buf)
        ld b,a
        call bdirty
        pop hl
        ret

; tino: IX -> A = its table entry (0: the root).  Keeps the rest.
tino:   ld a,(ix+MI_NUM+1-MI_CORE)
        and 0Fh
        ret z                   ; (1: the root)
        ld a,(ix+MI_NUM-MI_CORE)
        ret

; tid: A = a directory's entry (0: the root) -> A = its id; CF, A.
tid:    or a
        ret z
        call tent
        ret c
        ld de,TE_AU
        add hl,de
        ld a,(hl)
        or a
        ret

; tkey: entry A -> tf_key: parent, name and extension (attributes off).
tkey:   call tent
        ret c
        ld de,tf_key
        ld bc,12
        ldir
        ld hl,tf_key+TE_EXT
        ld b,3
.m:     res 7,(hl)
        inc hl
        djnz .m
        or a
        ret

; tpart: part A of the file with key tf_key -> A = its entry; CF if
; none (or an error).  Part 0 is entry (tf_i0).
tpart:  or a
        jr nz,.s
        ld a,(tf_i0)
        ret
.s:     ld (tf_p),a
        ld hl,tf_pc             ; the last answer?
        call vmhi
        cp (hl)
        jr nz,.scan
        inc hl
        ld a,(tf_i0)
        cp (hl)
        jr nz,.scan
        inc hl
        ld a,(tf_p)
        cp (hl)
        jr nz,.scan
        inc hl
        ld a,(hl)
        or a
        ret
.scan:  ld c,1
.l:     ld a,c
        push bc
        call tent
        pop bc
        ret c
        push hl
        ld de,tf_key            ; parent, name
        ld b,TE_EXT
.c:     ld a,(de)
        cp (hl)
        jr nz,.n
        inc hl
        inc de
        djnz .c
        ld b,3                  ; extension, attributes off
.e:     ld a,(hl)
        and 7Fh
        ex de,hl
        cp (hl)
        ex de,hl
        jr nz,.n
        inc hl
        inc de
        djnz .e
        ld a,(tf_p)             ; part
        cp (hl)
        jr nz,.n
        pop hl
        ld hl,tf_pc             ; remembered
        call vmhi
        ld (hl),a
        inc hl
        ld a,(tf_i0)
        ld (hl),a
        inc hl
        ld a,(tf_p)
        ld (hl),a
        inc hl
        ld (hl),c
        ld a,c
        or a
        ret
.n:     pop hl
        inc c
        bit 7,c
        jr z,.l
        scf
        ret

; tpcx: the remembered part is no more (a table change).
tpcx:   xor a
        ld (tf_pc),a
        ret

; tbytes: the entry at HL -> HL = the bytes in its part.
tbytes: ld de,TE_TAIL
        add hl,de
        ld a,(hl)               ; tail
        inc hl
        ld d,(hl)               ; records
        inc hl
        ld e,(hl)
        or a
        jr nz,.t
        ex de,hl                ; whole sectors: records * 128
        xor a
        srl h
        rr l
        rra
        ld h,l
        ld l,a
        ret
.t:     ld l,a                  ; ((records + 1) / 2 - 1) * 256 + tail
        inc de
        srl d
        rr e
        dec e
        ld h,e
        ret

; tsize: the size of the file whose entry is A (its parts added; 64K
; and more: FFFFh) -> HL; CF, A.
tsize:  ld (tf_i0),a
        call tkey
        ret c
        ld hl,0
        ld (tf_sz),hl
        xor a
.l:     ld (tf_q),a
        call tpart
        jr c,.x
        call tent
        ret c
        call tbytes
        push hl
        ld de,(tf_sz)
        add hl,de
        jr nc,.n
        ld hl,0FFFFh
.n:     ld (tf_sz),hl
        pop hl
        ld de,4000h             ; a full part: there may be another
        call cphlde
        jr nz,.x
        ld a,(tf_q)
        inc a
        cp 4
        jr c,.l
.x:     ld hl,(tf_sz)
        or a
        ret

; tnsub: A = a directory's id -> A = its subdirectories (for its links).
tnsub:  ld (tf_d),a
        xor a
        ld (tf_q),a
        ld c,1
.l:     ld a,c
        push bc
        call tent
        pop bc
        jr c,.x
        ld a,(hl)
        cp TFREE
        jr z,.n
        bit 7,a
        jr z,.n
        and 7Fh
        ld b,a
        ld a,(tf_d)
        cp b
        jr nz,.n
        ld hl,tf_q
        inc (hl)
.n:     inc c
        bit 7,c
        jr z,.l
.x:     ld a,(tf_q)
        ret

; tkids: NZ if directory id A has something in it (or on an error).
tkids:  ld (tf_d),a
        ld c,1
.l:     ld a,c
        push bc
        call tent
        pop bc
        jr c,.yes
        ld a,(hl)
        and 7Fh
        ld b,a
        ld a,(tf_d)
        cp b
        jr z,.yes
        inc c
        bit 7,c
        jr z,.l
        xor a
        ret
.yes:   or 1
        ret

; tdino: directory id A -> HL = its i-number (the root's if none).
tdino:  ld hl,1
        or a
        ret z
        ld (tf_d),a
        ld c,1
.l:     ld a,c
        push bc
        call tent
        pop bc
        jr c,.r
        ld a,(hl)
        cp TFREE
        jr z,.n
        bit 7,a
        jr z,.n
        ld de,TE_AU
        add hl,de
        ld a,(tf_d)
        cp (hl)
        jr nz,.n
        ld h,1
        ld l,c
        ret
.n:     inc c
        bit 7,c
        jr z,.l
.r:     ld hl,1
        ret

; tfreeid: a directory id no directory has -> A; CF if none.
tfreeid: ld a,1
.l:     ld (tf_d),a
        ld c,1
.e:     ld a,c
        push bc
        call tent
        pop bc
        ret c
        ld a,(hl)
        cp TFREE
        jr z,.n
        bit 7,a
        jr z,.n
        ld de,TE_AU
        add hl,de
        ld a,(tf_d)
        cp (hl)
        jr z,.used
.n:     inc c
        bit 7,c
        jr z,.e
        ld a,(tf_d)
        or a
        ret
.used:  ld a,(tf_d)
        inc a
        cp 16
        jr c,.l
        scf
        ret

; tnewent: a free entry, emptied, its key tf_key -> A; CF, A = ENOSPC.
tnewent: ld c,1
.l:     ld a,c
        push bc
        call tent
        pop bc
        ret c
        ld a,(hl)
        cp TFREE
        jr z,.got
        inc c
        bit 7,c
        jr z,.l
        ld a,ENOSPC
        scf
        ret
.got:   push bc
        ex de,hl
        ld hl,tf_key
        ld bc,12
        ldir
        ld b,20
        xor a
.z:     ld (de),a
        inc de
        djnz .z
        call tdirty
        pop bc
        ld a,c
        or a
        ret

; ---------------------------------------------------------------------
; The free AUs.
; ---------------------------------------------------------------------
; tbit: AU A of mount IY -> HL = its byte in the bitmap, C = its bit.
tbit:   push af
        and 7
        ld b,a
        ld c,1
        inc b
.m:     dec b
        jr z,.m1
        sla c
        jr .m
.m1:    call vmhi               ; the mount's bitmap: (k+1)*16 -> k*20
        rrca
        rrca
        rrca
        rrca
        dec a
        ld b,a
        ld hl,tf_map
        ld de,TMAPSZ
        inc b
.k:     dec b
        jr z,.k1
        add hl,de
        jr .k
.k1:    pop af
        rrca
        rrca
        rrca
        and 1Fh
        jp addhla

; tuse: AU A in use.  tunuse: free (AUs 0-3 stay in use).
tuse:   call tbit
        ld a,(hl)
        or c
        ld (hl),a
        ret
tunuse: cp 4
        ret c
        call tbit
        ld a,c
        cpl
        and (hl)
        ld (hl),a
        ret

; tfreeaus: the AUs of the entry at HL are free; the entry has none.
tfreeaus:
        ld de,TE_AU
        add hl,de
        ld b,16
.l:     ld a,(hl)
        ld (hl),0
        or a
        jr z,.n
        push hl
        push bc
        call tunuse
        pop bc
        pop hl
.n:     inc hl
        djnz .l
        ret

; talloc: a free AU, now in use and zeroed -> A; CF, A = ENOSPC.
talloc: ld a,4
.l:     ld (tf_ta),a
        cp (iy+M_BLKS)
        jr nc,.full
        call tbit
        ld a,(hl)
        and c
        jr z,.got
        ld a,(tf_ta)
        inc a
        jr .l
.got:   ld a,(hl)
        or c
        ld (hl),a
        xor a
.z:     ld (tf_tc),a            ; its 4 sectors: zeros
        ld c,a
        ld a,(tf_ta)
        call tsect
        ld a,(iy+M_DRV)
        call bget
        ret c
        push bc
        ld b,0
.zb:    ld (hl),0
        inc hl
        djnz .zb
        pop bc
        call bdirty
        ld a,(tf_tc)
        inc a
        cp 4
        jr c,.z
        ld a,(tf_ta)
        or a
        ret
.full:  ld a,ENOSPC
        scf
        ret

; tsect: AU A, sector C of it -> DE = the sector on the disk: logical
; sector L of a track is the one with ID tskew[L].
tsect:  ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld a,c
        call addhla
        ld a,l
        and 0F0h
        ld b,a
        ld a,l
        and 0Fh
        push hl
        ld hl,tskew
        call addhla
        ld a,(hl)
        pop hl
        or b
        ld l,a
        ld e,(iy+M_BASE)
        ld d,(iy+M_BASE+1)
        add hl,de
        ex de,hl
        ret

; ---------------------------------------------------------------------
; Mount, sync.
; ---------------------------------------------------------------------
; tmount: a TOS directory on drive (vdrv)?  At track 4 (after TOS's
; system tracks), else at track 0 (TOS4).  Fills IY's entry; CF if not.
tmount: ld a,(vdrv)
        ld (iy+M_DRV),a
        ld hl,64
.try:   ld (iy+M_BASE),l
        ld (iy+M_BASE+1),h
        xor a
        call tent
        ret c
        ld a,(hl)
        inc a                   ; FFh: entry 0, the disk
        jp nz,.no
        ld de,TE_EXT
        add hl,de
        ld de,s_tdir
        ld b,3
.c:     ld a,(hl)
        and 7Fh
        ex de,hl
        cp (hl)
        ex de,hl
        jr nz,.no
        inc hl
        inc de
        djnz .c
        ld a,(iy+M_BASE)        ; 40 tracks: AUs up to 144 or 160
        or a
        ld a,144
        jr nz,.lim
        ld a,160
.lim:   ld (iy+M_BLKS),a
        ld (iy+M_BLKS+1),0
        ld (iy+M_INOS),7Fh      ; i-numbers up to 17Fh
        ld (iy+M_INOS+1),1
        call vmhi               ; the bitmap: the directory's AUs ...
        xor a
        call tbit
        ld b,TMAPSZ
.zm:    ld (hl),0
        inc hl
        djnz .zm
        ld a,0
        call tuse
        ld a,1
        call tuse
        ld a,2
        call tuse
        ld a,3
        call tuse
        ld c,1                  ; ... and every file's
.f:     ld a,c
        push bc
        call tent
        pop bc
        ret c
        ld a,(hl)
        cp TFREE
        jr z,.fn
        bit 7,a
        jr nz,.fn               ; (a directory's AU byte is its id)
        ld de,TE_AU
        add hl,de
        ld b,16
.a:     ld a,(hl)
        or a
        jr z,.fn
        push hl
        push bc
        ld e,(iy+M_BLKS)
        cp e
        call c,tuse
        pop bc
        pop hl
        inc hl
        djnz .a
.fn:    inc c
        bit 7,c
        jr z,.f
        call tpcx
        or a
        ret
.no:    ld a,(iy+M_BASE)
        or a
        ld hl,0
        jp nz,.try
        ld a,EINVAL
        scf
        ret
s_tdir: db "DIR"

; tsync: the buffers to the disk.
tsync:  ld a,(iy+M_DRV)
        jp bflush

; ---------------------------------------------------------------------
; I-nodes.
; ---------------------------------------------------------------------
; tiload: own i-number HL into the 32 bytes at DE.
tiload: ld (tf_dst),de
        push hl
        ld h,d
        ld l,e
        ld b,32
.z:     ld (hl),0
        inc hl
        djnz .z
        pop hl
        ld a,h
        or a
        jr nz,.ent
        dec l                   ; 1: the root
        jr nz,.bad
        xor a
        jr .dir
.ent:   dec h
        jr nz,.bad
        ld a,l
        or a
        jp m,.bad
        jr z,.bad
        ld (tf_i0),a
        call tent
        ret c
        ld a,(hl)
        cp TFREE
        jr z,.bad
        bit 7,a
        jr z,.file
        ld de,TE_AU             ; a directory: its id
        add hl,de
        ld a,(hl)
.dir:   call tnsub              ; links: 2 + its subdirectories
        add a,2
        ld hl,(tf_dst)
        inc hl
        inc hl
        ld (hl),a
        ld hl,TDSIZE
        ld b,0C0h               ; IALLOC, IFDIR
        jr .set
.file:  ld de,TE_EXT
        add hl,de
        ld a,(hl)               ; read only: no writing for the owner
        ld (tf_q),a
        ld a,(tf_i0)
        call tent
        ret c
        ld a,(hl)
        cp TORPH
        ld a,1                  ; links: 1, or 0 (no name, still open)
        jr nz,.lk
        xor a
.lk:    ld hl,(tf_dst)
        inc hl
        inc hl
        ld (hl),a
        ld a,(tf_i0)
        call tsize
        ret c
        ld b,80h                ; IALLOC
.set:   ex de,hl                ; DE = the size
        ld hl,(tf_dst)
        ld a,TMODE
        bit 6,b
        jr nz,.m
        ld c,a
        ld a,(tf_q)
        bit 7,a
        ld a,c
        jr z,.m
        and 0FFh-IWOWN
.m:     ld (hl),a               ; flags
        inc hl
        ld (hl),b
        inc hl
        inc hl
        inc hl
        ld (hl),e               ; size
        inc hl
        ld (hl),d
        or a
        ret
.bad:   ld a,ENOENT
        scf
        ret

; tistore: the 32 bytes at DE to own i-number HL.  Only what TOS keeps:
; a new directory becomes one; read only.  A directory's links and size
; are made right again in the kernel's copy (DE), whatever unlink of "."
; or ".." did, or ialloc's zeros.
tistore:
        ld (tf_dst),de
        inc de
        ld a,(de)
        bit 7,a                 ; freed: nothing
        ret z
        ld (tf_q),a
        ld a,h
        or a
        jr nz,.ent
        xor a                   ; the root
        jr .lk
.ent:   ld a,l
        ld (tf_i0),a
        call tent
        ret c
        ld a,(hl)
        cp TFREE
        ret z
        cp TORPH
        ret z
        bit 7,a
        jr nz,.isdir
        ld a,(tf_q)             ; a file
        bit 6,a
        jr nz,.mkdir
        ld de,TE_EXT            ; read only?
        add hl,de
        res 7,(hl)
        ld de,(tf_dst)
        ld a,(de)
        and IWOWN
        jr nz,.rw
        set 7,(hl)
.rw:    jp tdirty
.mkdir: call tfreeid            ; a new directory: an id ...
        ret c                   ; (none: it stays a file)
        ld (tf_d),a
        ld a,(tf_i0)
        call tent
        ret c
        set 7,(hl)              ; ... and the form of one
        ld de,TE_EXT
        add hl,de
        ex de,hl
        ld hl,s_tdir
        ld bc,3
        ldir
        ex de,hl
        ld b,20
.zz:    ld (hl),0
        inc hl
        djnz .zz
        ld de,-16
        add hl,de
        ld a,(tf_d)
        ld (hl),a
        call tdirty
        ld a,(tf_d)
        jr .lk
.isdir: ld de,TE_AU
        add hl,de
        ld a,(hl)
.lk:    call tnsub
        add a,2
        ld hl,(tf_dst)
        inc hl
        inc hl
        ld (hl),a               ; links
        inc hl
        inc hl
        ld (hl),low TDSIZE      ; and size (a new one's was 0: namei
        inc hl                  ; would find no entries in it)
        ld (hl),high TDSIZE
        or a
        ret

; tialloc: HL = a free own i-number: an entry with no name yet.
tialloc:
        ld a,TORPH
        ld (tf_key),a
        ld hl,tf_key+TE_NAME
        ld b,11
.s:     ld (hl),' '
        inc hl
        djnz .s
        call tnewent
        ret c
        ld (tf_i0),a
        call tent               ; its name: its number
        ret c
        inc hl
        ld (hl),1
        inc hl
        ld a,(tf_i0)
        ld (hl),a
        call tdirty
        ld a,(tf_i0)
        ld l,a
        ld h,1
        or a
        ret

; tifree: own i-number HL was freed: its entries are.
tifree: ld a,h
        or a
        ret z
        ld a,l
; tkill: entry A and its other parts: free, and their AUs.
tkill:  ld (tf_i0),a
        call tkey
        ret c
        call tpcx
        ld a,3
.p:     ld (tf_q),a
        call tpart
        jr c,.n
        call tent
        ret c
        push hl
        call tfreeaus
        pop hl
        call .e5
.n:     ld a,(tf_q)
        dec a
        jr nz,.p
        ld a,(tf_i0)
        call tent
        ret c
        push hl
        ld a,(hl)
        bit 7,a                 ; (a directory's AU byte is its id)
        call z,tfreeaus
        pop hl
.e5:    ld b,32
.f:     ld (hl),TFREE
        inc hl
        djnz .f
        jp tdirty

; ---------------------------------------------------------------------
; readi, writei, itrunc.
; ---------------------------------------------------------------------
; tread: u_count bytes from u_off of IX to u_base, up to its end.
tread:  ld hl,0
        ld (u_nread),hl
        bit 6,(ix+1)
        jp nz,tdread
        call tino
        ld (tf_i0),a
        call tkey
        jr c,.err
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        call isize
        ld de,(u_off)
        or a
        sbc hl,de
        jr z,.ok
        jr c,.ok
        push hl
        call tchunk
        pop de
        call minhlde
        ld (tf_n),hl
        call tloc               ; its AU
        jr c,.zero
        or a
        jr z,.zero
        ld c,b
        call tsect
        ld a,(iy+M_DRV)
        call bget
        jr c,.err
        ld a,(u_off)
        call addhla
        ld de,(u_base)
        ld bc,(tf_n)
        ldir
        jr .adv
.zero:  ld hl,(u_base)
        ld bc,(tf_n)
.hz:    ld (hl),0
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.hz
.adv:   ld hl,(tf_n)
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

; tchunk: HL = what fits in u_off's sector: min(256 - offset, u_count).
tchunk: ld a,(u_off)
        ld c,a
        xor a
        sub c
        ld l,a
        ld h,0
        jr nz,.n
        inc h
.n:     ld de,(u_count)
        jp minhlde

; tloc: offset (u_off) of the file keyed tf_key -> A = its AU (0: none),
; B = the sector in it, (tf_j) its part's entry, (tf_a) the AU's place.
; CF: no such part.
tloc:   ld a,(u_off+1)
; tloch: the same for the offset's high byte A.
tloch:  ld c,a
        and 3
        ld b,a
        ld a,c
        and 3Fh
        rrca
        rrca
        and 0Fh
        ld (tf_a),a
        ld a,c
        rlca
        rlca
        and 3
        push bc
        call tpart
        pop bc
        ret c
        ld (tf_j),a
        push bc
        call tent
        pop bc
        ret c
        ld de,TE_AU
        add hl,de
        ld a,(tf_a)
        call addhla
        ld a,(hl)
        or a
        ret

; twrite: u_count bytes from u_base to IX at u_off.
twrite: ld hl,0
        ld (u_nread),hl
        bit 6,(ix+1)
        jp nz,tdwrite
        ld hl,(u_count)
        ld de,(u_off)
        add hl,de
        ld a,EFBIG
        ret c
        call tino
        ld (tf_i0),a
        call tkey
        jp c,.err
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        call isize              ; past the end: zeros up to u_off first
        ld de,(u_off)
        call cphlde
        jr nc,.in
        ld (tf_off),hl
        ex de,hl
        or a
        sbc hl,de               ; the gap
        ld a,(tf_off)
        ld c,a
        xor a
        sub c
        ld e,a
        ld d,0
        jr nz,.g
        inc d
.g:     call minhlde
        ld (tf_n),hl
        ld hl,0
        ld (tf_src),hl
        call tput
        jr c,.err
        ld hl,(tf_off)
        ld de,(tf_n)
        add hl,de
        ld (ix+I_SIZE),l
        ld (ix+I_SIZE+1),h
        jr .l
.in:    call tchunk
        ld (tf_n),hl
        ld hl,(u_off)
        ld (tf_off),hl
        ld hl,(u_base)
        ld (tf_src),hl
        call tput
        jr c,.err
        ld hl,(tf_n)
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

; tput: (tf_n) bytes, within one sector, from (tf_src) - 0: zeros - to
; the file keyed tf_key at (tf_off), which is not past its end.
tput:   ld a,(tf_off+1)
        call tloch
        jr nc,.have
        call tnewent            ; a new part (the last one is full):
        ret c                   ; part 0's key, its part number
        ld (tf_j),a
        call tent
        ret c
        ld de,TE_PART
        add hl,de
        ld a,(tf_off+1)
        rlca
        rlca
        and 3
        ld (hl),a
        call tdirty
        call tpcx
        ld a,(tf_off+1)
        and 3
        ld b,a
        xor a
.have:  ld (tf_au),a
        ld a,b
        ld (tf_c),a
        ld a,(tf_au)
        or a
        jr nz,.sec
        call talloc             ; a new AU for it
        ret c
        ld (tf_au),a
        ld a,(tf_j)
        call tent
        ret c
        ld de,TE_AU
        add hl,de
        ld a,(tf_a)
        call addhla
        ld a,(tf_au)
        ld (hl),a
        call tdirty
.sec:   ld a,(tf_c)
        ld c,a
        ld a,(tf_au)
        call tsect
        ld a,(iy+M_DRV)
        call bget
        ret c
        push bc
        ld a,(tf_off)
        call addhla
        ex de,hl
        ld bc,(tf_n)
        ld hl,(tf_src)
        ld a,h
        or l
        jr z,.zr
        ldir
        jr .wr
.zr:    xor a
.zl:    ld (de),a
        inc de
        dec bc
        ld a,b
        or c
        jr nz,.zr
.wr:    pop bc
        call bdirty
        ld hl,(tf_off)          ; the part longer?  Its end in the part:
        ld a,h
        and 3Fh
        ld h,a
        ld de,(tf_n)
        add hl,de
        ld (tf_sz),hl
        ld a,(tf_j)
        call tent
        ret c
        push hl
        call tbytes
        ld de,(tf_sz)
        call cphlde
        pop hl
        jr nc,.x
        ld de,TE_TAIL           ; tail, records = 2 * sectors
        add hl,de
        ld a,(tf_sz)
        ld (hl),a
        inc hl
        ex de,hl
        ld hl,(tf_sz)
        ld bc,255
        add hl,bc
        ld l,h
        ld h,0
        add hl,hl
        ex de,hl
        ld (hl),d
        inc hl
        ld (hl),e
        call tdirty
.x:     or a
        ret

; ttrunc: free what file IX holds; it is empty.
ttrunc: bit 6,(ix+1)
        ret nz
        call tino
        or a
        ret z
        ld (tf_i0),a
        call tkey
        ret c
        call tpcx
        ld a,3                  ; its other parts go
.p:     ld (tf_q),a
        call tpart
        jr c,.n
        call tent
        ret c
        push hl
        call tfreeaus
        pop hl
        ld b,32
.f:     ld (hl),TFREE
        inc hl
        djnz .f
        call tdirty
.n:     ld a,(tf_q)
        dec a
        jr nz,.p
        ld a,(tf_i0)            ; part 0: no AUs, no bytes
        call tent
        ret c
        push hl
        call tfreeaus
        pop hl
        ld de,TE_TAIL
        add hl,de
        xor a
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        call tdirty
        xor a
        ld (ix+I_SIZE),a
        ld (ix+I_SIZE+1),a
        ret

; ---------------------------------------------------------------------
; Directories.
; ---------------------------------------------------------------------
; tdread: a directory read: its 10-byte entries, made from the table.
tdread: call tdhere
        ret c
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        ld hl,(u_off)
        ld de,TDSIZE
        call cphlde
        jr nc,.ok
        call tslot              ; A = the offset in it
        jr c,.err
        ld b,a
        ld a,10
        sub b
        ld l,a
        ld h,0
        ld de,(u_count)
        call minhlde
        ld (tf_n),hl
        ld hl,tf_slot
        ld a,b
        call addhla
        ld de,(u_base)
        ld bc,(tf_n)
        ldir
        ld hl,(tf_n)
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

; tdhere: the directory IX: (tf_dn) its entry, (tf_d2) its id.
tdhere: call tino
        ld (tf_dn),a
        call tid
        ld (tf_d2),a
        ret

; tslot: the entry of directory (tf_dn, tf_d2) at u_off -> tf_slot (its
; i-number global), A = u_off's place in it, (tf_k) its number.
tslot:  ld hl,(u_off)
        ld de,0
        ld c,10
        call div32
        ld (tf_r),a
        ld a,l
        ld (tf_k),a
        ld hl,tf_slot
        ld b,10
.z:     ld (hl),0
        inc hl
        djnz .z
        ld a,(tf_k)
        cp 2
        jr nc,.ent
        or a
        jr nz,.dd
        ld a,(tf_dn)            ; ".": itself
        or a
        ld hl,1
        jr z,.dot
        ld l,a
        ld h,1
        jr .dot
.dd:    ld a,(tf_dn)            ; "..": its parent
        or a
        ld hl,1
        jr z,.ddn
        call tent
        ret c
        ld a,(hl)
        and 7Fh
        call tdino
.ddn:   ld a,'.'
        ld (tf_slot+3),a
.dot:   ld a,'.'
        ld (tf_slot+2),a
        jr .ino
.ent:   dec a                   ; entry k-1, if it is this directory's
        ld (tf_ej),a
        call tent
        ret c
        ld a,(hl)
        and 7Fh
        ld b,a
        ld a,(tf_d2)
        cp b
        jr nz,.x
        push hl
        ld de,TE_PART
        add hl,de
        ld a,(hl)
        pop hl
        or a
        jr nz,.x
        call tdisp
        ld a,(tf_ej)
        ld l,a
        ld h,1
.ino:   call vmhi               ; global
        or h
        ld h,a
        ld (tf_slot),hl
.x:     ld a,(tf_r)
        or a
        ret

; tdisp: the entry at HL (entry (tf_ej)) -> its name at tf_slot+2.
tdisp:  ld (tf_ptr),hl
        ld a,(hl)               ; a directory: the name only
        ld (tf_q),a
        inc hl
        ld de,tf_nm             ; name: up to its first space, lower case
        ld b,8
        ld c,0
        call .cp
        ld a,c
        ld (tf_nl),a
        ld hl,(tf_ptr)
        ld de,TE_EXT
        add hl,de
        ld de,tf_nm+8
        ld b,3
        ld c,0
        call .cp
        ld a,(tf_q)
        bit 7,a
        jr z,.f
        ld c,0
.f:     ld a,c                  ; C: the extension's length
        ld (tf_xl),a
        ld de,tf_slot+2
        ld hl,tf_nm
        ld a,(tf_nl)
        ld b,a
        ld a,c
        or a
        jr z,.name              ; no extension: the name
        ld a,(tf_nl)
        add a,c
        inc a
        cp 9
        jr nc,.long
        call .mv                ; name.ext
        ld a,'.'
        ld (de),a
        inc de
        ld hl,tf_nm+8
        ld a,(tf_xl)
        ld b,a
        jr .mv
.long:  ld b,5                  ; nnnnn~XX
        call .mv
        ld a,'~'
        ld (de),a
        inc de
        ld a,(tf_ej)
        rrca
        rrca
        rrca
        rrca
        call .hex
        ld a,(tf_ej)
.hex:   and 0Fh
        add a,'0'
        cp '9'+1
        jr c,.h
        add a,'a'-'9'-1
.h:     ld (de),a
        inc de
        ret
.name:  ld a,b
        or a
        ret z
.mv:    ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .mv
        ret
; .cp: B bytes at HL (bit 7 off), up to a space, to DE in lower case
; ('/' as '_'); C = how many.
.cp:    ld a,(hl)
        and 7Fh
        cp ' '+1
        ret c
        cp '/'
        jr nz,.c1
        ld a,'_'
.c1:    cp 'A'
        jr c,.c2
        cp 'Z'+1
        jr nc,.c2
        or 20h
.c2:    ld (de),a
        inc hl
        inc de
        inc c
        djnz .cp
        ret

; tdwrite: a directory written: what each touched entry becomes, done
; to the table.
tdwrite:
        call tdhere
        ret c
.l:     ld hl,(u_count)
        ld a,h
        or l
        jr z,.ok
        call tslot              ; the entry as it is ...
        jr c,.err
        ld b,a
        ld a,10
        sub b
        ld l,a
        ld h,0
        ld de,(u_count)
        call minhlde
        ld (tf_n),hl
        ld hl,tf_slot           ; ... with what is written
        ld a,b
        call addhla
        ex de,hl
        ld hl,(u_base)
        ld bc,(tf_n)
        ldir
        ld a,(tf_k)
        cp 2
        jr c,.adv               ; "." and "..": nothing to do
        call tdset
        jr c,.err
.adv:   ld hl,(tf_n)
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

; tdset: entry (tf_k) of the directory is now tf_slot: do it.
tdset:  ld hl,(tf_slot)
        ld a,h
        and 0Fh
        or l
        jr z,.clr
        ld a,h                  ; a name for own i-number 1xxh
        and 0Fh
        dec a
        ld a,EPERM
        scf
        ret nz                  ; (the root, nothing else, has 1)
        ld a,l
        or a
        scf
        ld a,EPERM
        ret z
        ld a,l
        ld (tf_i0),a
        call tent
        ret c
        ld a,(hl)
        cp TORPH
        ld a,EPERM              ; it has a name: TOS has no links
        scf
        ret nz
        call tsplit             ; the new name, TOS's way -> tf_nm
        ld a,(tf_i0)            ; the key it has now, for its parts
        call tkey
        ret c
        ld a,(tf_d2)
        ld (tf_nm-1),a
        jp tname
.clr:   ld a,(tf_k)             ; the name of entry k-1 goes
        dec a
        ld (tf_i0),a
        call tent
        ret c
        ld a,(hl)
        and 7Fh
        ld b,a
        ld a,(tf_d2)
        cp b
        jr nz,.no               ; (not this directory's)
        push hl
        ld de,TE_PART
        add hl,de
        ld a,(hl)
        pop hl
        or a
        ret nz
        bit 7,(hl)
        jr z,.file
        ld de,TE_AU             ; a directory: freed, if it is empty
        add hl,de
        ld a,(hl)
        call tkids
        ret nz
        ld a,(tf_i0)
        jp tkill
.no:    or a
        ret
.file:  ld a,(tf_i0)            ; a file: no name, till its last close
        call tkey
        ret c
        ld a,TORPH
        ld (tf_nm-1),a
        ld hl,tf_nm
        ld (hl),1
        inc hl
        ld a,(tf_i0)
        ld (hl),a
        inc hl
        ld b,9
.s:     ld (hl),' '
        inc hl
        djnz .s
; tname: entry (tf_i0) and the other parts of key tf_key: parent and name
; from tf_nm-1 (12 bytes; the attributes stay).
tname:  call tpcx
        ld a,3
.p:     ld (tf_q),a
        call tpart
        jr c,.n
        call tent
        ret c
        call .put
.n:     ld a,(tf_q)
        dec a
        jr nz,.p
        call tpcx
        ld a,(tf_i0)
        call tent
        ret c
.put:   ld de,tf_nm-1
        ex de,hl
        ld bc,TE_EXT
        ldir
        ld b,3
.x:     ld a,(de)               ; the extension, attributes kept
        and 80h
        or (hl)
        ld (de),a
        inc hl
        inc de
        djnz .x
        jp tdirty

; tsplit: the name at tf_slot+2 (8, 0-padded) -> tf_nm: TOS's name (8)
; and extension (3), space-padded, upper case: split at the last dot.
tsplit: ld hl,tf_nm
        ld b,11
.s:     ld (hl),' '
        inc hl
        djnz .s
        ld hl,tf_slot+2         ; its length, its last dot
        ld bc,0FF00h            ; B: the dot (FFh: none), C: length
.l:     ld a,(hl)
        or a
        jr z,.e
        cp '.'
        jr nz,.nd
        ld b,c
.nd:    inc hl
        inc c
        ld a,c
        cp 8
        jr c,.l
.e:     ld a,b                  ; a dot, not first, 1-3 after it?
        inc a
        jr z,.whole
        ld a,b
        or a
        jr z,.whole
        ld a,c
        sub b
        dec a
        jr z,.whole
        cp 4
        jr nc,.whole
        ld (tf_xl),a
        ld hl,tf_slot+3
        ld a,b
        call addhla
        ld de,tf_nm+8
        ld a,(tf_xl)
        ld c,a
        call .up
        ld c,b
        jr .nm
.whole: ld b,c
.nm:    ld hl,tf_slot+2
        ld de,tf_nm
; .up: C bytes HL -> DE, upper case.
.up:    ld a,c
        or a
        ret z
.u:     ld a,(hl)
        cp 'a'
        jr c,.u1
        cp 'z'+1
        jr nc,.u1
        and 0DFh
.u1:    ld (de),a
        inc hl
        inc de
        dec c
        jr nz,.u
        ret

; ---------------------------------------------------------------------
tskew:  db 0, 7, 14, 5, 12, 3, 10, 1, 8, 15, 6, 13, 4, 11, 2, 9
tf_e:   db 0
tf_buf: db 0
tf_i0:  db 0                    ; the file's first entry
tf_j:   db 0                    ; the entry of the part at hand
tf_a:   db 0                    ; the AU's place in it
tf_au:  db 0
tf_ta:  db 0
tf_tc:  db 0
tf_c:   db 0
tf_p:   db 0
tf_q:   db 0
tf_d:   db 0
tf_dn:  db 0                    ; the directory read: its entry ...
tf_d2:  db 0                    ; ... and id
tf_k:   db 0                    ; the directory entry at hand
tf_r:   db 0
tf_ej:  db 0
tf_nl:  db 0
tf_xl:  db 0
tf_n:   dw 0
tf_off: dw 0
tf_src: dw 0
tf_sz:  dw 0
tf_dst: dw 0
tf_ptr: dw 0
tf_pc:  ds 4, 0                 ; the last part found: mount, file, part, entry
tf_key: ds 12, 0                ; parent, name, extension
        db 0
tf_nm:  ds 11, 0                ; (tf_nm-1: a parent)
tf_slot: ds 10, 0
tf_map: ds 4*TMAPSZ, 0
