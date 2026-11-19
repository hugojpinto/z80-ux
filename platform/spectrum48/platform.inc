; =====================================================================
; ZX-UX platform: the 48K ZX Spectrum - ZX-UX as Supratim Sanyal ships it.
; Included first by unix.asm (platform/README.md: the contract).  With
; these settings the kernel assembles byte for byte as the shipped
; ZX-UX.tzx (fdd3000/tools/build.py spectrum checks it).
; =====================================================================

        include "rom48.inc"     ; the 48 BASIC ROM's addresses (drivers/rom48)
        DEFINE HAL_DRIVERS "drivers.asm"  ; rom48, screen64, the frame ISR

HAL_HZ       equ 50             ; frame interrupts a second (ULA, PAL)
HAL_KMAX     equ 8192           ; the kernel (KBASE..kend) at most

; --- optional subsystems
HAL_BLKDEV   equ 0              ; disk block devices
HAL_VFS      equ 0              ; mounts and file system types (21, 22)
HAL_SSXFILE  equ 0              ; SSX1 programs from files
HAL_BOOTMNT  equ 0              ; init mounts a system volume, runs its rc

;       (HAL_DRIVERS: the platform's drivers, assembled right after the
;       kernel's 8K; HAL_LAYER: a machine layer at its own address)

; --- hooks: what the kernel does at these points on this machine
        MACRO HAL_INIT          ; boot: before the clock starts (vectors, IM)
        call sp_init            ; IM 2, the ROM error trap, L mode (machine.asm)
        ENDM
        MACRO HAL_START         ; boot: start the clock, if the machine layer has one
        ENDM
        MACRO HAL_IDLE          ; the scheduler has nothing to run: wait a tick
        halt
        ENDM
        MACRO HAL_ENTER         ; a system call comes in (kernel mode)
        ENDM
        MACRO HAL_LEAVE         ; a system call goes out
        ENDM
        MACRO HAL_YIELD         ; sys rele: the process gives up the CPU
        ENDM
        MACRO HAL_ZPOLL         ; the packer's checkpoint (long kernel work)
        ENDM
        MACRO HAL_SSXFIX        ; an SSX1 image was relocated: make it safe here
        ENDM
        MACRO HAL_ITABALIGN     ; before ITAB (the root file system)
        ENDM
        MACRO HAL_BANNER        ; the boot banner's first lines
        db 10,"ZX-UX UNIX v1 48K ZX Spectrum Z80 3.5Mhz",10
        db 127," 2026 SANYALnet Labs",10
        ENDM
