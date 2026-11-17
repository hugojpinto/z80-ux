; =====================================================================
; ZX-UX on the Timex FDD3000: a 50 Hz clock from the WD1770.
; Based on original work by Supratim Sanyal of SANYALnet Labs (ZX-UX).
; FDD3000 port: LoadZX Museum.  Non-commercial use only: see ../LICENSE.
; =====================================================================
;
;  The FDD3000's one interrupt is the WD1770's INTRQ (RST 38h).  A type I
;  Step command ends - and raises INTRQ - one step time after it starts:
;  20 ms on the 1770 for rate code 10.  So, with drive D selected, the
;  interrupt handler that receives INTRQ gives the FDC the next Step at
;  once, and the WD1770 ticks at 50 Hz, the Spectrum's frame rate.
;
;    TCMD = 2Ah: Step (001), u = 0 - the track register is left alone -,
;    h = 1 - no spin-up, which would wait for index pulses -, V = 0 - no
;    verify -, rate 10 = 20 ms.
;
;  Drive D (TDRV) must not exist: its select line is the clock's.  tinit
;  looks for it at boot; with four drives the soft clock is used.  The
;  STEP pulses reach no drive; nothing moves.  MOTOR ON, common to all
;  drives (WD1770 MO -> IC12 -> PL1-16), stays up while the clock runs -
;  but an HFD305S turns its motor only while selected: on a two-drive
;  FDD3000, B never turns while A works.  A and B are not selected while
;  the clock runs, so no motor turns.  (A drive jumpered MX, "enabled
;  regardless of DRIVE SELECT", would: the drives must be DS0 - DS2.)
;
;  The disk driver stops the clock around its own commands (fio, fprobe:
;  tsusp / tresume); meanwhile the soft clock (hal.asm htime) counts, as it
;  does when the clock does not run at all.
;
;  ttick does what the Spectrum's frame ISR did: the clock and the
;  sleepers, CPU accounting, and - when it interrupts a program, not the
;  kernel - keys, the display mirror, the time slice (it switches
;  processes itself) and BREAK.  In the kernel the slice ends at the
;  system call's way out (runrun), as before.
; =====================================================================

TDRV    equ 3                   ; drive D: the timer's
TCMD    equ 2Ah                 ; Step, no update, no spin-up, 20 ms
LATTMR  equ 0D7h                ; drive D, side 0, MFM, ROM out, light off

; tstart: the clock runs from now on (boot; tresume).  The interrupts
; are left as they were.  Keeps all but AF.
tstart: ld a,i                  ; P/V: interrupts on
        push af
        di
        ld a,1
        ld (tmron),a
        ld a,LATTMR
        out (LATCH),a
        ld (latsh),a
        ld a,TCMD
        out (FDCST),a
        pop af
        ret po
        ei
        ret

; tsusp: the driver wants the FDC: the clock stops (it was running: tmsus
; says so, for tresume).  Keeps every register (fio, fprobe: A = drive).
tsusp:  push af
        ld a,(tmron)
        ld (tmsus),a
        or a
        jr z,.x
        ld a,i                  ; P/V: interrupts on
        di
        push af
        xor a
        ld (tmron),a
        ld a,FC_INT             ; stop the Step, no interrupt for it
        out (FDCST),a
        push bc
        ld b,8
.d:     djnz .d
        pop bc
        in a,(FDCST)            ; (an INTRQ already up goes)
        pop af
        jp po,.x
        ei
.x:     pop af
        ret

; tresume: the driver is done: the clock again, if it ran.
tresume:
        ld a,(tmsus)
        or a
        ret z
        jr tstart

; hint38 comes here with AF pushed when the clock runs: the next Step at
; once, then the tick.
tint:   in a,(FDCST)            ; INTRQ down
        ld a,TCMD
        out (FDCST),a           ; the next 20 ms start now
        push bc                 ; (AF: pushed by hint38)
        push de
        push hl
        push ix
        push iy
        exx
        ex af,af'
        push af
        push bc
        push de
        push hl
        call clk1               ; a frame of time; sleepers wake
        ld a,(idling)           ; CPU accounting (ps, top)
        or a
        jr nz,.idl
        ld a,(cur)
        ld hl,p_cpu
        add a,a
        call addhla
        inc (hl)
        jr nz,.cpu
        inc hl
        inc (hl)
        jr .cpu
.idl:   ld hl,(idlet)
        inc hl
        ld (idlet),hl
.cpu:   ld a,(inkern)
        or a
        jr nz,.kern
; a program was running: what the frame ISR did for one
        call hkeys              ; keys, BREAK
        ld a,(scrown)
        or a
        call nz,mtick           ; its screen
        ld hl,quant             ; the time slice
        ld a,(hl)
        or a
        jr z,.q1
        dec (hl)
        jr nz,.sig
.q1:    call othrun
        call z,swtch            ; preempt the program
.sig:   ld a,(cur)              ; a signal for it (BREAK, kill): now
        ld hl,p_sig
        call addhla
        ld a,(hl)
        or a
        jr z,.x
        ld (hl),0
        cp 2
        jr z,.kill
        ld a,(u_intr)
        or a
        jr z,.x
.kill:  call kmode
        jp sigck.xj0_11
; the kernel was running: the slice ends at its system call's way out
.kern:  ld hl,quant
        ld a,(hl)
        or a
        jr z,.k1
        dec (hl)
        jr nz,.x
.k1:    call othrun
        jr nz,.x
        ld a,1
        ld (runrun),a
.x:     pop hl
        pop de
        pop bc
        pop af
        ex af,af'
        exx
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        reti

; ---------------------------------------------------------------------
; tinit (boot): is there a drive D?  Restored at 6 ms steps, a present
; drive shows TRACK 00 (an HFD305S drives it whenever selected, disk or
; not: manual 5(5)); an absent one never does, and the WD1770 gives up
; after 255 steps (~1.5 s).  Absent: the clock runs, and from then on
; drive D is its.  Present (a four-drive system): the soft clock (hal.asm)
; keeps time, and /dev/fd3 is drive D.
; ---------------------------------------------------------------------
tinit:  ld a,TDRV
        ld c,0
        call fsel
        ld a,FC_PROBE
        call fcmd1
        push af
        ld a,LATIDLE            ; D deselected again
        out (LATCH),a
        ld (latsh),a
        call dcurp              ; (the driver: D's position unknown)
        ld (hl),0FFh
        pop af
        ret c                   ; (a timeout: no answer, treat as present)
        and 04h                 ; TRACK 00: a drive D is there
        ret nz
        ld a,1
        ld (tmuse),a
        jp tstart
FC_PROBE equ 00h                ; restore, 6 ms steps, spin-up, no verify

tmron:  db 0                    ; the clock runs
tmsus:  db 0                    ; tsusp found it running
tmuse:  db 0                    ; drive D is the clock's (tinit)
