# Amiga-CDTV-U75

**Reverse-engineered firmware disassembly for the Commodore CDTV U75 microcontroller.**

Community project. Intended for Amiga/CDTV hobbyists who want to understand the CDTV's
input handling — or build compatible hardware.

---

## What is the U75?

The U75 is a **MOS 6500/1 one-chip microcontroller** soldered to every CDTV mainboard.
It is the sole processor handling all user input:

| Input | Hardware |
|---|---|
| IR remote (CD1252) — mouse, joystick, media keys, keyboard | PA0 / IRDT |
| Wired peripheral port (CD1221 keyboard, front panel) | PA3 / PRDT |
| Mouse quadrature output to Denise JOY0DAT | PortD |
| Joystick quadrature output to Denise JOY1DAT | PortC |
| Media key nibble to U62 latch (CPCP0-3) | PB4-7 |
| Wired keyboard serial (CIA _KBCLOCK / _KBDATA / _KBSE) | PA1/PA2, PB2 |

The CDTV's 68000 never sees raw input — everything passes through the U75 first.

---

## Architecture summary

| | |
|---|---|
| CPU core | MOS 6502 (6500/1 variant) |
| ROM | `$0800–$0FFF` (2 KB) |
| RAM | `$0000–$003F` (64 bytes zero page; `$2E–$3F` is the stack) |
| I/O | `$0080–$008F` (memory-mapped on-chip registers) |
| Stack | Zero page only. SP initialised to `$3F`; grows down (~18 bytes usable) |
| IRQ | Every ~163 φ2 cycles (~108.7 µs). Latch = 140, overhead = 23 |
| Vectors | `$0FFA–$0FFF` (NMI, RESET, IRQ — all in ROM) |

The interval timer fires an IRQ every ~109 µs throughout normal operation.
All pulse timing — IR mark/space classification, wired keyboard bit sampling —
is counted in IRQ ticks rather than busy-loop cycles.

---

## IR protocol summary

Three distinct IR sub-protocols are decoded:

### Protocol 1 — NEC-style (media keys, joystick buttons, mouse buttons)
- CPCP encoding: 4-bit command nibble sent to U62 via PB4-7
- Header: long mark (~1100 µs) + short space; data bits pulse-position encoded
- Repeat frames detected by space duration (13–30 IRQ ticks)
- 9 base media keys + joystick/mouse button variants

### Protocol 2 — CD1252 IR mouse
- Mark-encoded; start mark ≥800 µs; bit-1 mark ≥300 µs; bit-0 mark <300 µs
- Measured start: ~1100L/399H µs; bit-1: ~520–620L µs; bit-0: ~105L µs
- TSOP stretches marks ~20 %, shortens short marks ~30 %
- Frame gap: H ≥ 8 ms

### Protocol 3 — 40-bit mark-encoded keyboard (CD1252 / IR keyboard)
- 40 bits: 4-bit header nibble | 8-bit status | 8-bit command | 8-bit check1 | 12-bit check2
- Wire header nibble = `0x4` (after ROR chain bit-reversal of nibbles)
- Decoded by `f_QualifierKbdDecode` at `$0CA8`, gated on IREventFlag bit 2
- Modifier keys (Shift, Alt, Amiga, Control, Caps Lock): StatusByte = 2, one-hot in command byte
- Standard keys: StatusByte = 0, command byte = Amiga scancode
- Four frames required for Shift+A (one event dispatched per `f_ProcessKeyboardEvent` call)
- Inter-frame gap must stay well under ~83,456 t-states (512 IRQs) to avoid periodic state reset

---

## Main loop

```
Loop_Main ($0835)
  │
  ├─ f_ProcessIRAndKeyboardEvents ($084A)  — sample IR/keyboard lines, set event flags
  ├─ f_ProcessIREvent             ($0A56)  — decode raw IR pulses into shift registers
  ├─ f_ProcessIRDataAndSetFlags   ($0C61)  — verify frame checksums, extract fields
  ├─ f_JumpTableDispatcher        ($0CFE)  — route to mouse / joystick / keyboard handler
  ├─ f_WriteAllPorts              ($0E0B)  — flush port shadows to hardware
  └─ f_ProcessKeyboard            ($0E25)  — wired keyboard / media events, clear flags
```

---

## Files in this repository

| File | Description |
|---|---|
| `U75-Final.asm` | Fully annotated ca65-syntax disassembly (~2200 lines). All zero-page variables, I/O registers, functions and data tables named and commented. |
| `U75.txt` | Ghidra export — raw annotated listing as produced by the Ghidra disassembler. Useful as a cross-reference. |
| `u75_rom.csv` | ROM byte table (512 rows × 9 columns: address + 8 data bytes). Useful for byte-level verification. |

---

## How to use with Ghidra

1. Create a new Ghidra project; import `u75.BIN` as a flat binary.
2. Set the language to **6502** (or closest 6502 variant available).
3. Set the base address to `0x0800`.
4. Manually define the memory regions:
   - RAM: `0x0000–0x003F`
   - I/O: `0x0080–0x008F`
   - ROM: `0x0800–0x0FFF`
5. Use `U75-Final.asm` as a reference to apply labels, comments and colour highlights.
6. The `GhidraAnnotationImporter.java` script (see the companion `Amiga-CDTV-Brick` repo)
   can import CSV-format EOL, PRE and PLATE comments in bulk.

---

## Key findings

- **Stack is zero-page only**: `$2E–$3F`, ~18 bytes. Deep call chains will corrupt RAM.
- **BIT instruction used as a skip trick** throughout — not a data operation.
- **`f_QualifierKbdDecode` is misnamed**: it is the 40-bit IR keyboard frame *decoder*, not a qualifier decoder. Name retained from Ghidra auto-analysis; see commentary in the ASM.
- **`f_ProcessJoystick` / `f_ProcessMouse` names are swapped** relative to Amiga port conventions — names reflect ROM behaviour (which port is written), not hardware labelling.
- **PortD = mouse (JOY0DAT); PortC = joystick (JOY1DAT)**: `f_Quadrature` writes exclusively to PortD. PortC never receives quadrature output.
- **PB2 / _KBSE constraint**: bit 2 of the CPCP Command field is always zero across media keys; setting it would corrupt ModifierIndex calculation before the `ORA #0x0F` guard.
- **IRQ effective period**: ~163 φ2 cycles (~108.7 µs), not the nominal 140 — overhead accounts for the difference. All timing thresholds are expressed in IRQ ticks throughout this disassembly.

---

## Primary references

- MOS 6500/1 One-Chip Microcomputer datasheet, October 1986
- Commodore CDTV Service Manual, May 1991
- CDTV CD1221 keyboard hardware documentation
- CDTV CD1252 IR mouse manual

---

## Related project

[**Amiga-CDTV-Brick**](https://github.com/Korinel/Amiga-CDTV-Brick) — RP2040 firmware that
reads physical joysticks and transmits CDTV-compatible IR frames, allowing standard Amiga
joysticks to control a CDTV.

---

## Licence

This disassembly is released for community use. The original firmware is copyright Commodore
Business Machines. Reproducing the ROM binary without authorisation may infringe that
copyright — check the laws in your jurisdiction before distributing the binary itself.
