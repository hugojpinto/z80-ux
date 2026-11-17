; =====================================================================
; ZX-UX on the Timex FDD3000: the hardware layer.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
; ZX-UX runs on the FDD3000's own Z80 (4 MHz, 64K RAM), the way TOS and
; the FDD3000's CP/M do: the Timex computer on the other end of the link
; (TC3256, TT3000 or TC2068 running the Terminal 3000 software) is only
; the screen and keyboard, a VT52 terminal.
;
; The 48K Spectrum gave ZX-UX three things the FDD3000 has not got:
;  - a 50 Hz frame interrupt.  The FDD3000's only interrupt is the
;    WD1770's INTRQ (the schematic: /INT comes from the PAL16L8 IC9,
;    whose one interrupt input is the FDC's IRQ).  So the clock is
;    counted in software (kpoll at every system call, kidle when nothing
;    can run) and preemption happens at system calls;
;  - a keyboard and a display file: the console is the terminal, over
;    port 2Fh, in the CBIOS A1.1 nibble protocol;
;  - the 16K ROM: the kernel no longer calls it (cassette, BEEP and the
;    ROM keyboard routines are gone from the FDD3000 build).
; Careful: port FEh, the Spectrum's ULA, is the FDD3000's drive latch
; (E0h-FFh decode to it).  No border colours, no BEEP.
;
; This file is included at the end of unix.asm (IFDEF FDD3000) and lives
; in RAM that was the Spectrum's ROM, HALBASE up to the boot sector's
; 3F00h.  Not in the old display file (4000h-5AFFh): SDK programs still
; draw into it (they clear "the screen" with LDIR), so it is left them as
; scratch - the boot sector does not even load it.
; =====================================================================

HALBASE equ 01800h              ; after the vectors, the ROM traps, the buffers

LINK    equ 02Fh                ; the terminal link; bit 7 in: FDC DRQ.
FDCST   equ 0C0h                ; WD1770 status / command.
LATCH   equ 0E0h                ; drive latch (write only).
LATIDLE equ 0DFh                ; drives off, side 0, MFM, boot ROM out, light off.

; The soft clock counts in units of 16 T-states.  At 4 MHz a 50 Hz tick
; is 80000 T = 5000 units.  The costs below are estimates of the time
; that passes between two calls; they are what the clock knows of time.
FDDHZ   equ 4000000
TICK    equ FDDHZ/50/16
SYSCOST equ 40                  ; a system call (640 T).
CHRCOST equ 35                  ; a character over the link (560 T).
ZCOST   equ 18100/16            ; swtch's look round and zidle's scan for a file to pack.
ZPCOST  equ 12400/16            ; between two zpoll calls of the packer (measured).
IDLEDLY equ 150                 ; kidle's wait: 150 x 13 T ...
IDLECOST equ (IDLEDLY*13+170)/16 ; ... plus the key poll and the count.

        org HALBASE
halstart:

; ---------------------------------------------------------------------
; hinit: called once by the kernel's boot.  The boot sector paged the
; FDD3000 boot ROM out (latch bit 6), so 0000h-07FFh is RAM: write the
; restart vectors there.  RST 0-30h are traps (no Spectrum ROM to call);
; RST 38h is the FDC's INTRQ (IM 1); 66h the NMI.
; ---------------------------------------------------------------------
hinit:  ld hl,0
        xor a
.v:     ld (hl),0F3h            ; di
        inc hl
        ld (hl),03Eh            ; ld a,n
        inc hl
        ld (hl),a
        inc hl
        ld (hl),0C3h            ; jp htrap
        inc hl
        ld (hl),low htrap
        inc hl
        ld (hl),high htrap
        inc hl
        inc hl
        inc hl
        add a,8
        cp 38h
        jr c,.v
        ld (hl),0C3h            ; 0038h: jp hint38
        inc hl
        ld (hl),low hint38
        inc hl
        ld (hl),high hint38
        ld hl,0ED45h            ; 0066h: retn
        ld a,h
        ld (0066h),a
        ld a,l
        ld (0067h),a
; 0068h-0FFFh: where the Spectrum's ROM routines were.  A program that
; calls one (CALL, JP) meets RST 30h and is stopped (htrap) - except
; BEEP and BEEPER, which just return: no sound, no harm.
        ld hl,0068h
        ld de,0069h
        ld bc,1000h-0069h
        ld (hl),0F7h            ; rst 30h
        ldir
        ld a,0C9h               ; ret
        ld (03B5h),a            ; BEEPER
        ld (03F8h),a            ; BEEP (C48's float.asm jumps there)
        call mhinit             ; the display mirror's glyph table
        im 1
        ld a,LATIDLE
        out (LATCH),a
        ld (latsh),a
        ld hl,0
        ld (tacc),hl
        ret

; hint38: the FDC raised INTRQ.  Nothing waits for it yet: read the
; status, which drops INTRQ, and carry on.
hint38: push af
        ld a,(tmron)
        or a
        jp nz,tint              ; the 50 Hz clock (tmr.asm)
        in a,(FDCST)
        pop af
        ei
        reti

; htrap: RST n was executed (A = n).  There is no ROM behind it: a
; program that wants the Spectrum's ROM (RST 10h to print, RST 28h for
; the calculator) is stopped with a message; in the kernel it is a panic.
htrap:  push af
        ld a,(inkern)
        or a
        jr nz,.k
        pop af
        ld hl,trapmsg+4
        call hhex
        ld hl,trapmsg
        call kputs
        call kmode
        jp sigck.xj0_11         ; exit, as if killed
.k:     pop af
        ld sp,KSTACK
        ld hl,trapmsg+4
        call hhex
        ld hl,trapmsg
        jp panic
trapmsg: db "rst ??h: no Spectrum ROM here",10,0

; hhex: A -> two hex digits at HL.
hhex:   push af
        rrca
        rrca
        rrca
        rrca
        call .d
        pop af
.d:     and 0Fh
        add a,90h
        daa
        adc a,40h
        daa
        ld (hl),a
        inc hl
        ret

hret:   ret

; ---------------------------------------------------------------------
; The link, as CBIOS A1.1 drives it (FDD3000-MSDOS BIOS.ASM, the version
; that ran on a real FDD3000): each byte is two nibbles, each echoed by
; the terminal.
;   send:  FDD 0Ah -> 0Fh, 1l -> 1l, 4h -> 4h, 50h (done)
;   key:   FDD 06h -> 05h (one is coming), 0Fh -> 1l, 1l -> 4h, 4h -> 50h
;   idle:  the terminal shows 04h when a key is waiting, else 50h.
;   07h from either side aborts the exchange.
; ---------------------------------------------------------------------
; lsend: A to the terminal.  Uses A, BC, DE.
lsend:  ld (lchr),a
.retry: ld a,(lchr)
        ld b,a
        call .send
        ret z
.ab:    in a,(LINK)             ; it went wrong: wait for the terminal's abort
        and 5Fh
        cp 07h
        jr nz,.ab
        jr .retry
.send:  ld a,b
        and 0Fh
        ld e,a
        ld a,b
        and 0F0h
        rrca
        rrca
        rrca
        rrca
        ld d,a
.rts:   ld a,0Ah                ; ask to send
        out (LINK),a
        in a,(LINK)
        and 5Fh
        cp 0Fh                  ; the terminal is ready
        jr nz,.rts
        ld a,e
        or 10h                  ; low nibble
        call lnib
        ret nz
        ld a,d
        or 40h                  ; high nibble
        call lnib
        ret nz
        ld a,50h                ; done
        out (LINK),a
        xor a
        ret
; lnib: send nibble A and wait for its echo.  NZ: no echo (aborted).
lnib:   out (LINK),a
        ld b,a
        ld c,0
.w:     in a,(LINK)
        dec c
        jr z,lfail
        and 5Fh
        cp b
        jr nz,.w
        xor a
        ret
lfail:  ld a,07h                ; abort
        out (LINK),a
        and a
        ret

; lrecv: A = the key the terminal has (7 bits).  Uses A, BC, DE.
lrecv:  call .get
        jr z,.ok
.ab:    in a,(LINK)
        and 5Fh
        cp 07h
        jr z,.ab
        jr lrecv
.ok:    ld a,b
        ret
.get:   ld a,06h                ; ask for a key
        out (LINK),a
        in a,(LINK)
        and 5Fh
        cp 05h                  ; one is coming
        jr nz,.get
        ld a,0Fh
        out (LINK),a
        ld c,0
.lo:    in a,(LINK)             ; low nibble: 1x
        dec c
        jr z,lfail
        ld e,a
        and 50h
        cp 10h
        jr nz,.lo
        ld a,e
        out (LINK),a            ; echo
        and 0Fh
        ld e,a
        ld c,0
.hi:    in a,(LINK)             ; high nibble: 4x
        dec c
        jr z,lfail
        bit 6,a
        jr z,.hi
        out (LINK),a
        and 0Fh
        rlca
        rlca
        rlca
        rlca
        or e
        and 7Fh
        ld b,a
.end:   in a,(LINK)
        and 5Fh
        cp 07h
        jr z,lfail
        cp 50h
        jr nz,.end
        ld a,50h
        out (LINK),a
        xor a
        ret

; ---------------------------------------------------------------------
; The console: kputc's language on a VT52.  ZX-UX writes 64 columns and
; 23 text rows; the terminal has 80 x 24, so the text keeps its Spectrum
; geometry (lines wrap at column 64) and AT row,col lands where it did.
;   16h AT r,c  -> ESC Y r+32 c+32      14h INVERSE n -> ESC L / ESC M
;   0Ch (cls)   -> ESC H ESC J          0Ah -> CR LF     08h, 07h as they are
;   09h TAB to the next column of 8     7Fh (the Spectrum's (c)) -> "(c)"
; ---------------------------------------------------------------------
; hputc: A = a character or a control (kputc).  Keeps every register.
hputc:  push hl
        push de
        push bc
        push af
        call cstrip             ; the screen's owner: its console text is
        jp nz,hputc.x           ; not shown (as on the Spectrum)
        pop af
        push af
        ld hl,ttat
        inc (hl)
        dec (hl)
        jr nz,.prm
        cp 16h                  ; AT row,col.
        jr z,.at
        cp 14h                  ; INVERSE n.
        jr z,.inv
        cp 10
        jr z,.nl
        cp 9
        jr z,.tab
        cp 8
        jr z,.bs
        cp 12
        jr z,.ff
        cp 7
        jr z,.raw
        cp 7Fh
        jr z,.copy
        jr nc,.x
        cp 20h
        call nc,hcol
.x:     pop af
        pop bc
        pop de
        pop hl
        ret
.nl:    call hnl
        jr .x
.ff:    call hcls
        jr .x
.raw:   call hout
        jr .x
.bs:    ld hl,tcol
        ld a,(hl)
        or a
        jr z,.x
        dec (hl)
        ld a,8
        jr .raw
.tab:   ld a,' '
        call hcol
        ld a,(tcol)
        and 7
        jr nz,.tab
        jr .x
.copy:  ld hl,s_copy
.cp:    ld a,(hl)
        or a
        jr z,.x
        call hcol
        inc hl
        jr .cp
.at:    ld (hl),2
        jr .ctl
.inv:   ld (hl),1
.ctl:   ld (ttcc),a
        jr .x
.prm:   dec (hl)                ; a parameter byte.
        jr z,.pend
        ld (ttp1),a
        jr .x
.pend:  ld c,a
        ld a,(ttcc)
        cp 14h
        jr nz,.pat
        ld a,c                  ; INVERSE 0/1: bit 0.
        rrca
        ld a,'M'
        jr nc,.esc
        ld a,'L'
.esc:   call hesc
        jr .x
.pat:   ld a,(ttp1)             ; AT: text rows and columns only.
        cp TROWS
        jr nc,.x
        ld b,a
        ld a,c
        cp 64
        jr nc,.x
        ld (tcol),a
        ld a,b
        ld (trow),a
        ld a,'Y'
        call hesc
        ld a,b
        add a,32
        call hout
        ld a,c
        add a,32
        jr .raw
s_copy: db "(c)",0

; hcol: print A in the next column; wrap after column 63.
hcol:   ld c,a
        ld a,(ttop)
        or a
        ld a,c
        jr z,.t
        ld a,(tcol)             ; console shared: row 22, by address,
        ld hl,clbuf             ; and kept for its move to row 21
        call addhla
        ld (hl),c
        call hc22
        ld a,c
.t:     call hout
        ld hl,tcol
        inc (hl)
        ld a,(hl)
        cp 64
        ret c
; hnl: a new line.
hnl:    ld a,(ttop)
        or a
        jr z,.t
        ld a,'Y'                ; console shared: rows 21-22 scroll
        call hesc
        ld a,21+32
        call hout
        ld a,32
        call hout
        ld hl,clbuf
        ld a,(tcol)
        or a
        jr z,.e
        ld b,a
.c:     ld a,(hl)
        call hout
        inc hl
        djnz .c
.e:     ld a,'K'
        call hesc
        xor a
        ld (tcol),a
        call hc22
        ld a,'K'
        jp hesc
.t:     xor a
        ld (tcol),a
        ld hl,trow
        ld a,(hl)
        cp TROWS-1
        jr nc,.b
        inc (hl)
.b:     ld a,13
        call hout
        ld a,10
        jr hout
; hc22: the cursor to row 22, column tcol (the shared console's line).
hc22:   ld a,'Y'
        call hesc
        ld a,22+32
        call hout
        ld a,(tcol)
        add a,32
        jp hout

; cstrip: Z: console output may go to the terminal.  NZ: the running
; process owns the screen (its console text is not shown).  When another
; process owns it, the console gets rows 21-22 (ttop = 21): programs draw
; above them (C48 reads ttop), the mirror reads only above them.
cstrip: call mbit
        ld hl,scrown
        and (hl)
        ret nz
        or (hl)
        ret z
        ld a,(ttop)
        or a
        jr nz,.z
        ld a,21
        ld (ttop),a
        ld hl,clbuf
        ld b,64
.b:     ld (hl),' '
        inc hl
        djnz .b
        xor a
        ld (tcol),a
        ld a,'Y'                ; rows 21 and 22 cleared
        call hesc
        ld a,21+32
        call hout
        ld a,32
        call hout
        ld a,'J'
        call hesc
.z:     xor a
        ret

; hcls: clear the terminal, home the cursor.
hcls:   xor a
        ld (tcol),a
        ld (trow),a
        ld a,'H'
        call hesc
        ld a,'J'
; hesc: ESC, then A.
hesc:   push af
        ld a,1Bh
        call hout
        pop af
; hout: A to the terminal; the time it takes goes on the clock.
hout:   push bc
        push de
        push hl
        call lsend
        ld hl,CHRCOST
        call htime
        pop hl
        pop de
        pop bc
        ret

; ---------------------------------------------------------------------
; Keys.  The terminal keeps a key until the FDD asks for it.  Its codes
; become the ones ZX-UX's line discipline knows (dev.asm ttrawin):
;   CR, LF -> 0Dh ENTER     BS, DEL -> 0Ch DELETE
;   ESC, ^D -> 07h (EDIT: vi's escape, end of file on a line)
;   ^C -> BREAK: every live process gets the interrupt (ttintr).
; ---------------------------------------------------------------------
; hkeys: take a key if the terminal has one.  Uses A, BC, DE, HL.
hkeys:  in a,(LINK)
        and 5Fh
        xor 04h                 ; (XOR, not CP: no phantom carry)
        ret nz
        call lrecv
        ld hl,kgot
        ld (hl),h               ; (non-zero: kidle returns)
        cp 03h
        jp z,ttintr
        ld hl,keytab
.k:     ld c,(hl)
        inc c
        dec c
        jp z,ttrawin
        inc hl
        cp c
        ld c,(hl)
        inc hl
        jr nz,.k
        ld a,c
        jp ttrawin
keytab: db 0Dh,0Dh, 0Ah,0Dh, 08h,0Ch, 7Fh,0Ch, 1Bh,07h, 04h,07h, 0

; ---------------------------------------------------------------------
; Time.  No interrupt counts the frames, so the kernel counts them: a
; system call, a character to the terminal and a turn of the idle loop
; each add what they cost (estimated, in 16 T units); every TICK units
; are a 50 Hz frame, and ktick does what the Spectrum's ISR did in one.
; ---------------------------------------------------------------------
; kpoll: at every system call (sysent; A = the call, arguments in HL, DE,
; BC).  Keeps HL, DE, BC.
kpoll:  push hl
        push de
        push bc
        call hkeys
        ld a,(scrown)           ; a program draws: a row of it at every
        or a                    ; system call, as well as at the ticks -
        call nz,mpoll           ; one that computes makes few of those
        ld hl,SYSCOST
        call htime
        pop bc
        pop de
        pop hl
        ret

; kidle: nothing can run (swtch has just run zidle).  As the Spectrum's
; HALT waited for the next frame, wait for the next tick, watching for a
; key all the while; return at the tick, or at once when a key came in.
kidle:  ld a,(tmron)            ; the WD1770 clock runs: wait for its tick,
        or a                    ; as the Spectrum waited for the frame
        jr z,.soft
        ei
        halt
        call hkeys
        ld a,(scrown)           ; (the tick does not draw in the kernel:
        or a                    ; the idle loop does, between its turns
        ret z                   ; on the link)
        jp mtick
.soft:  ld hl,ZCOST
        call htime
        ld a,(fticks)
        ld (ksnap),a
.l:     xor a
        ld (kgot),a
        call hkeys
        ld a,(kgot)
        or a
        ret nz
        ld b,IDLEDLY
.d:     djnz .d
        ld hl,IDLECOST
        call htime
        ld a,(ksnap)
        ld hl,fticks
        cp (hl)
        jr z,.l
        ret
; hzpoll: idle packing's check point (zx.asm zpoll), every ~3 ms of work:
; what the Spectrum's ISR did meanwhile - keys in, the clock on.  A key
; that wakes a reader makes zpoll stop the packing.  Keeps BC, DE.
hzpoll: push bc
        push de
        call hkeys
        ld hl,ZPCOST
        call htime
        pop de
        pop bc
        ret

; htime: HL units of time passed.  Uses A, DE, HL (and what ktick uses).
htime:  ld a,(tmron)            ; the WD1770 clock counts: no estimates
        or a
        ret nz
        ld de,(tacc)
        add hl,de
.l:     ld de,TICK
        or a
        sbc hl,de
        jr c,.r
        push hl
        call ktick
        pop hl
        jr .l
.r:     add hl,de
        ld (tacc),hl
        ret

; ktick: one 50 Hz frame: the clock and the sleepers (clk1), CPU
; accounting for ps and top, and the time slice.  The ISR switched
; processes itself; here the switch waits for the system call's way out
; (runrun -> sysx -> preempt).
ktick:  push bc
        call clk1
        ld a,(scrown)           ; a program draws: show it (mirror.asm)
        or a
        call nz,mtick
        pop bc
        ld a,(idling)
        or a
        jr nz,.idl
        ld a,(cur)
        ld hl,p_cpu
        add a,a
        call addhla
        inc (hl)
        jr nz,.q
        inc hl
        inc (hl)
.q:     ld hl,quant
        ld a,(hl)
        or a
        jr z,.q1
        dec (hl)
        ret nz
.q1:    call othrun
        ret nz
        ld a,1
        ld (runrun),a
        ret
.idl:   ld hl,(idlet)
        inc hl
        ld (idlet),hl
        ret

        include "fd.asm"        ; the floppy disk driver.
        include "vfs.asm"       ; mounted file systems ...
        include "zfs.asm"       ; ... of type 1, ZXFS.
        include "ssx.asm"       ; SSX1 programs from files.
        include "mirror.asm"    ; the display file, mirrored to the terminal.
        include "tmr.asm"       ; a 50 Hz clock from the WD1770.
; The FDD3000's own resident programs live here, not in the kernel image:
; what they do not take there is left to the arena.
        include "t_dd.asm"      ; /bin/dd
        include "t_fs.asm"      ; /etc/mount, umount (mkfs: kernel image)

; ---------------------------------------------------------------------
; variables
; ---------------------------------------------------------------------
tacc:   dw 0                    ; time not yet a whole tick (16 T units).
latsh:  db LATIDLE              ; the drive latch, which cannot be read.
lchr:   db 0                    ; the character being sent.
kgot:   db 0                    ; hkeys took a key.
clbuf:  ds 64                   ; the shared console's line (cstrip)
ksnap:  db 0                    ; kidle: fticks when it began.

halend:
        ASSERT halend <= 3F00h  ; the boot sector's page, then the display file.
        SAVEBIN "hal.bin", HALBASE, halend - HALBASE
