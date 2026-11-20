; =====================================================================
; ZX-UX platform: the Timex TC3256 started from disk (the boot menu's
; "4. Disk start": platform/tc3256.md) - its own screen and keyboard, a
; 64 KB all-RAM map (no ROM), the SCLD's display at 4000h, the FDD3000 its
; disk server.  The machine layer is tc3256/src (hal.asm and what it
; includes), in the low 16 KB.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; TC3256 port: LoadZX Museum.  Non-commercial use only: see ../../LICENSE.
; =====================================================================

HAL_HZ       equ 50             ; the SCLD's frame interrupt (PAL)
HAL_KMAX     equ 8192
NPROC        equ 6              ; processes (const.inc; 4 if a platform says none)
HAL_PTAB     equ 1              ; their table: proctab, in the layer (kvars.inc)           ; the kernel (KBASE..kend) at most
        include "memmap48.inc"  ; the memory map: the Spectrum's (the ABI's)
mem_swapout  equ wsave          ; a process window: copied to and from
mem_swapin   equ wload          ; its SAVE block in the arena (unix.asm)

; --- optional subsystems
HAL_BLKDEV   equ 1              ; /dev/fd0-3: the FDD3000's drives, through TOS (tosdisk.asm)
HAL_BLKVOL   equ 1              ; ZXFS volumes in a TOS file too (blkvol)
HAL_ROM48K   equ 0              ; no 48K ROM: programs built for it are refused
HAL_SEQDEV   equ 0              ; no cassette
        DEFINE HAL_DEVFILES "tty:1 mem:2 fd0:8 fd1:9 fd2:10 fd3:11 rd:12"  ; /dev (build.py)
HAL_VFS      equ 1              ; vfs.asm, fsmod.asm; ZXFS built in, modules
HAL_SSXFILE  equ 1              ; SSX1 programs from files
HAL_BOOTMNT  equ 1              ; init: HAL_SYSDEV on HAL_SYSMNT, its etc/rc
HAL_SCR4000  equ 1              ; the display file is at 4000h
HAL_SCREEN   equ 1              ; a screen: programs may draw
HAL_FONT8    equ font8          ; the 8x8 font (drivers/font8): ' ' first
KIY          equ 0              ; IY in the kernel: no ROM wants 5C3Ah here
SV_BORDCR    equ 05C48h         ; the border's colour, where the console and
                                ; programs keep it (the Spectrum's BORDCR)
        DEFINE HAL_LAYER "hal.asm"  ; the machine layer, assembled with the kernel
        DEFINE HAL_DRIVERS "rdsys.asm"  ; above 4000h: the RAM disk's system-mode part
        DEFINE HAL_SYSDEV "/dev/fd0"  ; the system disk: its ZXFS (a TOS file)
        DEFINE HAL_SYSMNT "/mnt/a"
        DEFINE HAL_FPMOD "/mnt/a/lib/fp"  ; the float engine (drivers/fp)

; --- hooks
        MACRO HAL_INIT
        call hinit              ; IM 1, the frame interrupt at 0038h (hal.asm)
        ENDM
        MACRO HAL_START
        ENDM
        MACRO HAL_IDLE
        halt                    ; the next frame interrupt
        ENDM
        MACRO HAL_ENTER
        ENDM
        MACRO HAL_LEAVE
        call vsync              ; changed mounted i-nodes to the disk.
        ENDM
        MACRO HAL_YIELD
        ENDM
        MACRO HAL_ZPOLL
        ENDM
        MACRO HAL_SSXFIX
        ENDM
        MACRO HAL_ITABALIGN
        ALIGN 2                 ; ITAB and the arena blocks are word aligned.
        ENDM
        MACRO HAL_BANNER
        db 10,"ZX-UX UNIX v1 / Timex TC3256 Z80 3.5MHz 64K",10
        db "Based on original work by Supratim Sanyal of SANYALnet Labs.",10
        db "TC3256 port: LoadZX Museum.",10
        ENDM
