; =====================================================================
; ZX-UX on the Timex FDD3000: /etc/mount, /etc/umount.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; Adapted by Hugo Pinto of the LoadZX Museum.  MIT licence: see ../../LICENSE.
; =====================================================================
;
;   mount [-t type] /dev/fdN dir
;                           the disk's file system on dir (sys mount);
;                           without -t, whichever type in the type table
;                           it is; with -t, that type - a name in the
;                           table, else the module /mnt/a/etc/fs/TYPE, or
;                           a module's path (fsmod.asm)
;   umount /dev/fdN         ... and off it again (sys umount)
;  (In the kernel image, with /etc/mkfs, t_mkfs.asm.)
; =====================================================================

MT_T    equ TV                  ; the type (0: any)
MT_I    equ TV+2                ; argv index of the disk

; ------------------------------------------------------------- mount
t_mount: db 18h,6
        dw STKRES, TV+3-UDATA, mount_m
mount_m: pop hl
        call args
        ld a,(U_ARGC)
        cp 3
        ld a,1
        jr z,.go
        ld a,(U_ARGC)
        cp 5
        jp nz,.use
        ld a,1                  ; -t type
        call argn
        ld a,(hl)
        cp '-'
        jp nz,.use
        inc hl
        ld a,(hl)
        cp 't'
        jp nz,.use
        ld a,2
        call argn
        ld (MT_T),hl
        ld a,3
.go:    ld (MT_I),a
.try:   inc a
        call argn
        ex de,hl
        ld a,(MT_I)
        call argn
        ld bc,(MT_T)
        push hl
        SC _mount
        pop hl
        jp nc,exit0
        cp ENODEV               ; a type not in the table: its module
        jr nz,.err
        ld hl,s_fsdir
        ld de,R_BUF
        call strcpy
        ld hl,(MT_T)
        call strcpy
        ld hl,R_BUF
        ld (MT_T),hl
        ld a,(MT_I)
        jr .try
.err:   cp ENOEXEC              ; the module's fault ...
        jr z,.mod
        cp ENOENT               ; ... or, not found: the first of the
        jr nz,.e                ; module, the disk, the directory that
        ld de,(MT_T)            ; is not there
        ld a,d
        or e
        jr z,.nod
.sl:    ld a,(de)               ; (a type with a / is a module's path)
        inc de
        or a
        jr z,.nod
        cp '/'
        jr nz,.sl
        ld hl,(MT_T)
        call .there
        jr c,.mod
.nod:   ld a,(MT_I)
        call argn
        call .there
        jr c,.e0
        ld a,(MT_I)
        inc a
        call argn
.e0:    ld a,ENOENT
        jr .e
.mod:   ld hl,(MT_T)
        jr .e
; .there: CF if there is no file HL.  Keeps HL.
.there: push hl
        ld de,U_STB
        call sc_stat
        pop hl
        ret
.e:     call ferr
        ld hl,1
        jp exitc
.use:   ld hl,s_mntu
        jp usage
s_mntu: db "mount [-t type] /dev/fdN dir",0
s_fsdir: db "/mnt/a/etc/fs/",0
e_mount:

; ------------------------------------------------------------- umount
t_umount: db 18h,6
        dw STKRES, TV-UDATA, umount_m
umount_m: pop hl
        call args
        ld a,(U_ARGC)
        cp 2
        ld hl,s_umnu
        jp nz,usage
        ld a,1
        call argn
        push hl
        SC _umount
        pop hl
        jp nc,exit0
        jr mount_m.e
s_umnu: db "umount /dev/fdN",0
e_umount:

; ferr: "name: what went wrong" for error A, on fd 2.
ferr:   ld de,s_eio
        cp EBUSY
        jr nz,.f1
        ld de,s_ebusy
.f1:     cp ENOTBLK
        jr nz,.f2
        ld de,s_enotblk
.f2:     cp EINVAL
        jr nz,.f3
        ld de,s_einval
.f3:     cp ENOENT
        jr nz,.f4
        ld de,s_enoent
.f4:     cp ENOTDIR
        jr nz,.f5
        ld de,s_enotdir
.f5:     cp ENOEXEC
        jr nz,.f6
        ld de,s_enoexec
.f6:     cp ENODEV
        jr nz,.f7
        ld de,s_enodev
.f7:     cp ENFILE
        jr nz,.f8
        ld de,s_enfile
.f8:     cp ENOMEM
        jr nz,.f9
        ld de,s_enomem
.f9:     jp perr
s_eio:  db "I/O error",0
s_ebusy: db "busy",0
s_enotblk: db "not a disk",0
s_einval: db "no file system / not mounted",0
s_enoent: db "not found",0
s_enotdir: db "not a directory",0
s_enoexec: db "not a file system module for this kernel",0
s_enodev: db "no such file system type",0
s_enfile: db "too many file system types",0
s_enomem: db "out of memory",0

