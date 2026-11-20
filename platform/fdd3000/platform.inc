; =====================================================================
; ZX-UX platform: the Timex FDD3000 disk unit, its own Z80 and 64K, a
; Timex computer as a VT52 terminal on the link.  The machine layer is
; fdd3000/src (hal.asm and what it includes), at 1800h.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../../LICENSE.
; =====================================================================

HAL_HZ       equ 50             ; ticks a second (the WD1770 clock, the soft clock)
HAL_KMAX     equ 8192           ; the kernel (KBASE..kend) at most
        include "memmap48.inc"  ; the memory map: the Spectrum's above 5B00h
                                ; (IM 1: FFF4h-FFFFh, above HAL_TOP, unused)
KIY          equ 0              ; IY in the kernel: no ROM wants 5C3Ah here
mem_swapout  equ wsave          ; a process window: copied to and from
mem_swapin   equ wload          ; its SAVE block in the arena (unix.asm)

; --- optional subsystems
HAL_BLKDEV   equ 1              ; /dev/fd0-3 (fd.asm)
HAL_SEQDEV   equ 0              ; sequential devices: none (no cassette)
        DEFINE HAL_DEVFILES "tty:1 mem:2 fd0:8 fd1:9 fd2:10 fd3:11"  ; /dev (build.py)
HAL_VFS      equ 1              ; vfs.asm, fsmod.asm; ZXFS built in, modules
HAL_SSXFILE  equ 1              ; ssx.asm, /etc/ldx's file part
HAL_BOOTMNT  equ 1              ; init: HAL_SYSDEV on HAL_SYSMNT, its etc/rc
HAL_SCR4000  equ 0
HAL_SCREEN   equ 0              ; no screen: a terminal - programs that draw are refused              ; 4000h-5AFFh holds resident programs: an SSX1
                                ; program that cannot move its display file
                                ; (upstream's: no kind declared; the fixed
                                ; kind) is refused.  rcc --ux bitmap programs
                                ; ask call 41 where it is.
        DEFINE HAL_LAYER "hal.asm"  ; the machine layer, assembled with the kernel
        DEFINE HAL_SYSDEV "/dev/fd0"
        DEFINE HAL_SYSMNT "/mnt/a"
        DEFINE HAL_FPMOD "/mnt/a/lib/fp"  ; the float engine (drivers/fp)

; --- hooks
        MACRO HAL_INIT
        call hinit              ; restart vectors, IM 1, drives idle (hal.asm).
        ENDM
        MACRO HAL_START
        call tinit              ; the 50 Hz clock from the WD1770 (tmr.asm).
        ENDM
        MACRO HAL_IDLE
        call kidle              ; no clock interrupt: poll the terminal, count the time.
        ENDM
        MACRO HAL_ENTER
        call kpoll              ; keys, BREAK and the clock come in through the door.
        ENDM
        MACRO HAL_LEAVE
        call vsync              ; changed mounted i-nodes to the disk.
        ENDM
        MACRO HAL_YIELD
        ENDM                    ; (nothing to show: no screen)
        MACRO HAL_ZPOLL
        call hzpoll             ; no interrupt brings keys or ticks: fetch them.
        ENDM
        MACRO HAL_SSXFIX
        call ssxfix             ; no OUT (FEh): the drive latch (ssx.asm).
        ENDM
        MACRO HAL_ITABALIGN
        ALIGN 2                 ; ITAB and the arena blocks are word aligned.
        ENDM
        MACRO HAL_BANNER
        db 10,"ZX-UX UNIX v1 / Timex FDD3000 Z80 4MHz 64K",10
        db "Based on original work by Supratim Sanyal of SANYALnet Labs.",10
        db "FDD3000 port: LoadZX Museum.",10
        ENDM
