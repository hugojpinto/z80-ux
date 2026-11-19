; =====================================================================
; ZX-UX platform: the 48K ZX Spectrum - ZX-UX as Supratim Sanyal ships it.
; Included first by unix.asm (platform/README.md: the contract).  With
; these settings the kernel assembles byte for byte as the shipped
; ZX-UX.tzx (fdd3000/tools/build.py spectrum checks it).
; =====================================================================

CON_SCREEN   equ 1              ; the kernel draws its console (64 x 24)
CON_TERMINAL equ 2              ; the machine layer's terminal is the console

; --- the machine
HAL_ROM      equ 1              ; the Spectrum ROM is in: keyboard, BEEP, tape, RST 8
HAL_FRAMEIRQ equ 1              ; 50 Hz frame interrupt, IM 2 through FFF4h (isr)
HAL_ULAFE    equ 1              ; OUT (FEh) is the ULA: border, beeper, key click
HAL_TAPE     equ 1              ; the cassette: /dev/tap, /dev/cassette, SSX1 from tape
HAL_CONSOLE  equ CON_SCREEN

HAL_HZ       equ 50             ; frame interrupts a second (ULA, PAL)

; --- optional subsystems
HAL_BLKDEV   equ 0              ; disk block devices
HAL_VFS      equ 0              ; mounts and file system types (21, 22)
HAL_SSXFILE  equ 0              ; SSX1 programs from files
HAL_BOOTMNT  equ 0              ; init mounts a system volume, runs its rc

;       (HAL_LAYER, a DEFINE: a machine layer's source, assembled after the
;       kernel image - none here: the ROM is the Spectrum's machine layer)

; --- hooks: what the kernel does at these points on this machine
        MACRO HAL_INIT          ; boot: before the clock starts (vectors, IM)
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
