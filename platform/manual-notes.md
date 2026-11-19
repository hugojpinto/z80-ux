# The seam and the design book

How the platform seam (`platform/README.md`) changes the design guidelines
of *The Design of the ZX-UX Operating System* (Supratim Sanyal; `docs/`,
revision of 2026-11-17, upstream `f302288`), and what that would mean for
the manual. Proposals for the author, not edits to his book.

Chapter and appendix numbers are the book's. Quotations are short and
marked; page numbers are of the 2026-11-17 PDF.

---

## 1. The position the book takes now

The book is about one machine, and says so well. Chapter 19 already has
the principle the seam builds on — its section is called **"The hardware
boundary has to be explicit"** (p. 143) — and chapter 1's last words to
the reader invite ports (the README closes with "port ZX-UX to other
computers of its era"). What it does not yet have is a *place* where the boundary is
written down: Spectrum facts are spread through chapters 19–29 as facts
about ZX-UX.

Examples of statements that are true of the 48K and not of ZX-UX in
general:

- Ch. 19, *The 50 Hz heartbeat*: "the I register is set to 39h, which
  points the processor at a 257-byte stretch of ROM that happens to be
  filled with FFh", and the jump's displacement "is read from ROM address
  0000h — the value F3h". Two ROM bytes are part of the interrupt design.
  On the +2A/+3 (ROM3) and the TC2068 the stretch is not FFh; on the
  TC3256 only 7 of the 257 bytes are; on the FDD3000 there is no ROM.
- Ch. 19, *ROM is a service*: IY = 5C3Ah around every ROM call — a rule
  of machines with the 48 ROM (the rom48 driver), meaningless without it.
- Ch. 23: "Four ticks make one normal scheduling quantum, which is about
  80 milliseconds" — 66 ms at the TS2068's 60 Hz.
- Ch. 28: the console is the bit-mapped screen; ch. 2 *Two programs, one
  screen*; ch. 35 "the shared graphics screen cannot keep two drawing
  applications in private windows" — a property of the screen console
  (screen64).
- Ch. 6, 29: cassette as the storage and the program loader (rom48's tape).
- Ch. 35, *What the machine cannot do*: "a RAM file system, not disk
  persistence", "no MMU" — of the 48K; the FDD3000 has disks, the TC3256
  and 128K have paging.
- Appendix C and ch. 35's fixed layout (ITAB B64Ah, AR0 B94Ah, the arena
  14,006 bytes): of the Spectrum build; the FDD3000's are B60Ah, B90Ah,
  14,070.

None of this is wrong. It is the Spectrum *platform*, described as the
system.

## 2. Guidelines the seam adds

Proposed as design rules, in the book's style of short imperatives:

1. **Kernel code does not name a machine.** A line that exists for one
   machine is behind a capability or is a hook; the machine's facts are in
   its `platform.inc`. (The book's "the hardware boundary has to be
   explicit", made a file.)
2. **The reference platform is reproduced byte for byte.** Every change to
   the seam is proven on the Spectrum by rebuilding the shipped tape
   exactly. A seam that changes Spectrum bytes is a change to ZX-UX, not a
   port.
3. **Hardware is a choice of drivers; flags switch subsystems only.** A
   platform says what it *is* by the drivers it includes (rom48,
   screen64, a terminal, a disk driver); `HAL_VFS`, `HAL_SSXFILE` say which
   parts of ZX-UX it carries. Machines with the same hardware share the
   same drivers (the 48K, 128K, +3 and TC3256 all use rom48).
4. **The ABI is what binaries pin, and only that is fixed**: the call
   entry 6003h, the call numbers and SSX1; for drawing programs 5BE4h and
   the screen; for float users, the ROM calculator's variables. SSX1
   programs are relocatable and resident programs are rebuilt with the
   kernel, so the rest of the memory map — the kernel's place, the window,
   the arena — is the platform's to lay out. The Spectrum keeps its map
   because it must equal the shipped tape.
5. **Time is counted in ticks of `HAL_HZ`.** Nothing assumes 50.
6. **Interrupt vectors are the platform's.** The ROM-FFh trick is the 48K
   platform's choice; others place a vector table in RAM.
7. **The machine layer lives outside the kernel's 8 KB** and outside the
   ABI regions; its size limit is its platform's (the FDD3000's
   1800h–3EFFh is full to the byte).
8. **Optional subsystems are switched, not forked.** Mounts, block
   devices, SSX1 from files, boot-time mounting are kernel subsystems any
   platform can turn on; they are not "the FDD3000 version".
9. **Modules carry the ABI they were built for.** A file system module is
   refused by a kernel with a different ABI checksum (`fsmod.asm`).

## 3. Chapter by chapter

| Part | What changes |
|---|---|
| **Foreword, ch. 1** | One paragraph: ZX-UX runs on a family of Z80 machines through a platform layer; the 48K Spectrum is the reference platform and the book's subject; others are described in their own platform notes. The "frozen" 6000h–7FFFh kernel and the fixed map are the reference platform's; binaries pin only 6003h and a few runtime addresses. |
| **Ch. 2** *Two programs, one screen* | Mark as a behaviour of the screen console (screen64). On a terminal console there are none: programs that draw are refused there (the FDD3000). |
| **Ch. 6** *Cassettes*, **ch. 29** | Scope to the tape driver (rom48). A sidebar: on platforms with `HAL_SSXFILE`, an SSX1 program is a file, `/etc/ldx` reads it from a descriptor. |
| **Ch. 7** *The software clock* | Ticks are `HAL_HZ`; mention a platform without a frame interrupt (the FDD3000's WD1770 clock, the soft clock). |
| **Ch. 12, 33** (SDK, C48) | The runtime draws at 4000h; note the planned screen-page call (41) that lets a platform place the screen, and a terminal console for text programs (`fdd3000/docs/memory-plan.md`). |
| **Ch. 19** *The machine beneath* | The pivot chapter. Keep the Spectrum's address space, ROM and heartbeat as *the reference platform*; add a section **"Platforms"**: capabilities, hooks, the machine layer, the one rule, the byte-identical proof. State that the IM 2 trick depends on two ROM bytes. |
| **Ch. 20** *Booting* | Boot becomes: platform init (`HAL_INIT`) → interrupt setup (Spectrum: IM 2) → clock (`HAL_START`) → init (+ `HAL_BOOTMNT`: mount the system volume, run its rc). The build section: one source tree, a `platform.inc` per target. |
| **Ch. 21** *System-call boundary* | `sysent`/`sysx` gain hooks (`HAL_ENTER`, `HAL_LEAVE`): what a machine layer may and may not do there (no allocation, keep the registers the call returns). |
| **Ch. 23** *Clock and scheduler* | What the handler does is split into the machine's part (keys, vectors) and the kernel's (clock, accounting, quantum, signals) — the planned shared `ktick`. `HAL_IDLE`: `halt` needs an interrupt to come back; a platform without one polls. |
| **Ch. 24, 25** *Memory, window, arena* | The memory map becomes per platform (table, Appendix C). The window/arena relation stays; note what paging platforms change (128K: one bank per process instead of copying the window; TC3256: windows in RAM-disk sectors). New fixed arena kind for loaded modules (K_FSM). |
| **Ch. 26, 27** *File system, byte I/O* | With `HAL_VFS`: mounted file systems, i-numbers ≥ 1000h, the i-node cache, types built in or loaded; seek origins 3–5 in sectors. The RAM file system stays the root everywhere. |
| **Ch. 28** *Devices, terminal, display, keyboard* | Two console drivers (screen64, a terminal) behind one interface (`kputc`, `kcls`, `curon`, `curoff`, sys screen); block devices with `HAL_BLKDEV`; the device-number space per platform. |
| **Ch. 34** *Testing* | The four kinds of checking gain a fifth axis: **per platform**. The Spectrum's gate (byte-identical) proves the seam; each other platform has its emulator tests (the FDD3000's `fdd3000/test`). |
| **Ch. 35** *What the machine cannot do* | Split into "what the Spectrum cannot do" (as now) and "what a platform may add" (disks, paging, a terminal); the *what to examine before changing the kernel* list gains: "does it name a machine?", "does the Spectrum still build byte for byte?" |
| **Appendix A, H** | Calls 21/22 (mount/umount) and reserved 41 (screen page), per platform. |
| **Appendix C** | Constants and addresses per platform; capability table. |
| **Appendix D, G** | `platform/` and the machine-layer files in the atlas. |
| **Appendix I** | New rows below; some rows become conditional. |
| **Appendix J** | The IY rule is rom48's; note the machine layer's register contract at `HAL_ENTER`/`HAL_LEAVE`. |
| **New appendix** | *Platforms*: the capability and hook tables, the ABI pins, one page per platform (48K, FDD3000; future: TC3256, 128K, TC/TS2068 from `hardware-notes.md`). |

## 4. Appendix I: proposed rows

| Invariant | Practical check | Source |
|---|---|---|
| Platform neutrality | No kernel line names a machine; machine lines are behind a `HAL_*` capability or hook. | `zx-ux/src`, `platform/*/platform.inc` |
| Reference build | The Spectrum system rebuilds byte for byte as `ZX-UX.tzx`. | `build.py spectrum` |
| ABI pins | 6003h, the call numbers, SSX1 (and 5BE4h, the screen, the ROM calculator's variables where programs use them) unchanged on every platform; the rest of the map is the platform's. | `const.inc`, `sdk/bin/py/lib` |
| Tick rate | Every time computation uses ticks of `HAL_HZ`. | `unix.asm` (`clk1`), machine layers |
| Machine layer bounds | The machine layer fits its platform's region and never covers ABI regions. | `hal.asm` `ASSERT`, platform map |
| Mounted i-nodes | A mounted file's i-node lives in the i-node cache, is written back at every system call's end, and never has an arena block. | `vfs.asm`, `fs.asm` |
| Loaded modules | A file system module is loaded only with this kernel's ABI checksum, into a fixed block outside a lent window, and freed with its last mount. | `fsmod.asm`, `fsmod.py` |

Rows that become conditional: **Tape unwind** (with rom48's tape),
**Interrupt registers** (the IY rule, with rom48), **SSX loan**
(also when an SSX1 image comes from a file, `HAL_SSXFILE`).

## 5. What to keep exactly as it is

The book's voice and its single-machine focus are its strength. The seam
does not need the book to become a porting manual: a platform section in
ch. 19, a *Platforms* appendix, a sentence of scope where a chapter states
a 48K fact, and three Appendix I rows would carry it. The rest — the arena,
the packer, the process model, the shell — is the same on every platform.

---

Sources: the book (`docs/Design_of_the_ZX-UX_Operating_System.pdf`, upstream
`f302288`), `platform/README.md`, `platform/hardware-notes.md`,
`fdd3000/README.md` (*Relation to the design*), `fdd3000/docs/memory-plan.md`.
