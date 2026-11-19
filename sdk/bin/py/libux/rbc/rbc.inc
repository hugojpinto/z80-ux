; =====================================================================
; ZX-UX 48K Sinclair ZX Spectrum Unix.
; Copyright (c) 2026 Supratim Sanyal of SANYALnet Labs.
; Non-commercial use only under the repository LICENSE.
; Commercial use prohibited without separate written permission.
; =====================================================================
; rbc --ux: the names libux/rbc/*.asm share (libux/build.py puts this
; before each of them).
;
; The system variables: @rsv + their offset in the Spectrum's layout
; (5C00h + n there), so that the compiled program's own references and
; ours agree; IY = @rsv + ERRNR.
KSTATE  equ @rsv+00h
TVDATA  equ @rsv+0Eh
STRMS   equ @rsv+10h
CHARS   equ @rsv+36h
ERRNR   equ @rsv+3Ah
FLAGS   equ @rsv+3Bh
TVFLAG  equ @rsv+3Ch
ERRSP   equ @rsv+3Dh
BORDCR  equ @rsv+48h
CURCHL  equ @rsv+51h
KCUR    equ @rsv+5Bh
CHADD   equ @rsv+5Dh
XPTR    equ @rsv+5Fh
WORKSP  equ @rsv+61h
STKBOT  equ @rsv+63h
STKEND  equ @rsv+65h
MEMV    equ @rsv+68h
FLAGS2  equ @rsv+6Ah
DFSZ    equ @rsv+6Bh
SEED    equ @rsv+76h
FRAMES  equ @rsv+78h
UDG     equ @rsv+7Bh
COORDS  equ @rsv+7Dh
DFCC    equ @rsv+84h
DFCCL   equ @rsv+86h
SPOSN   equ @rsv+88h
SPOSNL  equ @rsv+8Ah
SCRCT   equ @rsv+8Ch
ATTRP   equ @rsv+8Dh
MASKP   equ @rsv+8Eh
ATTRT   equ @rsv+8Fh
MASKT   equ @rsv+90h
PFLAG   equ @rsv+91h
MEMBOT  equ @rsv+92h
TVF_LOW equ 0                   ; TV_FLAG bit 0: printing in the lower screen
FL_PR   equ 1                   ; FLAGS bit 1: printing on the printer
FL_SP   equ 0                   ; FLAGS bit 0: the last character was a space

; The reports, as RST 8's byte (the report's number less one)
R_VAR   equ 01h                 ; 2 Variable not found
R_OOM   equ 03h                 ; 4 Out of memory
R_SCR   equ 04h                 ; 5 Out of screen
R_BIG   equ 05h                 ; 6 Number too big
R_ARG   equ 09h                 ; A Invalid argument
R_RANGE equ 0Ah                 ; B Integer out of range
R_NONS  equ 0Bh                 ; C Nonsense in BASIC
R_COL   equ 13h                 ; K Invalid colour

; The screen
LINES   equ 24                  ; character lines
COLS    equ 32                  ; character columns
CCOL    equ COLS+1              ; S_POSN's column counter at column 0
CLINE   equ LINES               ; S_POSN's line counter at line 0
LOWER   equ 2                   ; the lower screen's lines (DF_SZ), at CLS
ATTRS   equ 1800h               ; the attributes, past the pixels
CELL    equ 8                   ; pixel rows in a character

; The control codes PRINT knows
C_COMMA equ 06h
C_BACK  equ 08h
C_RIGHT equ 09h
C_ENTER equ 0Dh
C_INK   equ 10h                 ; ... PAPER FLASH BRIGHT INVERSE OVER: 11h-15h
C_OVER  equ 15h
C_AT    equ 16h
C_TAB   equ 17h
C_GRAPH equ 80h                 ; block graphics, 80h-8Fh
C_UDG   equ 90h                 ; user-defined graphics, 90h-A4h
C_TOKEN equ 0A5h                ; keywords, A5h-FFh
C_TOKFN equ 0A8h                ; from here, functions take a trailing space
C_TOKST equ 0C5h                ; from here (statements, operators), a leading one

; The streams and their channels
S_KEY   equ 0FDh                ; stream -3: 'K', the lower screen
S_SCR   equ 0FEh                ; stream -2: 'S', the upper screen
S_PRN   equ 3                   ; 'P', the printer
CH_LET  equ 4                   ; a channel's letter, after its two addresses

; The float engine's operations (platform/float.md)
F_ADD   equ 1
F_SUB   equ 2
F_MUL   equ 3
F_DIV   equ 4
F_POW   equ 5
F_ABS   equ 6
F_NEG   equ 7
F_TRUNC equ 8
F_EXP   equ 9
F_LN    equ 10
F_SIN   equ 11
F_COS   equ 12
F_ATN   equ 16
F_SQR   equ 17
FNUM    equ 5                   ; bytes in a number

SYS     equ 6003h               ; the kernel's system calls
SYS_FP  equ 42                  ; the float engine's address
SYS_SCR equ 41                  ; the screen, described

; The five-byte number: an exponent byte (bias N_BIAS; 0: a small integer:
; 0, a sign byte, the value, 0), then the mantissa with the sign in bit 7
N_BIAS  equ 80h
N_SIGN  equ 80h
N_INT16 equ N_BIAS+16           ; the exponent of a 16-bit whole number
ROOM    equ 80                  ; bytes kept free above the stack's top (the ROM's)

; The calculator's operations RST 28h is asked for (its literals)
K_DEL   equ 02h                 ; delete
K_SUB   equ 03h
K_MUL   equ 04h
K_CMP   equ 09h                 ; 09h-0Eh: compare, the comparison in B:
K_CMPN  equ 6                   ;   <= >= <> > < =
K_ADD   equ 0Fh
K_ATN   equ 24h
K_DUP   equ 31h                 ; duplicate
K_MOD   equ 32h                 ; n-mod-m
K_DATA  equ 34h                 ; stk-data
K_END   equ 38h                 ; end-calc
K_ONE   equ 0A1h                ; stk-one
K_PI2   equ 0A3h                ; stk-pi/2
K_DLEN  equ 0C0h                ; stk-data's first byte: mantissa bytes - 1,
K_DEXP  equ 3Fh                 ; and the exponent (0: in the next byte),
K_DBIAS equ 50h                 ; less this
CMP_Z   equ 1                   ; the comparisons' truth: x - y zero,
CMP_N   equ 2                   ; negative,
CMP_P   equ 4                   ; positive

; The attribute byte; P_FLAG's bits (even: temporary, odd: permanent)
A_INK   equ 07h
A_PAPER equ 38h
A_BRT   equ 40h
A_FLASH equ 80h
A_LIGHT equ 04h                 ; a colour's bit that makes it light
PF_OVER equ 0                   ; bits
PF_INV  equ 2
PF_INK9 equ 4
PF_PAP9 equ 6
PF_TEMP equ 55h                 ; masks
PF_PERM equ 0AAh
FL_KEY  equ 5                   ; FLAGS bit 5: a new key
FL2_K   equ 4                   ; FLAGS2 bit 4: channel K in use
TVF_ED  equ 5                   ; TV_FLAG bit 5: the lower screen to be cleared
SCR_SPEC equ 40h                ; the display file's page on a kernel without call 41
L_THIRD equ 18h                 ; a line's bits that pick a third of the screen
L_ROW   equ 07h                 ; ... and its line within the third
A_INKL  equ 2                   ; the ink's light bit
A_PAPL  equ 5                   ; the paper's light bit
COL_TR  equ 8                   ; a colour: transparent
COL_CON equ 9                   ; ... in contrast
COL_MAX equ 10                  ; (beyond: K Invalid colour)
S_MAIN  equ 2                   ; stream 2: the upper screen
FL2_CLS equ 0                   ; FLAGS2 bit 0: the screen to be cleared
GR_R    equ 0Fh                 ; a block graphic's right half of a byte
GR_L    equ 0F0h                ; ... and its left
ROTATE  equ 0FFh                ; @rascr: rotate rather than fill

; The pointers that move with the memory below them (VARS .. STKEND)
VARS    equ @rsv+4Bh
NPTRS   equ (STKEND-VARS)/2+1

; Strings
V_VAL   equ 1Dh                 ; VAL (B, for the ROM's val entry; 18h: VAL$)
UDG_N   equ 21                  ; user-defined graphics: 'A' .. 'U'
FSTRMAX equ 14                  ; the longest number @fstr writes
FL_NUM  equ 6                   ; FLAGS bit 6: the result is a number (0: a string)
VALMAX  equ 40                  ; the longest text VAL reads, its spaces left out

; The terminal (the kernel's ABI: call 3 read, 31 stty, 32 gtty; the mode
; byte, its fifth)
SYS_READ equ 3
SYS_STTY equ 31
SYS_GTTY equ 32
TTMODE  equ 4
TT_RAW  equ 20h
TT_NOWAIT equ 40h
KSTATE4 equ KSTATE+4            ; the second key's state
FL2_CAPS equ 3                  ; FLAGS2 bit 3: CAPS LOCK
