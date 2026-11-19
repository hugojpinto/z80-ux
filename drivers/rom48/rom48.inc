; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================

; =====================================================================
;  rom48: the 48 BASIC ROM's entry points and system variables, for the
;  platforms whose 0000h-3FFFh holds it (the 48K; the 128K's ROM1, the
;  +2A/+3's ROM3, the TC3256's BASIC page: platform/hardware-notes.md).
;  (Moved here from const.inc: the kernel names no ROM address.)
; =====================================================================
IM2I    equ 039h            ; The interrupt register points into ROM FFh bytes. Handy detour.
ROM_KEYBOARD  equ 002BFh
ROM_KEYINPUT  equ 010A8h
ROM_CHANOPEN  equ 01601h
ROM_CLS       equ 00D6Bh
ROM_BEEPER    equ 003B5h
ROM_BREAKKEY  equ 01F54h
ROM_SABYTES   equ 004C2h
ROM_LDBYTES   equ 00556h
ROM_CHARSET   equ 03D00h
SV_KSTATE equ 05C00h
SV_LASTK  equ 05C08h
SV_FLAGS  equ 05C3Bh
SV_TVFLAG equ 05C3Ch
SV_ERRSP  equ 05C3Dh
SV_MODE   equ 05C41h
SV_BORDCR equ 05C48h
SV_FLAGS2 equ 05C6Ah
SV_DFSZ   equ 05C6Bh
SV_FRAMES equ 05C78h
SV_SPOSN  equ 05C88h
SV_SCRCT  equ 05C8Ch
SV_ATTRP  equ 05C8Dh
SV_ATTRT  equ 05C8Fh
SV_CHANS  equ 05C4Fh
