; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; zx-ux+: the 48K Spectrum's memory map (const.inc's comment draws it),
; included by platform.inc.  A platform with another map sets these
; itself - all of them - keeping 6003h and 5BE4h (unix.asm asserts).

KBASE   equ 06000h
HAL_TOP equ 0FFF4h          ; the kernel's top; above: the machine's (48K: the IM 2 detour)
WINDOW  equ 0F000h          ; Resident process images live here. Space is borrowed, not free.
KV      equ 05B00h          ; The kernel uses the printer buffer. Sorry, printer.
KSTACK  equ 05F00h          ; Kernel stack top. It only grows toward trouble.
TTYBUF  equ 05F01h          ; 80 bytes for a line. No rambling allowed.
KARGS   equ 05F62h          ; 158 bytes for command arguments. Short speeches, please.
MEMBOT  equ 05C92h          ; 30 calculator bytes on loan as scratch. Keep BEEP out of the first five.
