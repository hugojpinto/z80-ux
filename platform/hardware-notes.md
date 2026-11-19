# Hardware notes for the future targets

Research for platform/README.md, 2026-11-19. Paths are
relative to `/Users/hugopinto/Developer/LOADZX`.

How to read the citations:
- **[file §x / :line]** means the fact is in a local document.
- **[ROM-check]** means I checked it here against the ROM images in `TC3256/EMUL/roms/` (FUSE's copies).
- **[GK]** means general knowledge, not found in a local file.
- **UNCERTAIN** marks anything I could not confirm.

The ZX-UX parts of the ABI that the findings test:
- the system-call entry at **6003h**
- kernel variables at **5B00h–5FFFh**
- the kernel at **6000h–7FFFh**
- `TTOP` at **5BE4h**
- the window at **F000h–FFFFh** and the u-area at FFB9h
- the IM 2 trampoline at **FFF4h**, reached through **I = 39h** (`zx-ux/zx-ux/src/const.inc:37,47` and `unix.asm:2025-2034`). The vector is read at 39FFh in ROM and gives FFFFh. The byte at FFFFh is a JR back to FFF4h.
- direct calls into the Spectrum ROM, listed in `const.inc:185-193`: 02BFh KEYBOARD, 10A8h KEY-INPUT, 1601h CHAN-OPEN, 0D6Bh CLS, 03B5h BEEPER, 1F54h BREAK-KEY, 04C2h SA-BYTES, 0556h LD-BYTES, 3D00h charset. The kernel also jumps to 04D0h (`dev.asm:79`).
- ROM errors (RST 8) are caught through ERR_SP (`unix.asm:2035`).

---

## 1. Timex TC3256 (Portuguese, 1986)

Main sources:
- `TC3256/SIM/DOCS/using_the_tc3256_mmu.md`, cited below as **MMU-guide**. It was checked against the 1986 gate-array specification, the schematics, the 3CCB shadow ROM, the VHDL and FUSE.
- `TC3256_BASIC_ROM_Technical_Reference.md`, cited as **BASIC-ref**.
- `tc3256_serial_port.md`, `music_with_tc3256.md`, `tc3256_keyboard_spec.md` and `mmu_ROMCSL_DOCKL_ROSL_theory.md`.
- FUSE's `TC3256/EMUL/machines/tc3256.c`.

### Memory map at reset; RAM total
**Physical memory** [MMU-guide §1]:
- 64 KB EPROM, holding four 16 KB pages:
  - page 0: the shadow ROM (Extended BASIC, boot menu, TOS/FDD services)
  - page 1: TimeWord+
  - page 2: the CP/M Terminal
  - page 3: BASIC
- 16 KB video RAM (two 4416 chips)
- **256 KB DRAM** (8 × 41256). A 1 MB option was designed but never built.
- the 2 KB TENET mailbox SRAM

**Z80 map** [MMU-guide §2, §11.3]:

| Range | Contents |
|---|---|
| 0000–3FFF | "the stage": an EPROM page, or the 16 KB disk-boot DRAM (below) |
| 4000–7FFF | video RAM, owned by the SCLD; the MMU never maps it |
| 8000–FFFF | DRAM, physical 08000–0FFFF; never moves |

There is **no bank switching above 4000h** ("Unlike a 128K Spectrum, there is no bank you can swap at C000h", MMU-guide §9.9).

**At reset**, every MMU register is cleared: FIRMWARE=0, SECTOR=0, 256 KB mode, page 3 selected [MMU-guide §3, §11.1]. The fetch at 0000h then sets PAGIN, so the shadow ROM runs the boot menu, and BASIC (page 3) is what is on stage after it pages out.

**The BASIC page** is the stock 48K ROM with 638 bytes patched in place. Every documented 48K entry point is at its original address. Tape, keyboard and the RST vectors are byte-identical [BASIC-ref TL;DR]. I verified the bytes at all nine ZX-UX ROM entry points against `48.rom` [ROM-check].

### Can ROM be paged out for RAM at 0000h–3FFFh? Yes
- Set **port EEh bit 7 (FIRMWARE)**. In user mode (PAGIN=0), 0000–3FFF then becomes 16 KB of DRAM at physical 04000–07FFF, the "disk-boot" RAM [MMU-guide §3 swap 3, §9.7, §9.9.2, §11.2].
- **EEh bit 5 (WRITE_DISABLE)** makes that RAM read-only.
- This gives a full **64 KB all-RAM map** in user mode.
- You cannot choose which DRAM is mapped: the offset is fixed at 04000h [§9.9].
- **EEh and EDh can only be written in system mode (PAGIN=1).** Writes made in user mode are silently ignored [§4, rule 1].
- **System mode** is entered by an M1 (opcode) fetch at **0000h, 0008h or 0066h**. Fetching at **0604h** leaves it.
- The supported way in from a program is the **gateway**: `CALL 0008h` with **IY=0**, made from code at or above 4000h. It returns with PAGIN=1 and **DI** [§6 rule 2, §9.1].
- The way out is `JP 0603h` (EI; RET) or `JP 0604h` (RET), with the return address on the stack. `CALL 0604h` leaves system mode at that point in the code [§9.9.2].
- The gateway still works with FIRMWARE=1, because the trap fetch at 0008h always comes from the shadow ROM [§9.9.2 FW_OFF].

### Paging/MMU details

**Granularity.** Two mechanisms only [§9.9 table]:

| Mechanism | Size and place | Which DRAM | Mode |
|---|---|---|---|
| RAM-disk window | **4 KB** at 3000–3FFF | any sector, chosen by port EDh | system mode only |
| Disk-boot RAM | **16 KB** at 0000–3FFF | fixed (physical 04000) | user mode only |

The two are never visible at the same time.

**Port EEh** [§11.2]:

| Bit | Name | Effect |
|---|---|---|
| D7 | FIRMWARE | disk-boot RAM on the stage |
| D6 | SECTOR | window open |
| D5 | WRITE_DISABLE | disk-boot RAM read-only |
| D4 | 256K/1M | addressing mode |
| D3 | — | unused |
| D2 | — | TimeWord+ page |
| D1 | — | Terminal page |
| D0 | ROMCSL | BASIC (same as neither D1 nor D2) |

Change EEh by read-modify-write: every bit reads back.

**Port EDh** is the sector number. The window shows physical `(SECNUM+10h)*1000h` [§11.5].

**Port FDh** is the RS-232 latch and is always live [§11.1].

**Sectors** [§8, §9.9.3]:
- 256 KB mode has **52 usable sectors (00h–33h, 208 KB)**. Sectors 34h–37h are dead, and 38h–3Fh alias the user RAM at 8000–FFFF.
- In 1 MB mode, 00h–F3h are usable. That mode needs D4 and the hardware; it was never built.
- The shadow ROM's own RAM-disk file system (`SAVE!`/`LOAD!`/`CAT!`) keeps its directory in sector 00h and its data in 01h–33h. ZX-UX must either own the whole RAM disk or share it through the shadow ROM's services [§8].

**Gotchas**
- **An opcode fetch at 0000h, 0008h or 0066h always traps**, even when the stage is RAM [§9.9.2 rules]:
  - RST 0 cold-starts the machine and clears the MMU [§3].
  - RST 8 enters the shadow ROM. With IY≠0 it treats the call as a BASIC syntax error and tries an extended command [§6 rule 2].
  - Disk-boot code must never execute at those three addresses.
  - **This touches ZX-UX's ROM-error path.** A Spectrum ROM routine that raises an error (for example BREAK during SA-BYTES) does RST 8. On a TC3256 that enters the shadow ROM rather than going straight to BASIC's ERR_SP. The shadow ROM is expected to fall back to BASIC's error handling through CBAS [§10.3], but **UNCERTAIN: whether ZX-UX's `rom_error` is still reached cleanly. Test this.**
- **In system mode:**
  - 0000–2FFF is the shadow ROM, 2000–27FF is the TENET mailbox, and 3000–3FFF is either the shadow ROM or the open sector.
  - The shadow ROM's 0038h is a bare `RET` [§6 rule 6].
  - Code and stack must sit at 4000h or above [§6 rule 3].
  - **Close the window (EEh bit 6) before leaving**, or the next shadow-ROM entry breaks [§6 rule 5].
- **Interrupts in system mode, and ZX-UX's IM 2.** The vector is read at 39FFh. In system mode that address is either the shadow ROM or **the open RAM-disk sector's data**, so an interrupt taken while a sector is open jumps to garbage. Either keep DI in system mode (the gateway already does), or move the IM 2 table to 8000h or above.
- **IM 2 in user mode with BASIC paged:** TC3256 BASIC has bytes FF FF at 39FF/3A00, so ZX-UX's vector trick works today. However, only 7 of the 257 bytes in 3900–3A00 are FFh, because the patch code sits at 386E–3A97. It therefore works **only if the data bus reads FFh during the interrupt acknowledge**. That is likely on the SCLD (unattached ports read FFh in FUSE), but **UNCERTAIN on hardware** [ROM-check; BASIC-ref §1 table].
- **5FFA–5FFF.** TC3256 BASIC adds system variables at 5FFAh, 5FFCh and 5FFEh (hi-res flag and state, RS-232 baud). The patched PO_* and CL_* print and scroll routines read them [BASIC-ref §2.8]. They fall inside ZX-UX's kernel-stack area. This is harmless unless ZX-UX calls ROM print, scroll or CLS routines. It does call ROM_CLS at 0D6Bh, which is in the patched CL_* range: **check that path.**
- **Port F4h** (the SCLD bank select) is decoded by the SCLD, but its DOCK/EXROM selects go only to the expansion connector. The MMU ignores them [mmu_ROMCSL_DOCKL_ROSL_theory.md §2, §4.1]. FUSE maps empty 0xFF DOCK memory over any chunk whose F4 bit is set (`tc3256.c:147-163, 477-500`). **UNCERTAIN on hardware: never write F4h with bits for chunks 2–7.**
- **Contention.** FUSE contends only the video RAM at 4000–7FFF, using the TC2048 pattern. The DRAM (8000–FFFF, the disk-boot area and the sectors) is uncontended (`tc3256.c:252,349-379`). The VHDL and FUSE agree. Not measured on hardware.

### Display
- The SCLD display lives in video RAM at **4000h** and cannot be moved [MMU-guide §2].
- SCLD port FFh modes, as on the TC2068:
  - second screen at 6000h
  - hi-colour (attributes at 6000–77FF)
  - 512×192 hi-res, which uses 4000 and 6000. The boot menu writes `OUT (FFh),3Eh` [§9.6]. BASIC knows hi-res and adds 2000h to address the second 6 KB [BASIC-ref patches].
- **Every extended mode uses 6000–7AFF**, which is the ZX-UX kernel area.

### Interrupts
- SCLD frame interrupt at 50 Hz (PAL). FUSE uses TC2048 timings (`tc3256.c:234-273`); the master clock is 14.112 MHz (`specs/tc3256_system_spec.md §2.2`).
- Inhibit it with port FFh bit 6 [TS2068 manual §2.1.13.1, same SCLD].
- The TENET network raises an NMI that traps at 0066h [MMU-guide §11.4].

### Console I/O and storage
- **Keyboard:** standard Spectrum matrix on port FEh. The extra keys are produced in hardware as ghost CS/SS pairs, which is transparent to the CPU [tc3256_keyboard_spec.md Overview].
- **RS-232** on a DE-9 at **port FDh**. It is bit-banged: D0 is TX/RX, D7 is RTS/CTS. There is no UART, so interrupts must be off while a byte is sent [MMU-guide §11.1; tc3256_serial_port.md; BASIC-ref "bit-bang section: interrupts disabled"].
- **AY-3-8912** at F5h (register latch) and F6h (data) [music_with_tc3256.md §2].
- **Joystick** on the CN6 connector: the port is **UNCERTAIN**.
- **Storage:**
  - tape (ROM routines)
  - **FDD3000** over the DA-15 6-bit link, bit-banged on **port EFh** through the TENET GA. The shadow ROM wraps it in TOS services in the jump table at 0605h [tc3256_fdd3000_spec.md §1; MMU-guide §9.8].
  - the 208 KB **RAM disk**
  - the TENET network
  - the cartridge connector: DOCK boot is not supported by any known board [MMU-guide §12 last row]
- The shadow ROM keeps its FDD workspace in the 2 KB TENET SRAM (`ShadowROM_Technical_Reference_v2.md:51-56`). Whether its services touch main RAM elsewhere is **UNCERTAIN**.

### Consequences for ZX-UX
1. **The 48K build should run nearly unchanged** with BASIC paged: same ROM entry points, same tape, same screen. The points to check are RST 8, the IM 2 bus value, and ROM_CLS with 5FFxh.
2. **FIRMWARE gives 16 KB of RAM at 0000h**, the same layout the FDD3000 build already uses (HAL at 1800–3EFF, buffers and vectors low). The ROM's keyboard and tape routines then disappear, so there are two choices:
   - (a) Use HAL drivers, as on the FDD3000.
   - (b) **Copy BASIC page 3 into the disk-boot RAM and patch it.** The copy goes through a staging buffer, 4 KB at a time [MMU-guide §9.9.2]. The ROM-calling code keeps working, and ZX-UX then owns 0038h, the trampoline, and the ~1.1 KB of FFh at 3A98–3CFF.
   - Either way the HAL must never place code at 0000h, 0008h or 0066h.
3. **The RAM-disk sector is 4 KB, the same size as the ZX-UX window** (F000–FFFF).
   - Saved process windows (K_SAVE) could live in sectors instead of the arena.
   - A swap is: gateway, open sector, then two 4 KB LDIRs (or an exchange through a buffer) between 3000h and F000h, which are both visible in system mode. That is about 25 ms per 4 KB at 3.5 MHz.
   - This frees ~4 KB of arena per saved process and allows more than four process slots.
   - The same sectors could serve as a `/dev/rd` block device, a ZXFS volume, or spill space for packed or evicted files.
   - The kernel code doing the copy must sit at 4000h or above, with DI.
4. **More arena:** with the HAL moved to 0000–3FFF, the space it used could join the arena. The arena still cannot grow above 8000h, because no banking exists there.
5. **No hi-res or second screen** while the kernel sits at 6000h. The SCLD modes collide with 6000–7AFF.
6. The kernel at 6000–7FFF runs from **contended VRAM**. On the Spectrum it is contended too, so nothing changes.

### HAL must abstract (TC3256)
- the bottom-16K mode: ROM present or RAM (FIRMWARE)
- the system-mode gateway and its rules: DI, code at 4000h or above, close the window
- the RAM-disk sector copy primitive
- the trap addresses (0000h, 0008h, 0066h) and RST 8 error capture
- the source of the IM 2 table
- the console: keyboard and SCLD screen, or RS-232 at FDh
- block devices: FDD3000 over EFh through the shadow ROM's TOS services or a native driver; the RAM disk
- AY sound

### Could exploit
- 64 KB all-RAM user map
- 208 KB of RAM disk as swap for saved windows and as a RAM file system
- the RS-232 console
- TOS disks through the shadow-ROM services

---

## 2. ZX Spectrum 128K / +2 / +2A / +3

No local document describes 128K paging. `grep -i 7ffd` over the requested document directories finds only:
- `TC3256/SIM/DOCS/TOS_Technical_Reference.md:355-356`: the Timex FDD interface EPROM must `OUT (7FFDh),10h` (ROM1) on a 128K/+2, and also `OUT (1FFDh),04h` on a +3.
- `TI_FDD_Technical_Reference.md:40-46, 2101-2152`: a 128K variant of the Timex FDD interface ROM (1986-06-27) exists, and does 7FFDh paging in BOOT.
- `nextos_architecture_for_tc3256.md:163-179`: ROM selection by 7FFDh bit 4 and 1FFDh bit 2.

Everything else in this section is **[GK]**. The ROM byte checks are **[ROM-check]**.

### Memory map at reset; RAM total
**128 KB** of RAM in 8 × 16 KB banks (0–7), plus 32 KB of ROM (+2A/+3: 64 KB, ROM 0–3).

| Range | Contents |
|---|---|
| 0000–3FFF | ROM |
| 4000–7FFF | bank 5, always |
| 8000–BFFF | bank 2, always |
| C000–FFFF | one bank, selected |

At reset, 7FFDh = 0: bank 0 at C000, ROM0 (the 128 editor), screen in bank 5.

### Paging
**Port 7FFDh** (write-only on the 128K and +2; reads return the floating bus):

| Bits | Function |
|---|---|
| 0–2 | RAM bank at C000 |
| 3 | screen: 0 = bank 5, 1 = bank 7 |
| 4 | ROM: 0 = 128 editor, 1 = 48 BASIC; on the +2A/+3 this is the low bit of the ROM number |
| 5 | **lock** paging until reset |

Decoding of 7FFDh:
- 128K and +2: A15=0 and A1=0 only, so many ports alias it.
- +2A/+3: A15=0, A14=1, A1=0.

The ROM keeps a shadow copy of the last value in BANKM at 5B5Ch.

**Port 1FFDh** (+2A/+3 only; decoded by A15–A12 = 0001 and A1=0):

| Bit | Function |
|---|---|
| 0 | special (all-RAM) mode |
| 2 | ROM high bit (normal mode) |
| 3 | disk motor |
| 4 | printer strobe |

In special mode, bits 2–1 choose the layout of 0000/4000/8000/C000:

| Bits 2–1 | Banks |
|---|---|
| 00 | 0,1,2,3 |
| 01 | 4,5,6,7 |
| 10 | 4,5,6,3 |
| 11 | 4,7,6,3 |

**RAM at 0000h is possible only on the +2A/+3** (special mode). The original 128K and the grey +2 cannot do it.

**Granularity:** 16 KB. Only C000–FFFF moves in normal mode.

**Contended banks:**
- 128K/+2: the odd banks (1, 3, 5, 7)
- +2A/+3: banks 4–7

**Gotchas**
- **Lock bit.** "48 BASIC" mode, or USR 0, sets bit 5. ZX-UX must be loaded from 128 BASIC or the Tape Loader, not from 48 mode, or it can never page.
- **5B00–5BFF.** 128 BASIC keeps its paging routines and BANKM in the printer buffer, which is ZX-UX's kernel-variable page. That is fine once ZX-UX owns the machine and never returns to BASIC. ZX-UX must write 7FFDh with bit 4 = 1 itself.
- **Snow.** An I register value of 40h–7Fh causes snow or crashes on the 128K, and so does C0h–FFh while a contended bank is at C000. ZX-UX's I = 39h is safe.
- **ROM bytes at 39FFh** [ROM-check]:

| ROM | 39FF/3A00 | FFh bytes in 3900–3A00 | Effect on ZX-UX's vector |
|---|---|---|---|
| 128K ROM1 (48 BASIC) | FF FF | 4 of 257 | works only if the bus reads FFh at interrupt acknowledge; usually true at the top of the frame, but the 128K floating bus can carry other values |
| 128K ROM0 | 19 22 | — | broken |
| +3 ROM3 (48 BASIC) | 00 21 | 0 | **broken on +2A/+3** |

  The ZX-UX entry points (02BF, 0556, 04C2, 10A8, 03B5, 0D6B, 1601, 1F54) are byte-identical in 128-1.rom and plus3-3.rom [ROM-check].

### Display
- The screen is in bank 5 (4000h) or bank 7, selected by 7FFDh bit 3.
- Bank 7 can be written only while it is paged at C000.
- The ULA reads only offset 0000–1AFF of bank 5 or bank 7. There is no other relocation.

### Interrupts
- ULA frame interrupt at 50 Hz: 70,908 T per frame (228 T × 311 lines), CPU at 3.5469 MHz.
- No vector byte is guaranteed. On the 128K/+2 the bus floats; the +2A/+3 bus behaves differently. The robust choice is a 257-byte table in non-paged RAM.

### Console I/O and storage
- **Keyboard:** the 48K matrix on FEh.
- **AY** at FFFDh (select/read) and BFFDh (write).
- **RS-232/MIDI** bit-banged on AY I/O port A (128K/+2/+2A/+3).
- **Storage:**
  - tape
  - **+3:** a built-in 3" drive on a µPD765A (2FFDh status, 3FFDh data, motor on 1FFDh bit 3), with +3DOS in ROM2
  - **Timex FDD interface** (128K variant exists): FDD3000 through EFh [local docs above]
  - **Interface 1 microdrives:** work on the 128K/+2. **UNCERTAIN** on the +2A/+3; reportedly incompatible.

### Consequences for ZX-UX
1. **The window at F000–FFFF lies inside the paged C000 bank.** The u-area (FFB9) and the IM 2 trampoline (FFF4–FFFF) are also in it.
   - Either replicate the 12-byte trampoline plus the JR at FFFF into every bank,
   - or move the IM 2 table and handler to 8000–BFFF (bank 2) or 4000–7FFF (bank 5, contended) and fill a 257-byte table there.
   - **The second option is required for the +2A/+3** (ROM3 bytes) and is safer everywhere.
2. **The arena today runs B90A–EFFF, crossing C000.** If C000 pages, the arena must split into a fixed part below C000 and a per-bank part above it.
3. **Natural model: one bank per process.**
   - Each process's C000–FFFF holds its own 12 KB of private arena, SSX1 image and data, plus its 4 KB window and u-area.
   - A context switch is one `OUT (7FFDh)` instead of a K_SAVE copy.
   - With banks 0, 1, 3, 4, 6 and 7 free, that gives six 16 KB process spaces. Bank 7 is free if the shadow screen is not used.
   - SSX1 images then get up to ~12 KB at C000 plus the window, independently of each other.
   - What must stay global (kernel, shared resident text, inodes, shared arena) has to sit in 4000–BFFF.
4. **Shadow screen (bank 7):** a virtual console switched by flipping bit 3 instantly, or double buffering for SDK graphics. Writing to it means paging bank 7 at C000, which takes away the current process's window, so the kernel must mediate.
5. **RAM disk:** any banks not used for processes; about 96 KB on the 128K.
6. **+2A/+3 special mode 4,5,6,3** gives RAM at 0000h with the screen still at 4000h. The HAL can then live low, as on the FDD3000. While special mode is on, 7FFDh bank selection is ignored, so the HAL must switch modes to reach other banks. **Bank 4 at 0000h is contended on the +2A/+3.**

### HAL must abstract (128K)
- "map process P": `OUT (7FFDh)`, with the 7FFDh/1FFDh shadow register in kernel variables
- the bank allocator
- the IM 2 table location
- screen-bank selection
- ROM selection (keep ROM1/ROM3)
- the lock-bit check at boot
- the +3 FDC and +2A/+3 special mode as an optional variant
- AY sound and the AY-port serial line

### Could exploit
- zero-copy process switching
- six large process spaces
- a RAM disk
- virtual consoles on bank 7
- the +3 floppy

---

## 3. Timex TC2068 / TS2068

Main sources:
- `timex-cores/docs/references/TS2068 Technical Manual (OCR).txt`, cited as **MAN** with line numbers
- `classic-cores/docs/ts2068_vs_tc2068.md`, cited as **CMP**
- `classic-cores/docs/fuse_functional_reference.md`, cited as **FUSE-ref**
- `timex_scld/README.md`: an SCLD CPLD implementation for the TC2048/TC2068, with no functional detail

### Memory map at reset; RAM total
**48 KB of RAM** in the Home bank: 16 KB of video RAM at 4000–7FFF and 32 KB at 8000–FFFF [CMP §4.6].

**ROM:**
- 16 KB Home ROM at 0000–3FFF
- 8 KB Extension ROM (EXROM), which holds the tape routines, video-mode change and the interrupt fielder [MAN 3500-3600]

Memory is chosen in **eight 8 KB chunks**. Each chunk comes from Home, Dock (a cartridge, up to 64 KB) or EXROM [MAN:350-361, 2036-2090].

At reset, F4h = 0 and FFh = 0: everything is Home, the normal screen, interrupts enabled [FUSE-ref:48-50].

### Paging
**Port F4h** (the Horizontal Select Register, readable and writable) [MAN:2830-2837; FUSE-ref:22-28, 83-90]:
- Bit i set means chunk i (i·2000h) comes from Dock or EXROM instead of Home.
- **Port FFh bit 7** chooses Dock (0) or EXROM (1) for **all** selected chunks at once [MAN:2052-2090].
- The single 8 KB EXROM image appears in every chunk switched to it, because EXROM A13 is not connected [CMP §4.7; FUSE-ref:72-78].

**RAM at 0000h:** **not on a stock machine.**
- Dock with no cartridge reads FFh, and EXROM is ROM [FUSE-ref:95-101].
- RAM at 0000h needs a **Dock cartridge containing RAM** (FUSE's DCK format supports RAM banks) or external memory using /BE (TS2068) to disable the internal memories [MAN:2045-2047]. Whether such hardware is common is **[GK]: rare.**
- With a RAM Dock, any of the 8 chunks, Home RAM included, can be swapped per 8 KB.

**Interrupts and paging:**
- With chunk 0 switched, 0038h comes from Dock or EXROM.
- The EXROM's 0038h is a fielder that jumps to OS RAM code: INT3 at 62AEh when VIDMOD=0, or INT7 at FA6Eh [MAN fig. 3.2.2-1, ~3610-3625].

**Contention:** 4000–7FFF only, including Dock/EXROM chunks 2–3 there [FUSE-ref:97-98, 183].

**Ports FFh and F4h are readable** [MAN table 2.1.13-1].

### Display (port FFh) [MAN:2682-2703, table 3.2.2-1]

| Port FFh value | Mode | Memory used |
|---|---|---|
| 000 | normal | 4000–5AFF |
| 001 | second display file | **6000–7AFF** |
| 010 | hi-colour | pixels 4000–57FF + 8×1 attributes **6000–77FF** |
| 110 | 512×192 / 64 columns | even columns 4000, odd columns **6000**; ink/paper set by FFh bits 3–5 |

- Bit 6 = 1 inhibits the frame interrupt.
- Bit 7 selects EXROM or Dock.
- The SCLD always fetches from Home video RAM, and no other relocation exists.
- The ROM supports the second screen only through CHNG_VID, which moves OS RAM code [MAN:3630-3660].

### Interrupts
- SCLD vertical-blank interrupt, enabled by FFh bit 6 = 0.
- **TS2068: 60 Hz** (60.1 Hz, 262 lines, 58,688 T) [MAN:2446-2452, 3513-3518; CMP §3.3; FUSE-ref:226].
- **TC2068: 50 Hz.** SCLD pin 26 is a 50/60 strap; FUSE uses 69,888 T [CMP §3.3; FUSE-ref:153-158].
- The ROM uses IM 1.
- The bus value during interrupt acknowledge is **UNCERTAIN**: FUSE reads unattached ports as FFh.

### Console I/O and storage
- **Keyboard:** the Spectrum matrix on FEh. The 42 keys produce extra combinations [MAN §2.1.9; CMP §4.9].
- **AY** at F5h/F6h. **Joysticks** are read through AY register 14 on F6h with A8 or A9 high [CMP §4.8-4.9; MAN 2.1.13.4].
- **TS2040 printer** on FBh.
- **Storage:**
  - tape, with the routines in EXROM
  - **Dock cartridges** (ROM, or RAM with special hardware)
  - **Timex FDD interface**: TC2068 variants of the interface ROM on EFh [TI_FDD_Technical_Reference.md:44-46]
  - microdrive: none built in
- **The ROM is not Spectrum-compatible.** At 02BF, 0556, 04C2 and 10A8 the TC2068 ROM holds different bytes from `48.rom`, and its 39FF/3A00 bytes are E3 9F [ROM-check on `tc2068-0.rom`]. FUSE uses the TC2068 ROM for both machines; the real TS2068 ROM differs [FUSE-ref:229-234].

### Consequences for ZX-UX
1. **No ROM services.** Keyboard, tape, beeper, CLS, the charset at 3D00 and ERR_SP all need HAL drivers, as in the FDD3000 build. The TC2068 ROM has the charset at 3D00 too (the 3D00 bytes match).
2. **The IM 2 trick fails** (39FFh gives 9FE3h). Use a 257-byte table in RAM, at 8000h or above to stay uncontended, or use IM 1 through the ROM's 0038h. IM 1 would run Timex code that expects the Timex system variables and OS RAM code at 6000h, which the kernel overwrites.
3. **0000–3FFF stays ROM**, so the HAL must fit in 4000–FFFF. That leaves less arena than on the Spectrum.
4. **The second screen, hi-colour and 512×192 all collide** with the kernel at 6000–7AFF (and 6003h). The 512-pixel mode would make a native 64-column console, but it needs a kernel moved off 6000–7AFF, which the ABI forbids.
5. **Tick rate is 60 Hz on the TS2068.** Time slices, `sleep` and the clock must use a HAL constant.
6. **If a Dock RAM cartridge is present,** chunk 7 (E000–FFFF) covers the window plus 4 KB of arena. That is per-8K bank switching usable as process swap, but it is optional hardware.

### HAL must abstract (TC2068)
- the keyboard, tape, beeper and charset drivers (no ROM)
- the IM 2 table location
- the tick rate (50 or 60 Hz)
- SCLD port FFh (keep mode 0, interrupts enabled)
- optional Dock RAM banking through F4h and FFh bit 7
- the AY and joystick
- storage: tape or the Timex FDD interface

### Could exploit
- the AY
- Dock RAM if present
- little else under the current ABI

---

## 4. Cross-platform table

| Concern | Spectrum 48K | FDD3000 | TC3256 | Spectrum 128K (+2A/+3) | TC2068 / TS2068 |
|---|---|---|---|---|---|
| **ROM removable** | no | yes: boot ROM out via latch bit 6 (`fdd3000/src/hal.asm:37,56`) | yes: EEh D7 FIRMWARE, written only in system mode | 128K/+2: no. +2A/+3: yes, 1FFDh bit 0 special mode | no; only with a Dock RAM cartridge or /BE external memory |
| **RAM at 0000h** | no | yes, 0000–3EFF is the HAL (memory-plan §1) | 16 KB disk-boot DRAM at a fixed offset; **fetches at 0000h, 0008h and 0066h trap** | +2A/+3 only (banks 0 or 4) | no (stock) |
| **Paging granularity** | none | none (flat 64K) | 4 KB sector window at 3000h (system mode) + 16 KB bottom swap; nothing above 4000h | 16 KB at C000 (7FFDh); +2A/+3 16 KB × 4 fixed layouts | 8 KB × 8 chunks, Home vs Dock/EXROM (F4h + FFh bit 7) |
| **Screen base(s)** | 4000h | none: a 4000h image is read back by the mirror | 4000h; SCLD 2nd/hi-res/hi-colour use 6000h | bank 5 (4000h) or bank 7 (shadow; only via C000) | 4000h; 2nd/hi-res/hi-colour use **6000h** |
| **Interrupt** | ULA 50 Hz; ZX-UX IM 2 via ROM FFh at 3900–3A00 | WD1770 INTRQ on RST 38 IM 1; 50 Hz soft clock from the WD1770 (`tmr.asm`) | SCLD 50 Hz; IM 2 vector works only if the bus reads FFh; no interrupts in system mode | ULA 50 Hz; ROM1 works only if the bus reads FFh; **+3 ROM3 breaks the vector** | SCLD **60 Hz TS / 50 Hz TC**; ROM vector wrong; FFh bit 6 enables |
| **Console** | keyboard + 64-column screen | VT52 over the link to a Timex terminal | keyboard + screen, or RS-232 bit-bang at FDh | keyboard + screen; AY-port RS-232 | keyboard + screen (no ROM keyboard routine) |
| **Storage** | tape | WD1770, 4 drives, ZXFS/TOS | tape, FDD3000 via EFh/TOS (shadow ROM), 208 KB RAM disk, TENET | tape; +3 µPD765; Timex FDD interface; IF1 microdrive (128K/+2) | tape (EXROM), Timex FDD interface (EFh), Dock cartridges |
| **Extra RAM beyond the 48K map** | none | +16 KB (64K flat) | +16 KB at 0000h, +208 KB RAM disk (1 MB never built) | +80 KB in banks (128K total) | none stock; up to 64 KB Dock if fitted |
| **ROM services usable by the 48K build** | yes | no | yes (page 3 = 48K ROM, patched); check RST 8 and ROM_CLS | yes with ROM1 (128K) or ROM3 (+3) | **no** (different ROM) |
| **6000h–7AFF free for kernel** | yes | yes | yes unless SCLD modes are used | yes | yes unless SCLD modes are used (the ROM's OS RAM code at 6000h is overwritten) |
| **Window F000h–FFFFh stable** | yes | yes | yes | **no: inside the paged C000 bank** | yes (unless Dock chunk 7 is switched) |
