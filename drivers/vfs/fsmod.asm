; =====================================================================
; ZX-UX on the Timex FDD3000: file system types, built in and loaded.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  The type table (fstab) holds up to NFST file system types: a name and
;  the vector of its operations (vfs.asm FO_*).  ZXFS is built in (type
;  1, zfs.asm).  Any other type is a module, a file loaded when a mount
;  asks for it and unloaded when its last mount goes - so the hardware
;  layer carries one format and the disks carry the rest:
;
;    sys mount (21), BC = 0       the types in the table are tried in turn
;                    BC = "name"  that type, which must be in the table
;                    BC = "/path" the module in that file: loaded, unless
;                                 a type of its name is in the table already
;  (/etc/mount -t NAME tries NAME, then /mnt/a/etc/fs/NAME.)
;
;  A module (fdd3000/tools/fsmod.py makes them):
;      0  "ZXFM"           4  ABI.w           6  image length.w
;      8  relocations.w   10  name (8 bytes, 0-padded)
;     18  the image: its vector of operations first, then its code and
;         data, assembled at 0000h
;   then  the relocations: one word each, the offset in the image of a
;         word that holds an address in the image (so: + where it landed)
;  The image lands in an arena block of its own kind (K_FSM), which, like
;  a loaded SSX1 image, compaction does not move.  It calls the kernel by
;  address - the symbols of fdd3000/tools/build.py's ABI list - so it only
;  runs with the kernel it was built against: ABI is a checksum of those
;  symbols and their values (KABI), and a module whose ABI is not this
;  kernel's is refused (ENOEXEC).
; =====================================================================

NFST    equ 5                   ; types in the table at once: ZXFS and one
                                ; a mount (NMOUNT), at most
FTSZ    equ 16
FT_OPS  equ 0                   ; the vector of operations (0: a free entry)
FT_BLK  equ 2                   ; a module: its arena block (0: built in)
FT_REF  equ 4                   ; mounts of this type
FT_NAME equ 5                   ; 8 bytes, 0-padded

K_FSM   equ 6                   ; arena kind: a loaded module (fixed)
ENODEV  equ 19                  ; no such file system type

FMHSZ   equ 18                  ; a module's header
FM_ABI  equ 4
FM_LEN  equ 6
FM_NREL equ 8
FM_NAME equ 10

        IFNDEF KABI
        DEFINE KABI 0           ; (build.py: the second pass sets it)
        ENDIF
kabi    equ KABI

; vfst: type A (1 - NFST) -> HL = its entry in the type table.  Keeps BC, DE.
vfst:   dec a
        add a,a
        add a,a
        add a,a
        add a,a
        ld hl,fstab
        jp addhla

; vtype: sys mount's type, string HL -> A = the type; CF, A.
vtype:  push hl
.s:     ld a,(hl)
        inc hl
        cp '/'
        jr z,.path
        or a
        jr nz,.s
        pop hl                  ; a name: one in the table
        call vbyname
        ret nc
        ld a,ENODEV
        ret
.path:  pop hl                  ; a path: a module
; fmload: the module in file HL -> A = its type; CF, A.
fmload: call mhdr
        ret c
        ld hl,fmhdr+FM_NAME     ; loaded already?
        call vbyname
        ret nc
        ld b,1                  ; a free entry
.f:     ld a,b
        call vfst
        ld a,(hl)
        inc hl
        or (hl)
        dec hl
        jr z,.got
        inc b
        ld a,b
        cp NFST+1
        jr c,.f
        ld a,ENFILE
        scf
        ret
.got:   ld (vfte),hl
        ld a,b
        ld (vftn),a
        ld a,FT_NAME            ; its name (FT_OPS stays 0 till it runs)
        call addhla
        ex de,hl
        ld hl,fmhdr+FM_NAME
        ld bc,8
        ldir
        ld a,K_FSM
        call mimg
        ret c
        ex de,hl                ; in the table: its vector is its start
        ld hl,(vfte)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d               ; (FT_REF: 0 in a free entry)
        ld a,(vftn)
        or a
        ret

; mhdr: module file HL: its header into fmhdr, IX = its i-node; CF, A
; (ENOEXEC: no module, or one built for another kernel).
mhdr:   call nami
        ret c
        ld hl,0                 ; the header (a directory: no "ZXFM")
        ld de,fmhdr
        ld bc,FMHSZ
        call fmrd
        jp c,.nox
        ld hl,fmhdr             ; "ZXFM", this kernel's ABI
        ld de,s_zxfm
        ld b,4
.c:     ld a,(de)
        cp (hl)
        jp nz,.nox
        inc hl
        inc de
        djnz .c
        ld hl,(fmhdr+FM_ABI)
        ld de,kabi
        call cphlde
        jp nz,.nox
        or a
        ret
.nox:   ld a,ENOEXEC
        scf
        ret

; mimg: the module whose header is in fmhdr (file IX): its image in a
; fixed arena block of kind A, relocated -> HL = the block; CF, A.
mimg:   ld bc,(fmhdr+FM_LEN)    ; a fixed block for the image
        ld (vmlen),bc
        push ix
        call aalloc
        pop ix
        ret c
        ld (vmblk),hl
        ld bc,(fmhdr+FM_LEN)    ; not in a window lent to a big program:
        add hl,bc               ; it would never be given back
        ld de,WINDOW+1
        call cphlde
        ld a,ENOMEM
        jp nc,.err
        ld hl,FMHSZ             ; the image
        ld de,(vmblk)
        ld bc,(fmhdr+FM_LEN)
        call fmrd
        jp c,.eio
        ld hl,(fmhdr+FM_LEN)    ; the relocations follow it
        ld de,FMHSZ
        add hl,de
        ld (vmoff),hl
        ld hl,(fmhdr+FM_NREL)
        ld (vmn),hl
.r:     ld hl,(vmn)             ; up to 8 at a time, through fmhdr
        ld a,h
        or a
        jr nz,.r8
        ld a,l
        or a
        jr z,.done
        cp 8
        jr c,.rn
.r8:    ld a,8
.rn:    ld (vmk),a
        ld hl,(vmn)
        ld e,a
        ld d,0
        or a
        sbc hl,de
        ld (vmn),hl
        ex de,hl
        add hl,hl
        ld b,h
        ld c,l
        ld hl,(vmoff)
        push hl
        add hl,bc
        ld (vmoff),hl
        pop hl
        ld de,fmhdr
        call fmrd
        jp c,.eio
        ld hl,fmhdr
.w:     ld e,(hl)               ; a word at offset DE of the image ...
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,(vmlen)           ; (inside it)
        dec hl
        call cphlde
        jr c,.bad
        jr z,.bad
        ld hl,(vmblk)
        add hl,de
        ld c,(hl)               ; ... gets where the image is added
        inc hl
        ld b,(hl)
        ex de,hl
        ld hl,(vmblk)
        add hl,bc
        ex de,hl
        ld (hl),d
        dec hl
        ld (hl),e
        pop hl
        ld a,(vmk)
        dec a
        ld (vmk),a
        jr nz,.w
        jr .r
.bad:   pop hl
.nox2:  ld a,ENOEXEC
        jp .err
.done:  ld hl,(vmblk)
        or a
        ret
.eio:   ld a,EIO
.err:   push af
        ld hl,(vmblk)
        call afree
        pop af
        scf
        ret
; fmrd: BC bytes of the file IX from offset HL to DE, all of them; CF if not.
fmrd:    push bc
        push ix
        xor a
        call iio
        pop ix
        pop de
        ret c
        ld hl,(u_nread)
        call cphlde
        ret z
        scf
        ret

; vbyname: name HL (0-ended, or 8 long) -> A = its type in the table; CF
; if none.  Keeps HL.
vbyname:
        ex de,hl
        ld b,1
.l:     ld a,b
        call vfst
        ld a,(hl)
        inc hl
        or (hl)
        jr z,.n
        ld a,FT_NAME-1
        call addhla
        push de
        ld c,8
.c:     ld a,(de)
        cp (hl)
        jr nz,.ne
        or a
        jr z,.eq
        inc hl
        inc de
        dec c
        jr nz,.c
        ld a,(de)               ; 8 alike: the name must end there
        or a                    ; (fmhdr's 0 after a header's name)
        jr z,.eq
.ne:    pop de
.n:     inc b
        ld a,b
        cp NFST+1
        jr c,.l
        ex de,hl
        scf
        ret
.eq:    pop de
        ex de,hl
        ld a,b
        or a
        ret

; vgc: the loaded types no mount uses go: their blocks back to the arena.
; Keeps AF.
vgc:    push af
        ld b,NFST
        ld hl,fstab
.l:     push hl
        inc hl
        inc hl
        ld e,(hl)               ; FT_BLK
        inc hl
        ld d,(hl)
        inc hl
        ld a,d
        or e
        jr z,.n                 ; built in, or free
        ld a,(hl)               ; FT_REF
        or a
        jr nz,.n
        pop hl
        push hl
        xor a                   ; the entry is free ...
        ld c,5
.z:     ld (hl),a
        inc hl
        dec c
        jr nz,.z
        ex de,hl                ; ... and the block
        push bc
        call afree
        pop bc
.n:     pop hl
        ld de,FTSZ
        add hl,de
        djnz .l
        pop af
        ret

s_zxfm: db "ZXFM"
vfte:   dw 0
vftn:   db 0
vmblk:  dw 0
vmoff:  dw 0
vmn:    dw 0
vmk:    db 0
vmlen:  dw 0
fmhdr:  ds FMHSZ+1, 0           ; (+1: a 0 after the name; 16-byte reads
                                ;  of relocations never reach it)
fstab:  dw zfsops, 0            ; 1: ZXFS, built in (zfs.asm)
        db 0, "zxfs", 0, 0, 0, 0, 0, 0, 0
        ds (NFST-1)*FTSZ, 0
