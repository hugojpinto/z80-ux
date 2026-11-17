; =====================================================================
; ZX-UX on the Timex FDD3000: /etc/mount, /etc/umount.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;   mount /dev/fdN dir      the disk's file system on dir (sys mount)
;   umount /dev/fdN         ... and off it again (sys umount)
;  (They live in the hardware layer's spare room; /etc/mkfs, t_mkfs.asm,
;  in the kernel image.)
; =====================================================================

; ------------------------------------------------------------- mount
t_mount: db 18h,6
        dw STKRES, TV-UDATA, mount_m
mount_m: pop hl
        call args
        ld a,(U_ARGC)
        cp 3
        ld hl,s_mntu
        jp nz,usage
        ld a,2
        call argn
        ex de,hl
        ld a,1
        call argn
        push hl
        SC _mount
        pop hl
        jp nc,exit0
.err:   call ferr
        ld hl,1
        jp exitc
s_mntu: db "mount /dev/fdN dir",0
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
        jr mount_m.err
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
.f5:     jp perr
s_eio:  db "I/O error",0
s_ebusy: db "busy",0
s_enotblk: db "not a disk",0
s_einval: db "no file system / not mounted",0
s_enoent: db "not found",0
s_enotdir: db "not a directory",0

