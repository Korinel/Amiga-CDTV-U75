;
; U75.asm — Commodore CDTV U75 Firmware Disassembly
; MOS 6500/1 One-Chip Microcontroller
;
; Handles all CDTV input:
;   IR remote  — CD1252 mouse, NEC media keys, 40-bit mark-encoded keyboard
;   Wired      — CD1221 keyboard (serial), front panel buttons
;   Quadrature — mouse (PortD / JOY0DAT) and joystick (PortC / JOY1DAT)
;
; Architecture:
;   CPU    MOS 6500/1 (6502 core + on-chip timer / I/O)
;   ROM    $0800-$0FFF  (2 KB)
;   RAM    $0000-$003F  (64 bytes zero page; $2E-$3F is the stack)
;   I/O    $0080-$008F  (memory-mapped on-chip registers)
;   Stack  Zero-page only. S initialised to $3F; grows down (~18 bytes).
;   IRQ    163 phi2 cycles per tick (~108.7 us). Latch=140, overhead=23.
;
; Syntax: ca65 (cc65 assembler suite)
;   label:          code / data labels
;   label = $NN     zero-page and I/O equates
;   $xx             hex immediate / address
;   %xxxxxxxx       binary immediate
;   .byte / .word   data directives
;
; Community reverse engineering project — Amiga/CDTV hobbyist resource.
; Primary refs: MOS 6500/1 datasheet Oct 1986, CDTV Service Manual.
;

                        .feature c_comments
                        .feature labels_without_colons


; ────────────────────────────────────────────────────────────────────────────
; Zero Page  $0000-$003F
; RAM locations used as firmware variables and the hardware stack.
; Defined as equates — not assembled storage.
; ────────────────────────────────────────────────────────────────────────────

zp_PortA                = $0000                             ; $0000: FF  ; Shadow of hw_PortA (0x80). PA0=IRDT (IR data in), PA1=_KBDATA, PA2=_KBCLOCK, PA3=PRDT (wired peripheral data in)
zp_PortB                = $0001                             ; $0001: FF  ; Shadow of hw_PortB (0x81). PB0-1=AUS0-1, PB2=_KBSE (keyboard serial enable), PB3=AUS2, PB4-7=CPCP0-3 (media key nibble to U62)
zp_PortD                = $0002                             ; $0002: FF  ; Shadow of hw_PortD (0x83). PD0=YB1, PD1=XA1, PD2=YA1, PD3=XB1 (mouse quadrature), PD4=FIRE0, PD5-6=POT. WARNING: clobbered by quadrature encoder at 0x0AF0
zp_PortC                = $0003                             ; $0003: FF  ; Shadow of hw_PortC (0x82). PC0=YB2, PC1=XA2, PC2=YA2, PC3=XB2 (joystick quadrature), PC4=FIRE1, PC5-6=POT
zp_PulseDuration_LSB    = $0004                             ; $0004: FF  ; IR pulse duration counter LSB. Incremented every IRQ tick (~163 t-states) while bit 7 of zp_IREventFlag is set
zp_PulseDuration_MSB    = $0005                             ; $0005: FF  ; IR pulse duration counter MSB. Masked to 4 bits at 0x0BB6 giving a 12-bit range (0-4095 ticks, max ~445 ms)
zp_ProtocolMask         = $0006                             ; $0006: FF  ; Protocol line mask: 0x01 for IR (PA0/IRDT), 0x08 for wired (PA3/PRDT), 0x06 for keyboard (PA1+PA2). Set at 0x08C8
zp_IRCommandByte        = $0007                             ; $0007: FF  ; Decoded IR command byte. On the 20-bit path: mouse/joystick/numpad command. On the 40-bit keyboard path: qualifier bitmask (one bit per qualifier key). Interpretation depends on which decode path last wrote this location.
zp_KeyboardIndex        = $0008                             ; $0008: FF  ; Keyboard table index (0x0F7C). 0=no key. Set by f_Decode40BitIRKeyboard
zp_IRShift0             = $0009                             ; $0009: FF  ; IR shift register byte 0 (LSB of 40-bit frame buffer). Bits enter via ROR chain from byte 4
zp_IRShift1             = $000A                             ; $000A: FF  ; IR shift register byte 1
zp_IRShift2             = $000B                             ; $000B: FF  ; IR shift register byte 2
zp_IRShift3             = $000C                             ; $000C: FF  ; IR shift register byte 3
zp_IRShift4             = $000D                             ; $000D: FF  ; IR shift register byte 4 (MSB). Status nibble extracted from bits[7:4] after 4 LSRs at 0x0A6E-0x0A71
zp_IRHeaderNibble       = $000E                             ; $000E: FF  ; IR header nibble: 0x0=mouse, 0x1=joystick, 0x2=keyboard
zp_IREventFlag          = $000F                             ; $000F: FF  ; IR event state flags. bit0=error/timeout, bit1=repeat frame received, bit2=40-bit qualifier frame, bit7=pulse measurement active
zp_IRQCount_LSB         = $0010                             ; $0010: FF  ; 16-bit IRQ tick counter LSB. Incremented every IRQ (~163 t-states / ~108.7 us). Used for keyboard timing and periodic reset
zp_IRQCount_MSB         = $0011                             ; $0011: FF  ; 16-bit IRQ tick counter MSB. Combined with LSB bit0 gives a 9-bit window (~512 IRQs / ~56 ms) for periodic port refresh
zp_KB_Temp              = $0012                             ; $0012: FF  ; Keyboard state flag. bit0: set when a full NEC frame has been validated (enables repeat-range test on next frame)
zp_Remote_NP_Media      = $0013                             ; $0013: FF  ; Remote event type flags. bit0=numpad key pending, bit1=media key pending (bit1 is never set by any firmware path)
zp_ModifierIndexPrior   = $0014                             ; $0014: FF  ; Previous qualifier bitmask (one bit per qualifier key per Amiga Hardware Reference Manual). Stored here after each IR frame; compared on next frame to detect changes. RENAME CANDIDATE: zp_QualifierBitmaskPrior
zp_KeyboardIndexPrior   = $0015                             ; $0015: FF  ; Previous keyboard index. Compared against zp_KeyboardIndex to detect changes; updated after transmission
zp_IRInputReady         = $0016                             ; $0016: FF  ; IR data ready flag. bit7=peripheral data ready for main loop commit. Set by f_CommitPendingModifierEntry, cleared at 0x0861
zp_IRPR_RawState        = $0017                             ; $0017: FF  ; Raw PortA state snapshot. Updated each call to f_DetectInputEdges; previous value used for edge XOR comparison
zp_IRPR_RawDeactEdge    = $0018                             ; $0018: FF  ; Raw deactivation edges: bits that transitioned from active (low) to inactive (high) since last edge detection call
zp_IRPR_ActiveFlags     = $0019                             ; $0019: FF  ; Active-high input flags. PA0/PA3 inverted to active-high convention. Seeded to 0x09 at reset for edge detector baseline
zp_IRPR_ActivationEdge  = $001A                             ; $001A: FF  ; Activation edge flags. Bits set where inputs transitioned from inactive to active since last call. Tested for PA0 (bit0) and PA3 (bit3)
zp_PendingModifier0     = $001B                             ; $001B: FF  ; Dual-use: (1) pending modifier staging byte 0 for IR keyboard path, (2) distance accumulator for quadrature channel 0
zp_PendingModifier1     = $001C                             ; $001C: FF  ; Dual-use: (1) pending modifier staging byte 1 for IR keyboard path, (2) distance accumulator for quadrature channel 1
zp_QuadPhase0           = $001D                             ; $001D: FF  ; Quadrature phase counter channel 0. 2-bit modulo-4 ring (0-3). Indexes into tbl_QuadratureX at 0x0B4C
zp_QuadPhase1           = $001E                             ; $001E: FF  ; Quadrature phase counter channel 1. 2-bit modulo-4 ring (0-3). Indexes into tbl_QuadratureY at 0x0B50
zp_IRInputProcessed     = $001F                             ; $001F: FF  ; IR input processed flag. Set to 1 after f_ProcessIRInput runs; cleared to 0 by IRQ after port write completes. Guards against re-entry
zp_QuadDelta0           = $0020                             ; $0020: FF  ; Signed movement delta for quadrature channel 0: +1=forward, 0xFF=reverse, 0=idle. Cleared when distance accumulator saturates
zp_QuadDelta1           = $0021                             ; $0021: FF  ; Signed movement delta for quadrature channel 1: +1=forward, 0xFF=reverse, 0=idle
zp_StatusCheck          = $0022                             ; $0022: FF  ; Status check sentinel. Initialised to 0xFF at reset; cleared at end of f_ProcessKeyboard. Non-zero blocks IR dispatch re-entry at 0x08AC
zp_PeripheralDataReady  = $0023                             ; $0023: FF  ; Peripheral data ready semaphore. Set to 1 when Protocol 2 frame decoded; cleared at start of f_ProcessIRAndKeyboardEvents. Triggers PortD reset
zp_FrontPanelPrevious   = $0024                             ; $0024: FF  ; Previous front panel button state (PortB bits 0/1/3). Used for edge-triggered change detection in f_ProcessFrontPanel
zp_UNUSED               = $0025                             ; $0025: FF  ; Unused
zp_ScratchA             = $0026                             ; $0026: FF  ; Scratch A: scancode to send / PortA snapshot 1 / X-axis offset
zp_ScratchB             = $0027                             ; $0027: FF  ; Scratch B: key direction flag / PortA snapshot 2 / Y-axis offset
zp_ScratchC             = $0028                             ; $0028: FF  ; Scratch C: PortA snapshot 3 / checksum command byte copy
zp_ScratchD             = $0029                             ; $0029: FF  ; Scratch D: PortA snapshot 4 / checksum complement byte
zp_PeriphTypeSave       = $002A                             ; $002A: FF  ; Peripheral type save/restore. Y register stashed here before quadrature processing; restored afterwards
zp_IRScratch            = $002B                             ; $002B: FF  ; IR scratch byte. Temp for rotation chain in f_Decode40BitIRKeyboard checksum 3
zp_BitValue             = $002C                             ; $002C: FF  ; Validated bit value from mark duration classifier: 0=short mark (bit 0), 1=long mark (bit 1). Used in Protocol 2 bit loop
zp_KB_ShiftRegister     = $002D                             ; $002D: FF  ; Keyboard/peripheral shift register. Accumulates bits via LSR/ROL in the 3-bit header and 11-bit keyboard paths

; 0x002E–0x003F: Stack area (18 bytes)
; Stack pointer S initialized to 0x3F, grows downward to 0x2E
; Maximum safe depth: ~9 JSRs or ~3 nested calls during IRQ
; Stack area (0x2E-0x3F): 18 bytes. Stack pointer initialised to 0x3F at reset and grows downward.
; Maximum safe depth is approximately 9 JSR frames or 3 nested calls during IRQ service.
zp_StackBase-1          = $003E                             ; $003E: FF
zp_StackBase            = $003F                             ; $003F: FF  ; Initial stack location (S=0x3F at reset)

; ────────────────────────────────────────────────────────────────────────────
; I/O Registers  $0080-$008F
; MOS 6500/1 on-chip memory-mapped peripherals.
; Defined as equates — not assembled storage.
; ────────────────────────────────────────────────────────────────────────────

hw_PortA                = $0080                             ; $0080: FF  ; Hardware PortA. PA1=_KBDATA output (U75 drives to CIA), PA2=_KBCLOCK output (U75 drives to CIA). U75 uses these as outputs only to relay IR-decoded scancodes. The CD1221 also connects to these lines but communicates with the CIA independently.
hw_PortB                = $0081                             ; $0081: FF  ; Hardware PortB. PB2=_KBSE: keyboard serial enable line. Held high by CIA when ready to receive; U75 waits for PB2 high before each serial transmission. Note: _KBSE is floating/unconnected on the CD1221 — the line is driven by the CIA not the keyboard.
hw_PortC                = $0082                             ; $0082: FF  ; Hardware PortC register. Directly drives Denise JOY1DAT for joystick quadrature lines. Active-low
hw_PortD                = $0083                             ; $0083: FF  ; Hardware PortD register. Directly drives Denise JOY0DAT for mouse quadrature lines. Active-low
hw_UpperLatchWO         = $0084                             ; $0084: FF  ; Only ever written 0
hw_LowerLatchWO         = $0085                             ; $0085: FF  ; Only ever written 0x8C (140)
hw_UpperCountRO         = $0086                             ; $0086: FF  ; Not used
hw_LowerCountRO         = $0087                             ; $0087: FF  ; Not used
hw_TransferWO           = $0088                             ; $0088: FF  ; Transfer latches to counter & start timer (WO, typically write 0x00) | Atomically: (1) Store to Upper Latch, (2) Copy latches→counter, (3) Begin countdown
hw_PosEdgeDetectedWO    = $0089                             ; $0089: FF  ; Clear PA0 edge flag (WO) — UNUSED: Edge interrupts disabled
hw_NegEdgeDetectedWO    = $008A                             ; $008A: FF  ; Clear PA1 edge flag (WO) — UNUSED: Edge interrupts disabled
hw_ControlRegister      = $008F                             ; $008F: FF  ; 00001 0000 = Counter interrupt ENABLED

; ────────────────────────────────────────────────────────────────────────────
; ROM  $0800-$0FFF
; ────────────────────────────────────────────────────────────────────────────

                        .org $0800


; ────────────────────────────────────────────────────────────────────────────
; RES (0x0800)
; Purpose: Cold-start initialisation. Clears zero-page RAM, configures I/O
; ports, starts the interval timer, seeds the edge detector, and enters
; the main processing loop.
; Outputs:
; S = 0x3F (top of 6500/1 zero-page stack)
; All zero-page RAM (0x00-0x3F) cleared
; PortA/B = 0x0F, PortC/D = 0xFF (idle)
; Interval timer running (140 t-state latch, CIE enabled)
; Interrupts enabled (CLI)
; Timing: IRQ fires every ~163 t-states (140 latch + 23 overhead) = ~108.7 us.
; Ref: MOS 6500/1 datasheet, interval timer section.
; ────────────────────────────────────────────────────────────────────────────
RES:
                        SEI                                 ; $0800: 78  ; Disable interrupts during hardware setup
                        CLD                                 ; $0801: D8  ; Clear decimal mode (unpredictable at power-on per datasheet)
                        LDX             #$3F                ; $0802: A2 3F  ; X = 0x3F: loop counter and initial stack pointer value
                        TXS                                 ; $0804: 9A  ; Set SP to 0x3F (6500/1 stack is in zero-page, not page 1)
                        LDA             #$00                ; $0805: A9 00  ; A = 0x00: value to write during zero-page clear loop

; Clear all 64 bytes of zero-page RAM (0x3F down to 0x00). X counts downward; BPL loops while X >= 0.
Loop_PageZero:
                        STA             zp_StackBase,X      ; $0807: 95 00  ; Write 0x00 to zero-page[X], clearing this RAM location
                        DEX                                 ; $0809: CA  ; Move to next lower address
                        BPL             Loop_PageZero       ; $080A: 10 FB  ; Loop while X >= 0; exits when DEX from 0 gives 0xFF (N=1)

; Configure I/O ports. PortA/B = 0x0F (lower nibble high = idle inputs). PortC/D = 0xFF (all inactive).
                        LDA             #$0F                ; $080C: A9 0F  ; A = 0x0F: PA0-3 idle high, PB0-3 idle
                        STA             zp_PortA            ; $080E: 85 00  ; Init PortA shadow to idle
                        STA             hw_PortA            ; $0810: 85 80  ; Write idle to hw_PortA
                        STA             zp_PortB            ; $0812: 85 01  ; Init PortB shadow (CPCP=0, AUS idle)
                        STA             hw_PortB            ; $0814: 85 81  ; Write idle to hw_PortB

                        LDA             #$FF                ; $0816: A9 FF  ; A = 0xFF: all active-low lines deasserted
                        STA             zp_PortD            ; $0818: 85 02  ; Init PortD shadow (mouse port) to inactive
                        STA             hw_PortD            ; $081A: 85 83  ; Write inactive to hw_PortD
                        STA             zp_PortC            ; $081C: 85 03  ; Init PortC shadow (joystick port) to inactive
                        STA             hw_PortC            ; $081E: 85 82  ; Write inactive to hw_PortC

                        STA             zp_StatusCheck      ; $0820: 85 22  ; Init status sentinel to 0xFF; blocks IR dispatch until first cycle

; Configure 6500/1 interval timer. Latch=140, upper=0. Writing hw_TransferWO starts the counter. CIE bit enables IRQ.
                        LDA             #$8C                ; $0822: A9 8C  ; A = 140 (0x8C): counter reload value (~93 us period)
                        STA             hw_LowerLatchWO     ; $0824: 85 85  ; Write 140 to lower latch (0x85)
                        LDA             #$00                ; $0826: A9 00  ; A = 0: upper latch (period fits in 8 bits)
                        STA             hw_UpperLatchWO     ; $0828: 85 84  ; Write 0 to upper latch (0x84)
                        STA             hw_TransferWO       ; $082A: 85 88  ; Write to transfer reg (0x88): loads latch, starts counter
                        LDA             #$10                ; $082C: A9 10  ; A = 0x10: bit 4 = Counter Interrupt Enable (CIE)
                        STA             hw_ControlRegister  ; $082E: 85 8F  ; Write to control reg (0x8F): enable counter overflow IRQ

; Seed edge detector with idle state so first loop iteration has a valid baseline.
                        LDA             #$09                ; $0830: A9 09  ; A = 0x09: PA0(IRDT) + PA3(PRDT) high = idle
                        STA             zp_IRPR_ActiveFlags ; $0832: 85 19  ; Seed active-flags with idle baseline for edge detection
                        CLI                                 ; $0834: 58  ; Enable interrupts; timer running, IRQ handler ready

; ────────────────────────────────────────────────────────────────────────────
; Loop_Main (0x0835)
; Purpose: Central dispatch loop. Calls six stages per iteration then restarts.
; Stages:
; 1. f_ProcessIRAndKeyboardEvents  — sample IR/keyboard, flag events
; 2. f_ProcessIREvent              — decode raw IR pulse data
; 3. f_ProcessIRDataAndSetFlags    — verify checksums, extract fields
; 4. f_JumpTableDispatcher         — route to mouse/joy/kbd handler
; 5. f_WriteAllPorts               — flush port shadows to hardware
; 6. f_ProcessKeyboard             — wired keyboard/media, clear flags
; Timing: ~200-2000 us per iteration depending on IR/keyboard activity.
; ────────────────────────────────────────────────────────────────────────────

; Main execution loop — entered immediately after CLI. Calls each processing function in turn then loops back. The counter IRQ fires every 163 t-states (~109 µs) throughout.
Loop_Main:
                        JSR             f_ProcessIRAndKeyboardEvents; $0835: 20 4A 08  ; Stage 1: sample IR/keyboard lines, set event flags
                        JSR             f_ProcessIREvent    ; $0838: 20 56 0A  ; Stage 2: decode raw IR pulses into shift registers
                        JSR             f_ProcessIRDataAndSetFlags; $083B: 20 61 0C  ; Stage 3: verify frame checksums, extract fields
                        JSR             f_JumpTableDispatcher; $083E: 20 FE 0C  ; Stage 4: route to mouse/joystick/keyboard handler
                        JSR             f_WriteAllPorts     ; $0841: 20 0B 0E  ; Stage 5: flush port shadows to hardware (guarded)
                        JSR             f_ProcessKeyboard   ; $0844: 20 25 0E  ; Stage 6: wired keyboard/media events, clear flags
                        JMP             Loop_Main           ; $0847: 4C 35 08  ; Restart main loop unconditionally

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessIRAndKeyboardEvents (0x084A)
; Purpose: Core input handler. Discriminates IR, wired, and keyboard protocols,
; acquires data, and sets event flags for downstream processing.
; Inputs: hw_PortA, zp_PeripheralDataReady, zp_IREventFlag, IRQ counter
; Outputs: zp_PortC/D (quadrature), zp_IRCommandByte, zp_KeyboardIndex,
; zp_IRInputReady bit 7
; Protocol mask (set at 0x08C8):
; 0x01 = IR (PA0/IRDT), 0x08 = wired (PA3/PRDT), 0x06 = keyboard (PA1+PA2)
; Timing thresholds (per IRQ tick ~163 t-states):
; Header: 58-250, Repeat space: 13-30, Full space: 38-50
; Short mark: 1-7, Long mark: 9-25, Bit period: 13-47
; BIT tricks at: 0x08C5, 0x0991, 0x0A1B, 0x0A2B, 0x0A43
; Called from: Loop_Main (every iteration)
; ────────────────────────────────────────────────────────────────────────────
f_ProcessIRAndKeyboardEvents:
                        LDA             zp_PeripheralDataReady; $084A: A5 23  ; Check if previous peripheral data needs PortD cleanup
                        BEQ             ResetInputParameters; $084C: F0 04  ; Skip PortD reset if no data pending from previous frame
                        LDA             #$FF                ; $084E: A9 FF  ; A = 0xFF: clear stale mouse/joystick quadrature state
                        STA             zp_PortD            ; $0850: 85 02  ; Reset PortD shadow to idle, prevent phantom movements

; Clear event flags and counters for a fresh detection cycle. IRQ counter starts at 1 (not 0) to avoid false timeout.
ResetInputParameters:
                        LDX             #$00                ; $0852: A2 00  ; X = 0: used to clear multiple flags efficiently
                        STX             zp_IREventFlag      ; $0854: 86 0F  ; Clear event flags for fresh detection
                        STX             zp_IRQCount_MSB     ; $0856: 86 11  ; Reset IRQ counter MSB
                        STX             zp_PeripheralDataReady; $0858: 86 23  ; Clear peripheral-ready semaphore
                        INX                                 ; $085A: E8  ; X = 1 (saves a byte vs LDA #1)
                        STX             zp_IRQCount_LSB     ; $085B: 86 10  ; Start IRQ counter at 1 to avoid immediate false timeout
                        LDA             zp_IRInputReady     ; $085D: A5 16  ; Check if previous IR data still awaits main loop commit
                        AND             #$80                ; $085F: 29 80  ; Isolate bit 7 (data-ready flag)
                        STA             zp_IRInputReady     ; $0861: 85 16  ; Keep data-ready, clear protocol state bits 0-6
                        LDA             zp_PortA            ; $0863: A5 00  ; Read PortA shadow for idle assertion
                        ORA             #$09                ; $0865: 09 09  ; Force PA0 (IRDT) and PA3 (PRDT) high for idle baseline
                        STA             zp_PortA            ; $0867: 85 00  ; Update shadow with forced-idle state
                        STA             hw_PortA            ; $0869: 85 80  ; Write idle to hw_PortA before edge sampling
                        JSR             f_DetectInputEdges  ; $086B: 20 DB 0B  ; First edge detect: establish baseline for change detect

; Timeout and periodic refresh loop. Polls for IR/keyboard activity using a 9-bit counter (MSB bit0 : LSB).
; When it wraps to zero (~512 IRQs / ~56 ms), refreshes all ports to idle and clears the CPCP nibble.
; This implicit key-up is the ONLY release mechanism for CPCP media commands.
WaitForToggle:
                        LDA             zp_IRQCount_MSB     ; $086E: A5 11  ; Load IRQ counter MSB for periodic refresh check
                        AND             #$01                ; $0870: 29 01  ; Extract bit 0 of MSB for 9-bit counter window
                        ORA             zp_IRQCount_LSB     ; $0872: 05 10  ; Combine with full LSB: zero every 512 IRQs (~56 ms)
                        BNE             SkipInitialise      ; $0874: D0 34  ; Skip refresh unless 9-bit counter wrapped to zero

; Periodic port refresh (~512 IRQs / ~83ms):
; Writes 0x0F to portB — clears CPCP nibble (PB7:4=0x0).
; The U62 interprets CPCP=0 as key-up, completing the press/release cycle
; for any media key that was previously latched.
; This is the ONLY key-up mechanism for CPCP commands — there is no explicit
; IR key-up command. The release is implicit in the next periodic refresh
                        LDA             #$0F                ; $0876: A9 0F  ; Periodic PortB reset: 0x0F clears CPCP nibble (key-up)
                        STA             zp_PortB            ; $0878: 85 01  ; Update PortB shadow
                        STA             hw_PortB            ; $087A: 85 81  ; Flush to hw_PortB: U62 sees CPCP=0 as key-up
                        LDA             #$FF                ; $087C: A9 FF  ; A = 0xFF: inactive for joystick/mouse ports
                        STA             hw_PortC            ; $087E: 85 82  ; Refresh hw_PortC to inactive
                        STA             zp_PortC            ; $0880: 85 03  ; Update PortC shadow to match

; Periodic PortD refresh. WARNING: if f_AcquireIRBits ran since last f_WriteAllPorts, zp_PortD holds quadrature-encoded IR data, not a valid idle state.
                        LDA             zp_PortD            ; $0882: A5 02  ; Load PortD shadow (may hold stale quadrature data)
                        ORA             #$F0                ; $0884: 09 F0  ; Force upper nibble high; lower nibble as-is
                        STA             zp_PortD            ; $0886: 85 02  ; Update shadow with masked value
                        STA             hw_PortD            ; $0888: 85 83  ; Write to hw_PortD (garbled if IR clobbered shadow)
                        LDA             zp_Remote_NP_Media  ; $088A: A5 13  ; Check for pending remote control events
                        LSR             A                   ; $088C: 4A  ; Shift numpad flag (bit 0) into carry
                        BCS             ProcessNumPad       ; $088D: B0 0C  ; Numpad event pending: branch to handler
                        LDA             zp_Remote_NP_Media  ; $088F: A5 13  ; Re-read for media key check (bit 1)
                        AND             #$02                ; $0891: 29 02  ; Isolate media key flag

; Dead branch: bit 1 of zp_Remote_NP_Media is never set by any firmware path. The three writers (0x08A4, 0x0E72, 0x0E90) only store 0x00 or 0x01. Vestigial media dispatch from an earlier firmware revision.
                        BEQ             ResetRemoteValues   ; $0893: F0 0B  ; Always branches (bit 1 never set). 0x0895-0x0898 unreachable

; ────────────────────────────────────────────────────────────────────────────
; Dead Code Note — 0x0895-0x0898
; This JSR f_ProcessKeyboardEvent and the following JMP ResetRemoteValues are unreachable.
; The branch at 0x0893 (BEQ ResetRemoteValues) tests zp_Remote_NP_Media bit 1, but that
; bit is never set by any execution path in the firmware. The three writers of 0x13 are:
; 0x08A4 — STA 0 (clear on each periodic refresh)
; 0x0E72 — STA 0 (clear after media key dispatch)
; 0x0E90 — STA A, where A is always 0x00 or 0x01 (press/release flag for numpad)
; Bit 1 (value 0x02) is never stored. This appears to be a vestigial media key dispatch
; path, possibly intended for a media transport key that was later routed through the CPCP
; mechanism (f_MediaKeyCPCP at 0x0D88) instead of the keyboard scancode path.
; ────────────────────────────────────────────────────────────────────────────
                        JSR             f_ProcessKeyboardEvent; $0895: 20 0E 0F  ; DEAD CODE: would call f_ProcessKeyboardEvent
                        JMP             ResetRemoteValues   ; $0898: 4C A0 08  ; DEAD CODE: would jump to ResetRemoteValues
ProcessNumPad:
                        LDA             #$00                ; $089B: A9 00  ; A = 0: key press parameter (not release)
                        JSR             f_ProcessNumbPad    ; $089D: 20 90 0E  ; Send numpad keycode to host via serial interface

; Reset state for next detection cycle. Clears keyboard temp, remote flags, and prior modifier/key values.
ResetRemoteValues:
                        LDA             #$00                ; $08A0: A9 00  ; A = 0: clear value for multiple registers
                        STA             zp_KB_Temp          ; $08A2: 85 12  ; Clear keyboard temp (disable repeat-range test)
                        STA             zp_Remote_NP_Media  ; $08A4: 85 13  ; Clear remote event flags
                        STA             zp_ModifierIndexPrior; $08A6: 85 14  ; Clear previous modifier state (forces re-detection)
Bit_Trick:
                        STA             zp_KeyboardIndexPrior; $08A8: 85 15  ; Clear previous key index
SkipInitialise:
                        LDA             zp_StatusCheck      ; $08AA: A5 22  ; Check status sentinel: non-zero blocks IR dispatch
IRCheckIdle:
                        BNE             IRCheckIdle_PostKB  ; $08AC: D0 03  ; Skip IR processing if sentinel set (prevents re-entry)
                        JSR             f_CheckIRInputProcessed; $08AE: 20 C2 0A  ; Check if previous IR frame still being processed

; Second edge detection call this iteration. First at 0x086B set the baseline; this captures the final state.
IRCheckIdle_PostKB:
                        JSR             f_DetectInputEdges  ; $08B1: 20 DB 0B  ; Compute final activation/deactivation edges
                        JSR             f_ProcessFrontPanel ; $08B4: 20 FC 0B  ; Check front panel media buttons for state changes
                        LDA             zp_IRPR_ActivationEdge; $08B7: A5 1A  ; Read newly activated input lines
                        AND             #$09                ; $08B9: 29 09  ; Mask for IRDT (bit 0) and PRDT (bit 3) only
                        BEQ             WaitForToggle       ; $08BB: F0 B1  ; No IR/wired edge: loop back and keep waiting
                        LDA             zp_IRPR_ActivationEdge; $08BD: A5 1A  ; Re-read activation edges for protocol discrimination
                        AND             #$08                ; $08BF: 29 08  ; Isolate PRDT (bit 3) for wired vs IR test
                        BNE             PRDT_active+1       ; $08C1: D0 03  ; PRDT active: wired peripheral path (BIT trick)
                        LDA             #$01                ; $08C3: A9 01  ; IR protocol: mask = 0x01 (PA0 only)

; BIT trick: 3 bytes at 0x08C5 encode BIT $08A9. IR path (A=0x01) falls through. Wired path (BNE from 0x08C1 lands at 0x08C6) sees LDA #0x08.
PRDT_active:
                        BIT             Bit_Trick+1         ; $08C5: 2C A9 08  ; BIT trick: hides LDA #0x08 for wired path
                        STA             zp_ProtocolMask     ; $08C8: 85 06  ; Store protocol mask (0x01=IR, 0x08=wired)
                        JSR             f_ResetPulseTimer   ; $08CA: 20 2E 0C  ; Reset pulse timer before header mark measurement

; Peripheral line stabilisation. Polls up to 32 times (~4.5 ms) for the protocol line to go idle before acquisition.
                        LDX             #$20                ; $08CD: A2 20  ; X = 32: max iterations for line stabilisation
WaitKBStatus:
                        LDA             hw_PortA            ; $08CF: A5 80  ; Sample hw_PortA for active protocol line
                        AND             zp_ProtocolMask     ; $08D1: 25 06  ; Mask to protocol line (PA0 or PA3)
                        BNE             SkipInitialise      ; $08D3: D0 D5  ; Line idle: exit wait, begin header validation
                        DEX                                 ; $08D5: CA  ; Decrement stabilisation counter
                        BNE             WaitKBStatus        ; $08D6: D0 F7  ; Keep waiting for stabilisation or timeout

; NEC-like header mark validation. Wait for mark to end, then validate against table index 10 (Protocol 2: 6-19 ticks) or 0 (NEC: 58-250 ticks).
IRWaitLoop:
                        LDA             zp_IREventFlag      ; $08D8: A5 0F  ; Check IRQ timeout flag (bit 0)
                        LSR             A                   ; $08DA: 4A  ; Shift timeout flag into carry
                        BCS             SetIREventFlag      ; $08DB: B0 38  ; Timeout: header mark too long. Abort
                        LDA             hw_PortA            ; $08DD: A5 80  ; Sample PortA: has header mark ended?
                        EOR             #$09                ; $08DF: 49 09  ; XOR 0x09: result non-zero while either line active
                        AND             zp_ProtocolMask     ; $08E1: 25 06  ; Mask to monitored protocol line
                        BNE             IRWaitLoop          ; $08E3: D0 F3  ; Mark still active: keep waiting
                        LDX             #$0A                ; $08E5: A2 0A  ; X = 10: Protocol 2 header timing window (6-19 ticks)
                        JSR             f_ValidatePulseTiming; $08E7: 20 3B 0C  ; Validate against Protocol 2 range
                        BEQ             f_P2AcquireFrame    ; $08EA: F0 4C  ; Valid P2 header: branch to wired frame acquisition
                        LDX             #$00                ; $08EC: A2 00  ; P2 failed; X = 0: test NEC range (58-250 ticks)
                        JSR             f_ValidatePulseTiming; $08EE: 20 3B 0C  ; Validate against NEC-like range
                        BNE             SetIREventFlag      ; $08F1: D0 22  ; Neither range matched: abort

; Header mark valid (NEC-like). Measure the header space to discriminate full frame (~4500 us / 38-50 ticks) from repeat (~2250 us / 13-30 ticks). zp_KB_Temp bit 0 selects which range to test first.
                        JSR             f_ResetPulseTimer   ; $08F3: 20 2E 0C  ; Reset pulse timer for header space measurement
IRWaitLoop2:
                        LDA             zp_IREventFlag      ; $08F6: A5 0F  ; Poll for timeout during header space
                        LSR             A                   ; $08F8: 4A  ; Shift timeout flag into carry
                        BCS             SetIREventFlag      ; $08F9: B0 1A  ; Timeout: abort
                        LDA             hw_PortA            ; $08FB: A5 80  ; Sample PortA: has space ended?
                        AND             zp_ProtocolMask     ; $08FD: 25 06  ; Mask to protocol line
                        BNE             IRWaitLoop2         ; $08FF: D0 F5  ; Space ongoing: keep waiting

; After the header mark is validated, the firmware enters this loop to wait for
; the header space to end (PA0 goes low again), then measures its duration.
; A full NEC frame has a ~4500µs header space (~32 ticks at 140µs/tick).
; A NEC repeat frame has a ~2250µs header space (~16–20 ticks).
; zp_KB_Temp bit0 determines which timing range to test first:
; bit0 = 1 → test X=2 (range 13–30 ticks, ~1820–4200µs) — picks up repeat space
; bit0 = 0 → test X=4 (range 38–50 ticks, ~5320–7000µs) — full-frame space only
; Header space range discriminator: tests repeat range first if zp_KB_Temp bit 0 is set
                        LDA             zp_KB_Temp          ; $0901: A5 12  ; Load KB_Temp: bit 0 selects range test order
                        LSR             A                   ; $0903: 4A  ; Shift bit 0 into carry
                        BCC             CheckRange2         ; $0904: 90 07  ; Cold start: skip repeat test, go to full-frame range
                        LDX             #$02                ; $0906: A2 02  ; X = 2: repeat space range (13-30 ticks)
                        JSR             f_ValidatePulseTiming; $0908: 20 3B 0C  ; Validate against repeat range
                        BEQ             IRWaitNext          ; $090B: F0 0B  ; Matches repeat: handle repeat frame

; Repeat range failed (space > 30 ticks). Re-test against full-frame space range.
CheckRange2:
                        LDX             #$04                ; $090D: A2 04  ; Repeat failed; X = 4: full-frame range (38-50 ticks)
                        JSR             f_ValidatePulseTiming; $090F: 20 3B 0C  ; Validate against full-frame range
                        BNE             SetIREventFlag      ; $0912: D0 01  ; Neither range: abort
                        RTS                                 ; $0914: 60  ; Full-frame header valid: return for payload decode
SetIREventFlag:
                        JMP             f_SetIREventFlagJump; $0915: 4C 4F 0A  ; Flag error and abandon acquisition

; ────────────────────────────────────────────────────────────────────────────
; f_RepeatFramePath (0x0918)
; Purpose: Handle NEC repeat frame (9 ms mark + 2.25 ms space + stop mark).
; Sets IREventFlag bit 1 to signal repeat to MouseQuadraturePath.
; No shift-register update, no scancode, no port change.
; Inputs: hw_PortA (per zp_ProtocolMask), zp_IREventFlag bit 0
; Outputs: zp_IREventFlag bit 1 set
; Side effects: 256-NOP guard delay (~1.4 ms) prevents immediate re-entry.
; Prerequisite: zp_KB_Temp bit 0 must be set by a preceding full frame.
; ────────────────────────────────────────────────────────────────────────────
IRWaitNext:
                        JSR             f_ResetPulseTimer   ; $0918: 20 2E 0C  ; Reset pulse timer for stop mark measurement
AnotherIRWait:
                        LDA             zp_IREventFlag      ; $091B: A5 0F  ; Check timeout flag
                        LSR             A                   ; $091D: 4A  ; Shift bit 0 into carry
                        BCS             SetIREventFlag      ; $091E: B0 F5  ; Timeout: abort
                        LDA             hw_PortA            ; $0920: A5 80  ; Sample PortA: has stop mark ended?
                        AND             zp_ProtocolMask     ; $0922: 25 06  ; Mask to protocol line
                        BEQ             AnotherIRWait       ; $0924: F0 F5  ; Stop mark still active: keep waiting

; Stop mark ended. 256-NOP guard delay (~2048 cycles / ~1.4 ms) prevents immediate re-entry before line settles.
                        LDX             #$00                ; $0926: A2 00  ; X = 0: 256-iteration guard delay
NopDelayLoop:
                        NOP                                 ; $0928: EA  ; NOP padding for timing
                        NOP                                 ; $0929: EA  ; NOP padding
                        NOP                                 ; $092A: EA  ; NOP padding
                        DEX                                 ; $092B: CA  ; Decrement guard counter
                        BNE             NopDelayLoop        ; $092C: D0 FA  ; Loop until delay complete

; Record repeat event. Bit 7 already set (active). Add bit 1 for downstream MouseQuadraturePath (0x0D94).
                        LDA             zp_IREventFlag      ; $092E: A5 0F  ; Load IREventFlag (bit 7 already set)
                        ORA             #$02                ; $0930: 09 02  ; Set bit 1: valid NEC repeat received
                        STA             zp_IREventFlag      ; $0932: 85 0F  ; Store updated flag
                        RTS                                 ; $0934: 60  ; Return: repeat processed, no scancode/port change

; ────────────────────────────────────────────────────────────────────────────
; DEAD CODE — no caller targets this address. Sits immediately after RTS at $0934 inside f_RepeatFramePath. The JMP to $08AA (f_ProcessIRAndKeyboardEvents re-entry) is structurally unreachable. Confirmed by exhaustive branch/jump search of the entire ROM: zero references found.
; ────────────────────────────────────────────────────────────────────────────
                        JMP             SkipInitialise      ; $0935: 4C AA 08  ; DEAD — unreachable after RTS at $0934; no caller; JMP $08AA never executes

; ────────────────────────────────────────────────────────────────────────────
; f_P2AcquireFrame (0x0938)
; Purpose: Acquire one complete Protocol 2 frame (wired joystick, mouse, Brick)
; from PA0 or PA3. Three phases:
; 1. 3-bit discriminator: device type + button bits
; bit2=0: mouse (10 more bits). bit2=1: joystick (16 more bits)
; 2. Data bit loop: mark/space measurement with validation
; 3. Port decode: extract buttons/direction into PortC/PortD
; Inputs: zp_ProtocolMask, zp_IREventFlag bit 0, hw_PortA
; Outputs: zp_PortC (JOY2), zp_PortD (JOY1), zp_PeripheralDataReady
; Timing: mark 0 ~150 us, mark 1 ~500 us; space 0 ~725 us, space 1 ~375 us
; ────────────────────────────────────────────────────────────────────────────
f_P2AcquireFrame:
                        JSR             f_ResetPulseTimer   ; $0938: 20 2E 0C  ; Reset pulse timer for start space measurement

; Wait for protocol line to go high (start space ends). Timeout aborts.
WaitForStartSpaceEnd:
                        LDA             zp_IREventFlag      ; $093B: A5 0F  ; Check for timeout during start space
                        LSR             A                   ; $093D: 4A  ; Shift timeout flag into carry
                        BCS             SetIREventFlag      ; $093E: B0 D5  ; Timeout: abort
                        LDA             hw_PortA            ; $0940: A5 80  ; Sample PortA: is space still active?
                        AND             zp_ProtocolMask     ; $0942: 25 06  ; Mask to protocol line
                        BNE             WaitForStartSpaceEnd; $0944: D0 F5  ; Space ongoing: keep waiting
                        LDX             #$0C                ; $0946: A2 0C  ; X = 12: Protocol 2 start space range (1-6 ticks)
                        JSR             f_ValidatePulseTiming; $0948: 20 3B 0C  ; Validate start space duration
                        BNE             SetIREventFlag      ; $094B: D0 C8  ; Out of range: not Protocol 2. Abort
                        LDA             #$00                ; $094D: A9 00  ; A = 0: clear shift register
                        STA             zp_KB_ShiftRegister ; $094F: 85 2D  ; Clear shift register for 3-bit header
                        LDY             #$03                ; $0951: A0 03  ; Y = 3: read 3 header bits (device, RMB, LMB)

; 3-bit header read loop. Reads device type (bit 18), RMB (bit 17), LMB (bit 16) into zp_KB_ShiftRegister.
ReadInputLoop:
                        JSR             f_ProcessIRInput    ; $0953: 20 C9 0A  ; Sample PortA into 4 snapshot bytes
                        JSR             f_ResetPulseTimer   ; $0956: 20 2E 0C  ; Reset timer for this bit's mark duration
                        LDX             #$00                ; $0959: A2 00  ; X = 0: init mark-duration counter
                        JSR             f_TimingAnchorRTS   ; $095B: 20 78 0B  ; 12-cycle timing anchor before mark-count loop
HeaderMarkCountLoop:
                        INX                                 ; $095E: E8  ; Increment mark counter (~15 t-states/iteration)
HeaderMarkCountSample:
                        BEQ             SetIREventFlag      ; $095F: F0 B4  ; X=0 (wrapped): mark too long. Abort
                        LDA             hw_PortA            ; $0961: A5 80  ; Sample PortA: has mark ended?
                        AND             zp_ProtocolMask     ; $0963: 25 06  ; Mask to protocol line
                        BEQ             HeaderMarkCountLoop ; $0965: F0 F7  ; Mark active: keep counting
                        JSR             f_ValidatePulseDuration; $0967: 20 54 0B  ; Classify mark: 2-7=bit 0, 9-25=bit 1, else invalid
                        BMI             SetIREventFlag      ; $096A: 30 A9  ; Invalid duration: abort
                        STA             zp_BitValue         ; $096C: 85 2C  ; Store validated bit value (0 or 1)
                        JSR             f_ProcessIRInput    ; $096E: 20 C9 0A  ; Re-sample PortA for space-count phase
                        JSR             f_CountIdleSamples  ; $0971: 20 79 0B  ; Prime X with idle-sample count before space loop

; -- Wait for keyboard lines to return to idle state (all bits clear) --
HeaderSpaceCountLoop:
                        INX                                 ; $0974: E8  ; Increment cumulative mark+space counter
                        BEQ             SetIREventFlag      ; $0975: F0 9E  ; X=0 (wrapped): space too long. Abort
                        LDA             hw_PortA            ; $0977: A5 80  ; Sample PortA: has space ended?
                        AND             zp_ProtocolMask     ; $0979: 25 06  ; Mask to protocol line
                        BNE             HeaderSpaceCountLoop; $097B: D0 F7  ; Space active: keep counting
                        JSR             f_ValidateSpaceTiming; $097D: 20 6D 0B  ; Validate cumulative X: must be 13-47
                        BMI             SetIREventFlag      ; $0980: 30 93  ; Out of range: abort
                        LSR             zp_BitValue         ; $0982: 46 2C  ; Shift bit value into carry
                        ROL             zp_KB_ShiftRegister ; $0984: 26 2D  ; ROL carry into KB_ShiftRegister
                        DEY                                 ; $0986: 88  ; Decrement header bit counter
                        BNE             ReadInputLoop       ; $0987: D0 CA  ; More bits needed: loop back

; 3-bit read complete. KB_ShiftReg bit 2 = device type. 0=mouse (Y=10 more bits), 1=joystick (BIT trick loads Y=16).
                        LDA             zp_KB_ShiftRegister ; $0989: A5 2D  ; Load KB_ShiftReg to test device type bit
                        AND             #$04                ; $098B: 29 04  ; Test bit 2: 0=mouse, non-zero=joystick
                        BNE             SetTempD_Next       ; $098D: D0 03  ; Joystick: branch to BIT trick (loads Y=16)
                        LDY             #$0A                ; $098F: A0 0A  ; Mouse: Y = 10, read 10 more data bits

; NOTE: BIT trick corrected. Bytes at $0991: 2C A0 10. Branch target is $0992 = A0 10 = LDY #$10 (16 decimal). The BIT instruction at $0991 is a dummy read when execution falls through; the hidden LDY executes only when branched to at $0992 from $098D BNE.
                        BIT             $10A0               ; $0991: 2C A0 10  ; BIT trick: LDY #16 hidden in BIT $10A0 operand

; Data bit collection loop. Reads Y bits (10=mouse, 16=joystick) into {IRShift1:IRShift0} via mark/space measurement.
DataBitLoop:
                        JSR             f_ProcessIRInput    ; $0994: 20 C9 0A  ; Sample PortA for idle-count priming
                        LDX             #$00                ; $0997: A2 00  ; X = 0: reset mark counter
                        JSR             f_TimingAnchorRTS   ; $0999: 20 78 0B  ; 12-cycle timing anchor
DelayLoop:
                        INX                                 ; $099C: E8  ; Increment mark counter
                        BNE             DataMarkCheckEnd    ; $099D: D0 03  ; Skip timeout if X non-zero
                        JMP             f_SetIREventFlagJump; $099F: 4C 4F 0A  ; X=0: mark too long. Abort
DataMarkCheckEnd:
                        LDA             hw_PortA            ; $09A2: A5 80  ; Sample PortA: has mark ended?
                        AND             zp_ProtocolMask     ; $09A4: 25 06  ; Mask to protocol line
                        BEQ             DelayLoop           ; $09A6: F0 F4  ; Mark active: keep counting
                        JSR             f_ValidatePulseDuration; $09A8: 20 54 0B  ; Classify mark duration
                        BPL             StoreKeyValue       ; $09AB: 10 03  ; Valid (A>=0): store. Invalid (A=0xFF): abort
SetIREventFlagJump:
                        JMP             f_SetIREventFlagJump; $09AD: 4C 4F 0A  ; Invalid: abort
StoreKeyValue:
                        STA             zp_BitValue         ; $09B0: 85 2C  ; Store validated bit value
                        JSR             f_ProcessIRInput    ; $09B2: 20 C9 0A  ; Re-sample PortA for space phase
                        JSR             f_CountIdleSamples  ; $09B5: 20 79 0B  ; Prime X with idle count

; NOTE: X counter is cumulative across mark and space. f_ValidatePulseDuration (called at $09A8 after marking) receives mark-only count. f_ValidateSpaceTiming (called at $09C1 after spacing) receives mark+space count. This tightens the effective space timing window significantly.
DataSpaceCountLoop:
                        INX                                 ; $09B8: E8  ; Increment cumulative counter
                        BEQ             HeaderMarkCountSample; $09B9: F0 A4  ; X=0: space too long. Abort
                        LDA             hw_PortA            ; $09BB: A5 80  ; Sample PortA: has space ended?
                        AND             zp_ProtocolMask     ; $09BD: 25 06  ; Mask to protocol line
                        BNE             DataSpaceCountLoop  ; $09BF: D0 F7  ; Space active: keep counting
                        JSR             f_ValidateSpaceTiming; $09C1: 20 6D 0B  ; Validate cumulative X: 13-47
                        BMI             SetIREventFlagJump  ; $09C4: 30 E7  ; Out of range: abort
                        LDA             zp_BitValue         ; $09C6: A5 2C  ; Reload bit value
                        LSR             A                   ; $09C8: 4A  ; Shift into carry
                        ROL             zp_IRShift0         ; $09C9: 26 09  ; ROL into IRShift0; MSB exits to carry
                        ROL             zp_IRShift1         ; $09CB: 26 0A  ; Carry into IRShift1 (16-bit accumulation)
                        DEY                                 ; $09CD: 88  ; Decrement data bit counter
SetTempD_Next:
                        BNE             DataBitLoop         ; $09CE: D0 C4  ; More bits: loop back

; Port decode: extract buttons and direction from shift registers. Buttons from 3-bit header go to PortD upper nibble. Direction data to PortC and PortD lower nibbles. Both inverted to active-low via EOR.
                        LDA             zp_PortD            ; $09D0: A5 02  ; Load PortD shadow to preserve unmodified bits
                        AND             #$4F                ; $09D2: 29 4F  ; Clear button bits (PD4, PD5, PD7)
                        STA             zp_PortD            ; $09D4: 85 02  ; Store cleared shadow
                        LDA             zp_KB_ShiftRegister ; $09D6: A5 2D  ; Load KB_ShiftReg: bit0=LMB, bit1=RMB (wire state)
                        TAX                                 ; $09D8: AA  ; Save in X for framing check after button encode
                        AND             #$03                ; $09D9: 29 03  ; Isolate bits[1:0]: {RMB, LMB}
                        ASL             A                   ; $09DB: 0A  ; Shift button bits toward upper nibble (step 1/4)
                        ASL             A                   ; $09DC: 0A  ; ASL A — step 2
                        ASL             A                   ; $09DD: 0A  ; ASL A — step 3
                        ASL             A                   ; $09DE: 0A  ; Step 4: buttons now at PD5(RMB) and PD4(LMB)
                        ORA             zp_PortD            ; $09DF: 05 02  ; Merge button states into PortD upper nibble
                        STA             zp_PortD            ; $09E1: 85 02  ; Store merged value
                        TXA                                 ; $09E3: 8A  ; Restore KB_ShiftReg for framing check
                        AND             #$04                ; $09E4: 29 04  ; Test bit 2: must be 0 for valid mouse frame
                        BNE             P2AccumulateChannel ; $09E6: D0 26  ; Bit 2 set: framing error. Abort

; Quadrature transformation. Route V[3:0] and H[7:6] to PortC (JOY1DAT). Then right-shift by 6 to align V[7:4] into PortD (JOY0DAT). Invert to active-low.
                        LDA             zp_PortD            ; $09E8: A5 02  ; Reload PortD shadow (buttons in upper nibble)
                        AND             #$F0                ; $09EA: 29 F0  ; Clear lower nibble for direction insertion
                        STA             zp_PortD            ; $09EC: 85 02  ; Store cleared shadow
                        LDA             zp_IRShift0         ; $09EE: A5 09  ; Load IRShift0: bits[5:0] = {V3,V2,V1,V0,H7,H6}
                        AND             #$3F                ; $09F0: 29 3F  ; Isolate bits[5:0]
                        EOR             #$7F                ; $09F2: 49 7F  ; Invert to active-low for Denise JOY1DAT
                        STA             zp_PortC            ; $09F4: 85 03  ; Write to PortC shadow
                        LDX             #$06                ; $09F6: A2 06  ; X = 6: right-shift count to align V[7:4]
RotateShiftLoop:
                        LSR             zp_IRShift1         ; $09F8: 46 0A  ; LSR IRShift1: bit 0 exits to carry
                        ROR             zp_IRShift0         ; $09FA: 66 09  ; ROR IRShift0: carry enters bit 7
                        DEX                                 ; $09FC: CA  ; Decrement shift counter
                        BNE             RotateShiftLoop     ; $09FD: D0 F9  ; Loop until 6 shifts complete
                        LDA             zp_IRShift0         ; $09FF: A5 09  ; Load IRShift0: bits[3:0] = V[7:4]
                        AND             #$0F                ; $0A01: 29 0F  ; Isolate V[7:4]
                        ORA             zp_PortD            ; $0A03: 05 02  ; Merge into PortD lower nibble
                        EOR             #$3F                ; $0A05: 49 3F  ; Invert bits[5:0] to active-low for Denise
                        STA             zp_PortD            ; $0A07: 85 02  ; Write to PortD shadow
                        LDA             #$01                ; $0A09: A9 01  ; A = 1: set peripheral-ready flag
                        STA             zp_PeripheralDataReady; $0A0B: 85 23  ; Flag=1: next iteration resets PortD to 0xFF
                        RTS                                 ; $0A0D: 60  ; Return to main loop

; ────────────────────────────────────────────────────────────────────────────
; Wired-joystick quadrature delta accumulation (reached from $09E6 BNE).
; Entered only when a Protocol-2 frame arrives on PA3 (PRDT) and the 3-bit header discriminator identifies the frame as a joystick (KB_ShiftRegister bit 2 = 1).
; Mouse frames (bit 2 = 0) exit earlier via the quadrature encode path at $09E8.
; Two channels are accumulated separately:
; Channel 0: zp_PendingModifier0 ($001B) += zp_IRShift1 ($000A)
; Channel 1: zp_PendingModifier1 ($001C) += zp_IRShift0 ($0009)
; Each channel is then normalised to the range [-1 .. +1] using a pair of BIT tricks:
; Zero result     : BEQ skips both DEC and INC; value remains 0.
; Positive result : BPL branches into the BIT operand
; ────────────────────────────────────────────────────────────────────────────

; Modifier/scancode extraction from IR shift registers. Uses BIT tricks for conditional normalisation.
P2AccumulateChannel:
                        LDA             zp_PendingModifier0 ; $0A0E: A5 1B  ; Load accumulated channel-0 delta (zp_PendingModifier0) for joystick movement
                        CLC                                 ; $0A10: 18  ; Clear carry before 8-bit signed addition
                        ADC             zp_IRShift1         ; $0A11: 65 0A  ; Add IRShift1 (upper data byte from P2 joystick frame) to channel-0 accumulator
                        STA             zp_PendingModifier0 ; $0A13: 85 1B  ; Store updated channel-0 accumulator
                        BEQ             InputLowAdjusted    ; $0A15: F0 07  ; Zero result: no movement on channel 0; skip normalisation entirely
                        BPL             Label_InputLowPlus  ; $0A17: 10 03  ; Positive result: branch INTO BIT operand at $0A1C to execute INC PendingModifier0
                        DEC             zp_PendingModifier0 ; $0A19: C6 1B  ; Negative result: decrement accumulator toward -1 (normalise)
                        BIT             $1BE6               ; $0A1B: 2C E6 1B  ; BIT trick — executed only on negative path after DEC. Operand bytes $E6 $1B encode INC $1B which runs when BPL at $0A17 is taken (positive path); harmless dummy read otherwise
InputLowAdjusted:
                        LDA             zp_PendingModifier1 ; $0A1E: A5 1C  ; Load accumulated channel-1 delta (zp_PendingModifier1) for second joystick axis
                        CLC                                 ; $0A20: 18  ; Clear carry before signed addition
                        ADC             zp_IRShift0         ; $0A21: 65 09  ; Add IRShift0 (lower data byte from P2 joystick frame) to channel-1 accumulator
                        STA             zp_PendingModifier1 ; $0A23: 85 1C  ; Store updated channel-1 accumulator
                        BEQ             InputHighAdjusted   ; $0A25: F0 07  ; Zero result: no movement on channel 1; skip normalisation
                        BPL             InputHighPlus       ; $0A27: 10 03  ; Positive result: branch INTO BIT operand at $0A2C to execute INC PendingModifier1
                        DEC             zp_PendingModifier1 ; $0A29: C6 1C  ; Negative result: decrement accumulator toward -1
                        BIT             $1CE6               ; $0A2B: 2C E6 1C  ; BIT trick — same pattern as $0A1B but for channel 1 (PendingModifier1 / $001C)

; Modifier table reset and commit. Clear delta tables (0x20-0x21), commit from source (0x1B+X) to active (0x20+X), set IR_InputReady bit 7.
InputHighAdjusted:
                        LDA             #$00                ; $0A2E: A9 00  ; A = 0: clear modifier delta registers
                        STA             zp_QuadDelta0       ; $0A30: 85 20  ; Clear delta channel 0
                        STA             zp_QuadDelta1       ; $0A32: 85 21  ; Clear delta channel 1
                        STA             zp_IRQCount_LSB     ; $0A34: 85 10  ; Clear IRQ counter LSB (reset timing reference)
                        TAX                                 ; $0A36: AA  ; X = 0: index for first modifier table entry
                        JSR             f_CommitPendingModifierEntry; $0A37: 20 3B 0A  ; Commit modifier entry 0 to active table
                        INX                                 ; $0A3A: E8  ; X = 1: next modifier slot

; ────────────────────────────────────────────────────────────────────────────
; f_CommitPendingModifierEntry (0x0A3B)
; Purpose: Transfer pending modifier state from source (0x1B+X) to active
; (0x20+X) table, then set bit 7 of zp_IRInputReady.
; Normalisation: zero=skip, positive=as-is, negative=normalise to 1.
; Uses BIT trick at 0x0A43 to skip LDA #0xFF.
; ────────────────────────────────────────────────────────────────────────────
f_CommitPendingModifierEntry:
                        LDA             $1B,X               ; $0A3B: B5 1B  ; Load pending entry from source table[0x1B+X]
                        BEQ             SkipUpdate          ; $0A3D: F0 09  ; Zero: no change, skip to flag set
                        BPL             ProceedValue        ; $0A3F: 10 03  ; Positive (bit 7 clear): store as-is
                        LDA             #$01                ; $0A41: A9 01  ; Negative: normalise to 1 (key-pressed)
                        BIT             $FFA9               ; $0A43: 2C A9 FF  ; BIT trick: hides LDA #0xFF + STA
                        STA             $20,X               ; $0A46: 95 20  ; Store to active table[0x20+X]
SkipUpdate:
                        LDA             zp_IRInputReady     ; $0A48: A5 16  ; Load IR input ready flag
                        ORA             #$80                ; $0A4A: 09 80  ; Set bit 7: data ready for main loop
                        STA             zp_IRInputReady     ; $0A4C: 85 16  ; Store updated flag
                        RTS                                 ; $0A4E: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_SetIREventFlagJump (0x0A4F)
; Purpose: Set bit 0 of zp_IREventFlag to signal error/timeout.
; Called from any acquisition path on invalid pulse, framing error, or overflow.
; ────────────────────────────────────────────────────────────────────────────
f_SetIREventFlagJump:
                        LDA             zp_IREventFlag      ; $0A4F: A5 0F  ; Load event flags
                        ORA             #$01                ; $0A51: 09 01  ; Set bit 0: error/timeout
                        STA             zp_IREventFlag      ; $0A53: 85 0F  ; Store updated flags
WaitForFlagsClear:
                        RTS                                 ; $0A55: 60  ; Return with error flag set

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessIREvent (0x0A56)
; Purpose: Validate state, clear shift registers, acquire 4-bit NEC header,
; extract zp_IRHeaderNibble, set protocol-specific delay.
; Wire nibble -> zp_IRHeaderNibble -> handler:
; 0000 -> 0x0 -> f_ProcessMouse  (commands 0-255)
; 1000 -> 0x1 -> f_ProcessJoystick (commands 2048-2303)
; 0100 -> 0x2 -> f_ProcessKeyboardEvent (commands 1024-1279)
; Qualifier (0x2): sets IREventFlag bit 2 for 40-bit decode path.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessIREvent:
                        LDA             zp_IREventFlag      ; $0A56: A5 0F  ; Load event flags for state check
                        AND             #$03                ; $0A58: 29 03  ; Mask lower 2 bits: check for error/pending
                        ORA             zp_IRInputReady     ; $0A5A: 05 16  ; Combine with IR input ready
                        ORA             zp_PeripheralDataReady; $0A5C: 05 23  ; Combine with peripheral data ready
                        BNE             WaitForFlagsClear   ; $0A5E: D0 F5  ; Any flag set: wait until idle

; Clear 5-byte shift register (0x09-0x0D) for new IR data.
                        LDX             #$04                ; $0A60: A2 04  ; X = 4: start from highest byte
ClearIRShift:
                        STA             zp_IRShift4,X       ; $0A62: 95 09  ; Clear shift register byte[X]
                        DEX                                 ; $0A64: CA  ; Decrement index
                        BPL             ClearIRShift        ; $0A65: 10 FB  ; Loop until all 5 bytes zeroed

; ────────────────────────────────────────────────────────────────────────────
; IR Header Acquisition (0x0A67)
; Acquires the 4-bit protocol header from a 24-bit NEC frame.
; Each bit enters IRShift4 bit 7 via the ROR chain; after 4 RORs the
; nibble sits in bits[7:4]. Four LSRs move it to bits[3:0].
; Wire nibble (MSB-first) to zp_IRHeaderNibble:
; 0000 -> 0x0 -> f_ProcessMouse  (commands 0-255)
; 1000 -> 0x1 -> f_ProcessJoystick (commands 2048-2303)
; 0100 -> 0x2 -> f_ProcessKeyboardEvent (commands 1024-1279)
; For qualifier (0x2): bit 2 is set in zp_IREventFlag to signal the
; 40-bit decode path. IRHeaderNibble remains 0x2 for the dispatcher.
; ────────────────────────────────────────────────────────────────────────────

; Acquire 4-bit NEC header. Bits enter IRShift4 bit 7 via ROR chain. After 4 bits, 4 LSRs at 0x0A6E extract the nibble.
                        LDY             #$04                ; $0A67: A0 04  ; Y = 4: acquire 4 header bits
                        JSR             f_AcquireIRBits     ; $0A69: 20 8A 0A  ; Acquire bits with timing validation
                        LDA             zp_IRShift4         ; $0A6C: A5 0D  ; Load IRShift4: header nibble in bits[7:4]
                        LSR             A                   ; $0A6E: 4A  ; LSR 1/4: move nibble from [7:4] to [3:0]
                        LSR             A                   ; $0A6F: 4A  ; LSR 2 of 4
                        LSR             A                   ; $0A70: 4A  ; LSR 3 of 4
                        LSR             A                   ; $0A71: 4A  ; LSR 4/4: nibble now in bits[3:0]
                        STA             zp_IRHeaderNibble   ; $0A72: 85 0E  ; Store as zp_IRHeaderNibble: 0=mouse, 1=joy, 2=kbd
                        CMP             #$02                ; $0A74: C9 02  ; Test for qualifier protocol (0x2)
                        BNE             Std_Periph+1        ; $0A76: D0 03  ; Not qualifier: skip bit 2 set

; Qualifier path — entered only when zp_IRHeaderNibble = 0x2 (keyboard qualifier
                        LDA             #$04                ; $0A78: A9 04  ; A = 0x04: bit 2 set flag for 40-bit keyboard qualifier
Std_Periph:
                        BIT             $A9                 ; $0A7A: 2C A9 00  ; BIT trick — operand bytes $A9 $00 encode LDA #$00 for the standard path; qualifier path falls through here and then ORs bit 2 into IREventFlag at $0A7D
                        ORA             zp_IREventFlag      ; $0A7D: 05 0F  ; OR bit 2 into IREventFlag (qualifier) or 0 (standard)
                        STA             zp_IREventFlag      ; $0A7F: 85 0F  ; Store updated flag
                        AND             #$04                ; $0A81: 29 04  ; Test bit 2: qualifier=36-tick delay, standard=20
                        BNE             SkipAdditionalDelay ; $0A83: D0 03  ; Qualifier: skip standard delay
                        LDY             #$14                ; $0A85: A0 14  ; Y = 20: standard delay for mouse/joystick
                        BIT             $24A0               ; $0A87: 2C A0 24  ; BIT trick: hides LDY #36 for qualifier path

; ────────────────────────────────────────────────────────────────────────────
; f_AcquireIRBits (0x0A8A)
; Purpose: Read Y bits from IR signal with timing validation.
; Short mark (1-6 ticks) = bit 0. Long mark (7-12 ticks) = bit 1.
; Bits shift into IRShift0-4 via ROR chain (enters IRShift4 bit 7).
; BIT trick at 0x0AB2: CLC opcode (0x18) doubles as BIT operand.
; ────────────────────────────────────────────────────────────────────────────

; IR bit acquisition loop. Each bit: wait for mark start, wait for mark end, validate against short/long timing windows, shift into 5-byte register via ROR chain.
f_AcquireIRBits:
                        JSR             f_ResetPulseTimer   ; $0A8A: 20 2E 0C  ; Reset pulse timer for mark measurement
WaitForKeyboardSignalStart:
                        LDA             zp_IREventFlag      ; $0A8D: A5 0F  ; Check for timeout
                        LSR             A                   ; $0A8F: 4A  ; Shift timeout into carry
                        BCS             f_SetIREventFlagJump; $0A90: B0 BD  ; Timeout: abort
                        LDA             hw_PortA            ; $0A92: A5 80  ; Sample PortA: read IR line state
                        AND             zp_ProtocolMask     ; $0A94: 25 06  ; Mask to active line
WaitForPeriphMarkStart:
                        BEQ             WaitForKeyboardSignalStart; $0A96: F0 F5  ; Line inactive: waiting for mark to begin
WaitForKeyboardSignalEnd:
                        LDA             zp_IREventFlag      ; $0A98: A5 0F  ; Mark started: check for timeout during mark
                        LSR             A                   ; $0A9A: 4A  ; Shift timeout into carry
                        BCS             f_SetIREventFlagJump; $0A9B: B0 B2  ; Timeout during mark: abort
                        LDA             hw_PortA            ; $0A9D: A5 80  ; Re-sample: has mark ended?
                        AND             zp_ProtocolMask     ; $0A9F: 25 06  ; Mask to active line
WaitForPeriphMarkEnd:
                        BNE             WaitForKeyboardSignalEnd; $0AA1: D0 F5  ; Mark still active: keep waiting

; Mark ended. Validate against short (1-6 ticks) and long (7-12 ticks) windows. Short=carry clear. Long=carry set.
                        LDX             #$06                ; $0AA3: A2 06  ; X = 6: short pulse timing offset
                        JSR             f_ValidatePulseTiming; $0AA5: 20 3B 0C  ; Validate short range (1-6 ticks)
                        BEQ             AcceptKeyboardBit+1 ; $0AA8: F0 09  ; Short match: accept as bit 0 (BIT trick clears carry)
AcceptKeyboardBit_Long:
                        LDX             #$08                ; $0AAA: A2 08  ; X = 8: long pulse timing offset
                        JSR             f_ValidatePulseTiming; $0AAC: 20 3B 0C  ; Validate long range (7-12 ticks)
                        BNE             f_SetIREventFlagJump; $0AAF: D0 9E  ; Neither range: invalid. Abort
                        SEC                                 ; $0AB1: 38  ; Long valid: set carry (bit value = 1)
AcceptKeyboardBit:
                        BIT             zp_IRPR_RawDeactEdge; $0AB2: 24 18  ; BIT trick: CLC opcode as operand. Short=carry clear
                        ROR             zp_IRShift4         ; $0AB4: 66 0D  ; Rotate carry into IRShift4 bit 7
                        ROR             zp_IRShift3         ; $0AB6: 66 0C  ; Cascade through IRShift3
                        ROR             zp_IRShift2         ; $0AB8: 66 0B  ; Cascade through IRShift2
                        ROR             zp_IRShift1         ; $0ABA: 66 0A  ; Cascade through IRShift1
                        ROR             zp_IRShift0         ; $0ABC: 66 09  ; Complete into IRShift0 (LSB)
                        DEY                                 ; $0ABE: 88  ; Decrement bits remaining
                        BNE             f_AcquireIRBits     ; $0ABF: D0 C9  ; More bits: loop back
                        RTS                                 ; $0AC1: 60  ; All bits acquired: return

; ────────────────────────────────────────────────────────────────────────────
; f_CheckIRInputProcessed (0x0AC2)
; Purpose: Guard against re-entering f_ProcessIRInput in the same cycle.
; Returns immediately if zp_IRInputProcessed is non-zero.
; ────────────────────────────────────────────────────────────────────────────
f_CheckIRInputProcessed:
                        LDA             zp_IRInputProcessed ; $0AC2: A5 1F  ; Load processed flag
                        BNE             ReturnImmediately   ; $0AC4: D0 02  ; Already processed: return immediately
                        BEQ             ProcessIRInput      ; $0AC6: F0 06  ; Not processed: fall through to f_ProcessIRInput
ReturnImmediately:
                        RTS                                 ; $0AC8: 60  ; Early return for already-processed frames

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessIRInput (0x0AC9)
; Purpose: Critical-section handler for IR mouse/joystick data. Processes dual
; channels via f_ProcessInputState, applies XOR quadrature transform via lookup
; tables, updates PortD with next phase.
; WARNING: After 0x0AF0, zp_PortD holds quadrature-encoded IR data, not the
; value from f_WriteAllPorts. Periodic refresh at 0x0882 will write garbled
; state. Repeat frames avoid this by bypassing f_AcquireIRBits.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessIRInput:
                        LDA             zp_IRInputProcessed ; $0AC9: A5 1F  ; Check if already processed this cycle
                        BNE             AltProcessing       ; $0ACB: D0 3D  ; Already done: take 4-sample idle path instead
                        SEI                                 ; $0ACD: 78  ; SEI: enter critical section
ProcessIRInput:
                        TXA                                 ; $0ACE: 8A  ; Save peripheral index (X) to A
                        PHA                                 ; $0ACF: 48  ; Push X onto stack
                        LDX             #$00                ; $0AD0: A2 00  ; X = 0: first input channel
                        JSR             f_ProcessInputState ; $0AD2: 20 2D 0B  ; Update phase + distance for channel 0
                        LDX             #$01                ; $0AD5: A2 01  ; X = 1: second channel
                        JSR             f_ProcessInputState ; $0AD7: 20 2D 0B  ; Update phase + distance for channel 1
                        PLA                                 ; $0ADA: 68  ; Restore X from stack
                        TAX                                 ; $0ADB: AA  ; Transfer A back to X
                        LDA             hw_PortA            ; $0ADC: A5 80  ; Sample PortA for edge detection
                        STA             zp_ScratchC         ; $0ADE: 85 28  ; Store snapshot 1 into zp_ScratchC
                        STY             zp_PeriphTypeSave   ; $0AE0: 84 2A  ; Save peripheral type Y before quadrature clobbers it

; Quadrature XOR transform. Force lower nibble idle, XOR with X and Y lookup tables. Result stored to zp_PortD (WARNING: clobbers).
                        LDA             zp_PortD            ; $0AE2: A5 02  ; Load PortD shadow as basis for next phase
                        ORA             #$0F                ; $0AE4: 09 0F  ; Force lower nibble to 0xF (idle) before new phase
                        LDY             zp_QuadPhase0       ; $0AE6: A4 1D  ; Load X-axis phase index from zp_QuadPhase0
                        EOR             g_EorTableHigh,Y    ; $0AE8: 59 4C 0B  ; XOR with X-axis table: encode X direction
                        LDY             zp_QuadPhase1       ; $0AEB: A4 1E  ; Load Y-axis phase index from zp_QuadPhase1
                        EOR             $0C4F,Y             ; $0AED: 59 50 0B  ; XOR with Y-axis table: encode Y on top of X
                        STA             zp_PortD            ; $0AF0: 85 02  ; Write to PortD shadow (WARNING: clobbers idle state)
                        LDA             #$01                ; $0AF2: A9 01  ; A = 1: completion flag
                        STA             zp_IRInputProcessed ; $0AF4: 85 1F  ; Mark IR input as processed
                        LDY             zp_PeriphTypeSave   ; $0AF6: A4 2A  ; Restore peripheral type Y
                        LDA             hw_PortA            ; $0AF8: A5 80  ; Sample PortA for second snapshot
                        STA             zp_ScratchD         ; $0AFA: 85 29  ; Store snapshot 2 into zp_ScratchD
                        LDA             #$01                ; $0AFC: A9 01  ; Reload A = 1 (clobbered by PortA read)
                        STA             zp_IRInputProcessed ; $0AFE: 85 1F  ; Confirm processing complete
                        LDA             zp_PendingModifier0 ; $0B00: A5 1B  ; Test if any input data still pending
                        ORA             zp_PendingModifier1 ; $0B02: 05 1C  ; OR both channels: non-zero = still pending
                        BNE             StatusCheckContinue ; $0B04: D0 02  ; Pending: don't clear ready flag yet
                        STA             zp_IRInputReady     ; $0B06: 85 16  ; All consumed: clear IR ready flag
StatusCheckContinue:
                        CLI                                 ; $0B08: 58  ; CLI: exit critical section
                        RTS                                 ; $0B09: 60  ; Return

; Alternative path: frame already handled. 4-sample idle detection with TinyDelay spacing. No quadrature transform.
AltProcessing:
                        SEI                                 ; $0B0A: 78  ; SEI: critical section
                        TXA                                 ; $0B0B: 8A  ; Save X via A
                        PHA                                 ; $0B0C: 48  ; Push to stack

; 4-sample idle detection. Take 4 PortA snapshots with TinyDelay spacing into ScratchA-D.
                        LDA             hw_PortA            ; $0B0D: A5 80  ; Sample 1: read PortA
                        STA             zp_ScratchA         ; $0B0F: 85 26  ; Store snapshot 1 into zp_ScratchA
                        JSR             f_TinyDelay         ; $0B11: 20 46 0B  ; Stabilisation delay (~11 us)
                        LDA             hw_PortA            ; $0B14: A5 80  ; Sample 2: read PortA
                        STA             zp_ScratchB         ; $0B16: 85 27  ; Store snapshot 2 into zp_ScratchB
                        JSR             f_TinyDelay         ; $0B18: 20 46 0B  ; Stabilisation delay
                        LDA             hw_PortA            ; $0B1B: A5 80  ; Sample 3: read PortA
                        STA             zp_ScratchC         ; $0B1D: 85 28  ; Store snapshot 3 into zp_ScratchC
                        JSR             f_TinyDelay         ; $0B1F: 20 46 0B  ; Stabilisation delay
                        LDA             hw_PortA            ; $0B22: A5 80  ; Sample 4: read PortA
                        STA             zp_ScratchD         ; $0B24: 85 29  ; Store snapshot 4 into zp_ScratchD
                        JSR             f_TinyDelay         ; $0B26: 20 46 0B  ; Final delay
                        PLA                                 ; $0B29: 68  ; Restore X from stack
                        TAX                                 ; $0B2A: AA  ; Transfer back to X
                        CLI                                 ; $0B2B: 58  ; CLI: exit critical section
                        RTS                                 ; $0B2C: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessInputState (0x0B2D)
; Purpose: Update phase counter and distance accumulator for one channel.
; Called twice per IR cycle (X=0, X=1). Auto-disables channel on saturation.
; Timing: 27-29 cycles (18-19 us at 1.5 MHz)
; ────────────────────────────────────────────────────────────────────────────

; Snapshot PortA, then update phase counter (mod-4 Gray code) and distance accumulator for one channel.
f_ProcessInputState:
                        LDA             hw_PortA            ; $0B2D: A5 80  ; Load current PortA state
                        STA             $26,X               ; $0B2F: 95 26  ; Store snapshot: X=0->0x26, X=1->0x27

; Update 2-bit phase counter (modulo-4). Tracks Gray code: CW 0->1->3->2, CCW 0->2->3->1.
                        LDA             $1D,X               ; $0B31: B5 1D  ; Load 2-bit phase position
                        CLC                                 ; $0B33: 18  ; Clear carry
                        ADC             $20,X               ; $0B34: 75 20  ; Add signed delta: +1 fwd, 0xFF rev, 0 idle
                        AND             #$03                ; $0B36: 29 03  ; Mask to 2 bits (modulo-4 Gray code phase)
                        STA             $1D,X               ; $0B38: 95 1D  ; Store updated phase

; Update distance accumulator. Auto-disables channel (clears delta) when accumulator wraps to zero.
                        LDA             $1B,X               ; $0B3A: B5 1B  ; Load distance accumulator
                        CLC                                 ; $0B3C: 18  ; Clear carry
                        ADC             $20,X               ; $0B3D: 75 20  ; Add delta (accumulate total movement)
                        STA             $1B,X               ; $0B3F: 95 1B  ; Store updated accumulator
                        BNE             DispatchRTS         ; $0B41: D0 02  ; Non-zero: still active, exit
                        STA             $20,X               ; $0B43: 95 20  ; Saturated to zero: clear delta to halt channel
DispatchRTS:
                        RTS                                 ; $0B45: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_TinyDelay (0x0B46)
; Purpose: ~17 cycle delay (~11.3 us) between PortA samples during idle detection.
; ────────────────────────────────────────────────────────────────────────────
f_TinyDelay:
                        LDX             #$02                ; $0B46: A2 02  ; X = 2: two-iteration delay
TinyDelayLoop:
                        DEX                                 ; $0B48: CA  ; Decrement counter
                        BNE             TinyDelayLoop       ; $0B49: D0 FD  ; Loop for 17-cycle delay
                        RTS                                 ; $0B4B: 60  ; Return

; X-axis quadrature table (4 entries). Phase 0-3 to PortD pin pattern for XB1/XA1. Gray code: 10->00->01->11.
tbl_QuadratureX:
                        .byte           $08                 ; $0B4C: 08  ; Phase 0: 0x08 = 0b00001000 = XB1=1, XA1=0  →  Gray code: 10 (decimal 2)
                        .byte           $00                 ; $0B4D: 00  ; Phase 1: 0x00 = 0b00000000 = XB1=0, XA1=0  →  Gray code: 00 (decimal 0)
                        .byte           $02                 ; $0B4E: 02  ; Phase 2: 0x02 = 0b00000010 = XB1=0, XA1=1  →  Gray code: 01 (decimal 1)
                        .byte           $0A                 ; $0B4F: 0A  ; Phase 3: 0x0a = 0b00001010 = XB1=1, XA1=1  →  Gray code: 11 (decimal 3)

; Y-axis quadrature table (4 entries). Phase 0-3 for YA1/YB1. 90-degree shifted: 11->10->00->01.
tbl_QuadratureY:
                        .byte           $05                 ; $0B50: 05  ; Phase 0: 0x05 = 0b00000101 = YA1=1, YB1=1  →  Gray code: 11 (decimal 3)
                        .byte           $04                 ; $0B51: 04  ; Phase 1: 0x04 = 0b00000100 = YA1=1, YB1=0  →  Gray code: 10 (decimal 2)
                        .byte           $00                 ; $0B52: 00  ; Phase 2: 0x00 = 0b00000000 = YA1=0, YB1=0  →  Gray code: 00 (decimal 0)
                        .byte           $01                 ; $0B53: 01  ; Phase 3: 0x01 = 0b00000001 = YA1=0, YB1=1  →  Gray code: 01 (decimal 1)

; ────────────────────────────────────────────────────────────────────────────
; f_ValidatePulseDuration (0x0B54)
; Purpose: Classify mark-duration loop count X.
; X=0: invalid. X=1-7: A=0 (bit 0). X=8: invalid (dead zone).
; X=9-25: A=1 (bit 1). X>=26: invalid.
; Returns: A=0/1 valid (N clear), A=0xFF invalid (N set).
; ────────────────────────────────────────────────────────────────────────────
f_ValidatePulseDuration:
                        CPX             #$01                ; $0B54: E0 01  ; Lower bound: X=0 invalid
                        BCC             ReturnInvalid       ; $0B56: 90 12  ; X < 1: invalid
                        CPX             #$1A                ; $0B58: E0 1A  ; Upper bound: X >= 26 too long
                        BCS             ReturnInvalid       ; $0B5A: B0 0E  ; X >= 26: invalid
                        CPX             #$08                ; $0B5C: E0 08  ; X < 8: short mark
                        BCC             ReturnZero          ; $0B5E: 90 07  ; X 1-7: return A=0 (bit 0)
                        CPX             #$09                ; $0B60: E0 09  ; X=8: dead zone
                        BCC             ReturnInvalid       ; $0B62: 90 06  ; X=8: invalid
                        LDA             #$01                ; $0B64: A9 01  ; X 9-25: long mark, A=1 (bit 1)
                        RTS                                 ; $0B66: 60  ; Return A=1 (valid long)
ReturnZero:
                        LDA             #$00                ; $0B67: A9 00  ; Return A=0 (valid short)
                        RTS                                 ; $0B69: 60  ; Return
ReturnInvalid:
                        LDA             #$FF                ; $0B6A: A9 FF  ; A=0xFF: invalid duration sentinel
                        RTS                                 ; $0B6C: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_ValidateSpaceTiming (0x0B6D)
; Purpose: Validate cumulative mark+space count X.
; X<13: invalid. X=13-47: valid (A=0, Z set). X>=48: invalid.
; ────────────────────────────────────────────────────────────────────────────
f_ValidateSpaceTiming:
                        CPX             #$0D                ; $0B6D: E0 0D  ; X < 13: too short
                        BCC             ReturnInvalid       ; $0B6F: 90 F9  ; Invalid
                        CPX             #$30                ; $0B71: E0 30  ; X >= 48: too long
                        BCS             ReturnInvalid       ; $0B73: B0 F5  ; Invalid
                        LDA             #$00                ; $0B75: A9 00  ; A=0: valid (Z set)
                        RTS                                 ; $0B77: 60  ; Return
f_TimingAnchorRTS:
                        RTS                                 ; $0B78: 60  ; Bare RTS: 12-cycle timing anchor for mark-count loops

; ────────────────────────────────────────────────────────────────────────────
; f_CountIdleSamples (0x0B79)
; Purpose: Count how many of 4 PortA snapshots show the protocol line idle.
; Returns count in X (0-4). Primes the cumulative space-count X.
; Snapshots in: zp_ScratchA, zp_ScratchB, zp_ScratchC, zp_ScratchD.
; ────────────────────────────────────────────────────────────────────────────
f_CountIdleSamples:
                        LDA             zp_ScratchA         ; $0B79: A5 26  ; Load snapshot 1 from zp_ScratchA
                        AND             zp_ProtocolMask     ; $0B7B: 25 06  ; Test protocol line in snapshot 1
                        BEQ             ExitIdleCount       ; $0B7D: F0 16  ; Line active: stop counting
                        INX                                 ; $0B7F: E8  ; Idle: increment X
                        LDA             zp_ScratchB         ; $0B80: A5 27  ; Load snapshot 2 from zp_ScratchB
                        AND             zp_ProtocolMask     ; $0B82: 25 06  ; Test protocol line
                        BEQ             ExitIdleCount       ; $0B84: F0 0F  ; Active: stop
                        INX                                 ; $0B86: E8  ; Idle: increment
                        LDA             zp_ScratchC         ; $0B87: A5 28  ; Load snapshot 3 from zp_ScratchC
                        AND             zp_ProtocolMask     ; $0B89: 25 06  ; Test protocol line
                        BEQ             ExitIdleCount       ; $0B8B: F0 08  ; Active: stop
                        INX                                 ; $0B8D: E8  ; Idle: increment
                        LDA             zp_ScratchD         ; $0B8E: A5 29  ; Load snapshot 4 from zp_ScratchD
                        AND             zp_ProtocolMask     ; $0B90: 25 06  ; Test protocol line
                        BEQ             ExitIdleCount       ; $0B92: F0 01  ; Active: stop
                        INX                                 ; $0B94: E8  ; Idle: increment
ExitIdleCount:
                        RTS                                 ; $0B95: 60  ; Return: X = idle count (0-4)

; ────────────────────────────────────────────────────────────────────────────
; IRQ (0x0B96)
; Purpose: Precision timer ISR. Fires every ~163 t-states (108.7 us).
; Reloads counter, increments tick counter, optionally increments 12-bit
; pulse duration counter, writes PortC/D on odd ticks when data pending.
; Saves A only; X and Y NOT preserved.
; Counter latch=140, overhead=23. True period=163 t-states.
; Port update rate: every 2nd IRQ (~217 us). Max pulse: 4095 ticks (~445 ms).
; ────────────────────────────────────────────────────────────────────────────
IRQ:
                        PHA                                 ; $0B96: 48  ; Save A on IRQ entry
                        LDA             #$8C                ; $0B97: A9 8C  ; A = 140: counter reload value
                        STA             hw_LowerLatchWO     ; $0B99: 85 85  ; Write to lower latch
                        LDA             #$00                ; $0B9B: A9 00  ; A = 0: upper latch
                        STA             hw_UpperLatchWO     ; $0B9D: 85 84  ; Clear upper latch
                        STA             hw_TransferWO       ; $0B9F: 85 88  ; Trigger counter reload
                        INC             zp_IRQCount_LSB     ; $0BA1: E6 10  ; Increment tick counter LSB
                        BNE             IRQ_CounterUpdated  ; $0BA3: D0 02  ; Skip MSB unless LSB overflowed

; Carries into MSB — only reached when LSB wraps from 0xFF to 0x00 (every 256 IRQ ticks = ~27.8 ms)
                        INC             zp_IRQCount_MSB     ; $0BA5: E6 11  ; Increment tick counter MSB

; Global tick counter updated successfully
IRQ_CounterUpdated:
                        LDA             zp_IREventFlag      ; $0BA7: A5 0F  ; Check bit 7: is pulse measurement active?
                        BPL             IRQ_CheckJoystick   ; $0BA9: 10 19  ; Bit 7 clear: skip pulse counter

; IR pulse measurement: increment 12-bit counter (max 4095). Sets IREventFlag bit 0 on overflow (timeout).
                        LDA             zp_PulseDuration_LSB; $0BAB: A5 04  ; Load pulse width LSB
                        CLC                                 ; $0BAD: 18  ; Clear carry
                        ADC             #$01                ; $0BAE: 69 01  ; Add 1 tick
                        STA             zp_PulseDuration_LSB; $0BB0: 85 04  ; Store updated LSB
                        LDA             zp_PulseDuration_MSB; $0BB2: A5 05  ; Load pulse width MSB
                        ADC             #$00                ; $0BB4: 69 00  ; Add carry from LSB
                        AND             #$0F                ; $0BB6: 29 0F  ; Mask to 4 bits (12-bit range)
                        STA             zp_PulseDuration_MSB; $0BB8: 85 05  ; Store MSB
                        ORA             zp_PulseDuration_LSB; $0BBA: 05 04  ; Test full counter for overflow (both bytes zero)
                        BNE             IRQ_CheckJoystick   ; $0BBC: D0 06  ; Non-zero: still counting

; ────────────────────────────────────────────────────────────────────────────
; 12-bit pulse counter overflow path inside IRQ handler.
; Reached only when both zp_PulseDuration_LSB ($0004) AND zp_PulseDuration_MSB ($0005) are zero after
; the masked increment at $0BB6 — meaning the counter wrapped through all 4096 values.
; At 163 t-states per IRQ tick this requires ~4096 ticks = ~667
; ────────────────────────────────────────────────────────────────────────────

; If g_IRPulseWidth counter fully overflows set IR event flag
; 12-bit pulse counter overflow.
; Sets bit 0 of IREventFlag to signal timeout to the main loop.
; The acquisition routine (f_AcquireIRBits etc.) checks this and aborts.
                        LDA             zp_IREventFlag      ; $0BBE: A5 0F  ; Load IREventFlag: bit 7 is set (pulse measurement still active at overflow point)
                        ORA             #$01                ; $0BC0: 09 01  ; Set bit 0: signal acquisition timeout to the main loop
                        STA             zp_IREventFlag      ; $0BC2: 85 0F  ; Store updated flags; main loop acquisition routines test bit 0 before each step

; Port update gating. Writes PortC/D on odd ticks only (halves rate to ~217 us). Requires IRInputReady bit 7.
IRQ_CheckJoystick:
                        LDA             zp_IRQCount_LSB     ; $0BC4: A5 10  ; Load tick counter LSB
                        LSR             A                   ; $0BC6: 4A  ; Shift bit 0 into carry
                        BCC             IRQ_ExitHandler     ; $0BC7: 90 10  ; Even tick: skip port update

; Check if joystick input event is pending
                        LDA             zp_IRInputReady     ; $0BC9: A5 16  ; Check peripheral data pending
                        BPL             IRQ_ExitHandler     ; $0BCB: 10 0C  ; No data: skip port write

; Joystick/mouse port write block — only reached on odd ticks when bit 7 of zp_IRInputReady is set (peripheral data waiting). Skipped on idle since zp_IRInputReady=0x00.
                        LDA             zp_PortD            ; $0BCD: A5 02  ; Write PortD shadow to hw_PortD
                        STA             hw_PortD            ; $0BCF: 85 83  ; Commit PortD
                        LDA             zp_PortC            ; $0BD1: A5 03  ; Load PortC shadow
                        STA             hw_PortC            ; $0BD3: 85 82  ; Write to hw_PortC

; Clear peripheral-data-pending flag — signals to main loop that port write is complete
                        LDA             #$00                ; $0BD5: A9 00  ; A = 0: clear pending flag
                        STA             zp_IRInputProcessed ; $0BD7: 85 1F  ; Clear IRInputProcessed: port write done
IRQ_ExitHandler:
                        PLA                                 ; $0BD9: 68  ; Restore A

; RTI exits both NMI (no code) and IRQ.
NMI:
                        RTI                                 ; $0BDA: 40  ; RTI (shared with NMI which has no handler body)

; ────────────────────────────────────────────────────────────────────────────
; f_DetectInputEdges (0x0BDB)
; Purpose: Monitor IRDT (PA0) and PRDT (PA3) for signal transitions.
; Maintains raw and active-high states with separate edge detection.
; Called twice per main loop: 0x086B (baseline) and 0x08B1 (final).
; ────────────────────────────────────────────────────────────────────────────
f_DetectInputEdges:
                        LDA             zp_IRPR_RawState    ; $0BDB: A5 17  ; Load previous raw state
                        PHA                                 ; $0BDD: 48  ; Push for comparison
                        LDA             hw_PortA            ; $0BDE: A5 80  ; Read current PortA
                        AND             #$09                ; $0BE0: 29 09  ; Mask to PA0 and PA3 only
                        STA             zp_IRPR_RawState    ; $0BE2: 85 17  ; Update raw state
                        PLA                                 ; $0BE4: 68  ; Retrieve previous state
                        EOR             #$FF                ; $0BE5: 49 FF  ; Invert for edge detection
                        AND             zp_IRPR_RawState    ; $0BE7: 25 17  ; AND: find deactivation edges (active->inactive)
                        STA             zp_IRPR_RawDeactEdge; $0BE9: 85 18  ; Store deactivation edges
                        LDA             zp_IRPR_ActiveFlags ; $0BEB: A5 19  ; Load previous active-high state
                        PHA                                 ; $0BED: 48  ; Push for comparison
                        LDA             zp_IRPR_RawState    ; $0BEE: A5 17  ; Reload raw state
                        EOR             #$09                ; $0BF0: 49 09  ; XOR 0x09: convert to active-high convention
                        STA             zp_IRPR_ActiveFlags ; $0BF2: 85 19  ; Store active-high state
                        PLA                                 ; $0BF4: 68  ; Retrieve old active-high
                        EOR             #$FF                ; $0BF5: 49 FF  ; Invert for edge detection
                        AND             zp_IRPR_ActiveFlags ; $0BF7: 25 19  ; AND: find activation edges (inactive->active)
                        STA             zp_IRPR_ActivationEdge; $0BF9: 85 1A  ; Store activation edges
                        RTS                                 ; $0BFB: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessFrontPanel (0x0BFC)
; Purpose: Read CDTV front panel buttons via PortB bits 0/1/3.
; Detect changes, look up scancode from tbl_TableFrontButtons (0x0C23),
; transmit press/release pair via f_SendKeyboardSerial with debounce.
; Bit 2 (PB2=_KBSE) excluded to protect keyboard handshake.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessFrontPanel:
                        LDA             hw_PortB            ; $0BFC: A5 81  ; Read front panel button state from hw_PortB
                        AND             #$0B                ; $0BFE: 29 0B  ; Mask to bits 0/1/3 (media controls)
                        BEQ             NoKeyDetected_ClearPrevState; $0C00: F0 1E  ; No button: clear previous state, return

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessFrontPanel — button detected and changed path ($0C02-$0C1D).
; Reached when hw_PortB AND $0B is non-zero (a front panel button is pressed) AND that state
; differs from zp_FrontPanelPrevious ($0024).
; Bit mapping (PortB AND $0B):
; bit 0 = Stop (index 1  scancode $72)
; bit 1 = Play/Pause (index 2  scancode $73)
; bit 3 = Rewind (index 8  scancode $75)
; bits 4-7: not involved (PB2=_KBSE excluded at $0BFE mask)
; Protocol:
; 1. Save button index in X  push onto stack
; 2. Look up Amiga scancode from tbl_TableFrontButtons[X] ($0C23)
; 3. Transmit press via f_SendKeyboardSerial
; 4. 256-iteration debounce delay (~854 µs)
; 5. Pop index  look up same scancode
; 6. Set bit 7 (key release)
; 7. Tail-call f_SendKeyboardSerial for release
; Note: the double lookup (press and release) uses the same table[X] read; no state is
; retained between the two transmissions. The Amiga differentiates press/release
; by bit 7 of the scancode byte.
; ────────────────────────────────────────────────────────────────────────────
                        TAX                                 ; $0C02: AA  ; X = button index (PortB AND $0B); save for release lookup
                        EOR             zp_FrontPanelPrevious; $0C03: 45 24  ; XOR with zp_FrontPanelPrevious: check if button state has changed
                        BEQ             ExitNoChange        ; $0C05: F0 1B  ; Unchanged: return without retransmitting (debounce guard)
                        STX             zp_FrontPanelPrevious; $0C07: 86 24  ; New state differs: save as new previous so the same event is not re-sent next iteration
                        TXA                                 ; $0C09: 8A  ; Transfer button index back to A for table lookup
                        PHA                                 ; $0C0A: 48  ; Push button index onto stack — needed for release event after debounce

; *** Ghidra bug, should point to the table.
                        LDA             f_ResetPulseTimer,X ; $0C0B: BD 23 0C  ; Load Amiga scancode for this button index from tbl_TableFrontButtons
                        JSR             f_SendKeyboardSerial; $0C0E: 20 AD 0E  ; Transmit press scancode via f_SendKeyboardSerial (PA1/PA2 serial)
                        LDY             #$00                ; $0C11: A0 00  ; Y = 0: start 256-iteration debounce delay to prevent bounce re-triggering
DebounceDelay:
                        DEY                                 ; $0C13: 88  ; Decrement counter — each iteration costs ~4 t-states × 256 = ~1024 t-states total
                        BNE             DebounceDelay       ; $0C14: D0 FD  ; Loop until debounce delay expires
                        PLA                                 ; $0C16: 68  ; Pop saved button index from stack
                        TAX                                 ; $0C17: AA  ; Transfer to X for release table lookup

; *** Ghidra bug, should point to the table.
                        LDA             f_ResetPulseTimer,X ; $0C18: BD 23 0C  ; Load same scancode for release (same table  same index)
                        ORA             #$80                ; $0C1B: 09 80  ; Set bit 7: Amiga keyboard protocol marks key releases with bit 7 high
                        JMP             f_SendKeyboardSerial; $0C1D: 4C AD 0E  ; Tail-call f_SendKeyboardSerial for release event; RTS of f_SendKeyboardSerial returns to caller
NoKeyDetected_ClearPrevState:
                        STA             zp_FrontPanelPrevious; $0C20: 85 24  ; No button: clear previous
ExitNoChange:
                        RTS                                 ; $0C22: 60  ; Return

; Front panel scancode table (11 entries). Index = PortB bits 3/1/0. Indices 4-7 unused (_KBSE conflict).
tbl_TableFrontButtons:
                        .byte           $00                 ; $0C23: 00  ; 0 0 0 0 Index 0: no key pressed
                        .byte           $72                 ; $0C24: 72  ; 0 0 0 1 Index 1: 0x72 (Stop)
                        .byte           $73                 ; $0C25: 73  ; 0 0 1 0 Index 2: 0x73 (Play/Pause)
                        .byte           $74                 ; $0C26: 74  ; 0 0 1 1 Index 3: 0x74 (Rewind)
                        .byte           $00                 ; $0C27: 00  ; 0 1 0 0 Index 4: unused (_KBSE pin conflict)
                        .byte           $00                 ; $0C28: 00  ; 0 1 0 1 Index 5: unused (_KBSE pin conflict)
                        .byte           $00                 ; $0C29: 00  ; 0 1 1 0 Index 6: unused (_KBSE pin conflict)
                        .byte           $00                 ; $0C2A: 00  ; 0 1 1 1 Index 7: unused (_KBSE pin conflict)
                        .byte           $75                 ; $0C2B: 75  ; 1 0 0 0 Index 8: 0x75 (Fast Forward)
                        .byte           $76                 ; $0C2C: 76  ; 1 0 0 1 Index 9: 0x76 (Volume Up?)
                        .byte           $77                 ; $0C2D: 77  ; 1 0 1 0 Index 10: 0x77 (Volume Down?)

; ────────────────────────────────────────────────────────────────────────────
; f_ResetPulseTimer (0x0C2E)
; Purpose: Zero the 16-bit pulse counter and set IREventFlag bit 7 to enable
; IRQ-driven pulse counting. Must be called before each measurement.
; ────────────────────────────────────────────────────────────────────────────
f_ResetPulseTimer:
                        LDA             #$00                ; $0C2E: A9 00  ; A = 0: clear both counter bytes
                        STA             zp_PulseDuration_LSB; $0C30: 85 04  ; Zero pulse duration LSB
                        STA             zp_PulseDuration_MSB; $0C32: 85 05  ; Zero pulse duration MSB
                        LDA             zp_IREventFlag      ; $0C34: A5 0F  ; Load IREventFlag
                        ORA             #$80                ; $0C36: 09 80  ; Set bit 7: enable IRQ pulse counting
                        STA             zp_IREventFlag      ; $0C38: 85 0F  ; Store: IRQ will now count ticks
                        RTS                                 ; $0C3A: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_ValidatePulseTiming (0x0C3B)
; Purpose: Validate pulse duration against indexed timing bounds.
; Clears IREventFlag bit 7 first (stops counting).
; Returns: A=0 Z=1 (valid), A=0xFF Z=0 (invalid).
; Windows (X -> ticks): 0:58-250, 2:13-31, 4:38-50, 6:4-10,
; 8:11-18, 10:6-19, 12:1-6
; ────────────────────────────────────────────────────────────────────────────
f_ValidatePulseTiming:
                        LDA             zp_IREventFlag      ; $0C3B: A5 0F  ; Load IREventFlag
                        AND             #$7F                ; $0C3D: 29 7F  ; Clear bit 7: stop pulse counting
                        STA             zp_IREventFlag      ; $0C3F: 85 0F  ; Store cleaned flag
                        LDA             zp_PulseDuration_LSB; $0C41: A5 04  ; Load measured pulse duration in ticks
                        CMP             tbl_TimingBoundsLower,X; $0C43: DD 53 0C  ; Compare against lower bound[X]
                        BCC             TimingInvalid       ; $0C46: 90 08  ; Too short: invalid
                        CMP             tbl_TimingBoundsUpper,X; $0C48: DD 54 0C  ; Compare against upper bound[X+1]
g_EorTableHigh:
                        BCS             TimingInvalid       ; $0C4B: B0 03  ; Too long: invalid
                        LDA             #$00                ; $0C4D: A9 00  ; A = 0: valid
                        RTS                                 ; $0C4F: 60  ; Return (Z set)
TimingInvalid:
                        LDA             #$FF                ; $0C50: A9 FF  ; A = 0xFF: invalid
                        RTS                                 ; $0C52: 60  ; Return (Z clear)

; Timing bounds table. Interleaved min/max pairs for protocol elements. Addressed as [X] and [X+1].
tbl_TimingBoundsLower:
                        .byte           $3A                 ; $0C53: 3A  ; 0: Header pulse lower bound (58 ticks = 8.1ms)
tbl_TimingBoundsUpper:
                        .byte           $FA                 ; $0C54: FA  ; 1: Header pulse upper bound (250 ticks = 35ms)
                        .byte           $0D                 ; $0C55: 0D  ; 2: Bit '1' lower bound (13 ticks = 1.8ms)
                        .byte           $1F                 ; $0C56: 1F  ; 3: Bit '1' upper bound (31 ticks = 4.3ms)
                        .byte           $26                 ; $0C57: 26  ; 4: Header space lower bound (38 ticks = 5.3ms)
                        .byte           $32                 ; $0C58: 32  ; 5; Header space upper bound (50 ticks = 7.0ms)
                        .byte           $04                 ; $0C59: 04  ; 6: Short pulse lower bound (4 ticks = 560µs)
                        .byte           $0A                 ; $0C5A: 0A  ; 7: Short pulse upper bound (10 ticks = 1.4ms)
                        .byte           $0B                 ; $0C5B: 0B  ; 8: Long pulse lower bound (11 ticks = 1.5ms)
                        .byte           $12                 ; $0C5C: 12  ; 9: Long pulse upper bound (18 ticks = 2.5ms)
                        .byte           $06                 ; $0C5D: 06  ; 10: Alt timing lower bound (6 ticks = 840µs)
                        .byte           $13                 ; $0C5E: 13  ; 11: Alt timing upper bound (19 ticks = 2.7ms)
                        .byte           $01                 ; $0C5F: 01  ; 12: Keyboard bit lower bound (1 tick = 140µs)
                        .byte           $06                 ; $0C60: 06  ; 13: Keyboard bit upper bound (6 ticks = 840µs)

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessIRDataAndSetFlags (0x0C61)
; Purpose: Verify IR frame checksums and extract decoded fields.
; Two paths (selected by IREventFlag bit 2):
; bit2=0: Standard 20-bit (numpad/media). Two checksums.
; Output: zp_IRCommandByte, zp_ScratchB (direction)
; bit2=1: Extended 40-bit (keyboard). Three checksums.
; Output: zp_IRCommandByte (modifier bitmask), zp_KeyboardIndex
; Side effects: IRShift0-2 destructively modified on 40-bit path.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessIRDataAndSetFlags:
                        LDA             zp_IREventFlag      ; $0C61: A5 0F  ; Load IREventFlag for guard check
                        AND             #$03                ; $0C63: 29 03  ; Isolate error and event bits
                        ORA             zp_IRInputReady     ; $0C65: 05 16  ; Combine with IR input ready
                        ORA             zp_PeripheralDataReady; $0C67: 05 23  ; Combine with peripheral data semaphore
                        BNE             ReturnFromFunction  ; $0C69: D0 3C  ; Any flag set: return without decoding

                        LDA             zp_IREventFlag      ; $0C6B: A5 0F  ; Reload IREventFlag for bit 2 test
                        AND             #$04                ; $0C6D: 29 04  ; Isolate bit 2: 40-bit frame selector
                        BNE             f_Decode40BitIRKeyboard; $0C6F: D0 37  ; 40-bit: branch to f_Decode40BitIRKeyboard

; Standard 20-bit decode. Extract command from IRShift2, verify against complement in IRShift3/4.
                        LDA             zp_IRShift2         ; $0C71: A5 0B  ; Load IRShift2: command byte
                        STA             zp_ScratchA         ; $0C73: 85 26  ; Stage for checksum comparison
                        LDA             zp_IRShift3         ; $0C75: A5 0C  ; Load IRShift3: direction nibble + complement
                        STA             zp_ScratchC         ; $0C77: 85 28  ; Stage for rotation chain
                        AND             #$0F                ; $0C79: 29 0F  ; Isolate direction nibble (lower 4 bits)
                        STA             zp_ScratchB         ; $0C7B: 85 27  ; Store direction flag
                        LDA             zp_IRShift4         ; $0C7D: A5 0D  ; Load IRShift4: bitwise complement
                        STA             zp_ScratchD         ; $0C7F: 85 29  ; Stage for rotation alignment

; Nibble alignment: 4 right-shifts to align complement for XOR.
                        LDX             #$04                ; $0C81: A2 04  ; X = 4: rotation iterations
RotateLoopA:
                        LSR             zp_ScratchD         ; $0C83: 46 29  ; LSR complement byte
                        ROR             zp_ScratchC         ; $0C85: 66 28  ; ROR command byte through carry
                        DEX                                 ; $0C87: CA  ; Decrement counter
                        BNE             RotateLoopA         ; $0C88: D0 F9  ; Loop until done

; Checksum 1: command XOR complement XOR 0xFF. Valid = 0x00.
                        LDA             zp_ScratchA         ; $0C8A: A5 26  ; Reload staged command byte
                        EOR             zp_ScratchC         ; $0C8C: 45 28  ; XOR with rotated complement
                        EOR             #$FF                ; $0C8E: 49 FF  ; Invert: valid = 0x00
                        BNE             SetIRFlagAndExit    ; $0C90: D0 65  ; Checksum 1 failed: discard frame

; Checksum 2: direction XOR complement XOR 0x0F. Valid = 0x00.
                        LDA             zp_ScratchB         ; $0C92: A5 27  ; Reload direction nibble
                        EOR             zp_ScratchD         ; $0C94: 45 29  ; XOR with complement
                        EOR             #$0F                ; $0C96: 49 0F  ; Invert lower nibble: valid = 0x00
                        BNE             SetIRFlagAndExit    ; $0C98: D0 5D  ; Checksum 2 failed: discard frame

; Both passed. Extract decoded command by shifting IRShift3 into IRShift2.
                        LDX             #$04                ; $0C9A: A2 04  ; X = 4: extraction rotations
RotateLoopB:
                        LSR             zp_IRShift3         ; $0C9C: 46 0C  ; Shift IRShift3 right
                        ROR             zp_IRShift2         ; $0C9E: 66 0B  ; Rotate into IRShift2
                        DEX                                 ; $0CA0: CA
                        BNE             RotateLoopB         ; $0CA1: D0 F9  ; repeat 4 times
                        LDA             zp_IRShift2         ; $0CA3: A5 0B  ; Load decoded 8-bit command
                        STA             zp_IRCommandByte    ; $0CA5: 85 07  ; Store as zp_IRCommandByte
ReturnFromFunction:
                        RTS                                 ; $0CA7: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_Decode40BitIRKeyboard (0x0CA8)
; Decodes a 40-bit IR keyboard frame from shift registers IRShift0..4.
; Outputs:
; zp_IRCommandByte  = qualifier bitmask (8 qualifier keys, one-hot per Amiga spec)
; zp_KeyboardIndex  = IR keycode index (0 = no key pressed)
; Note: zp_IRCommandByte is referred to as qualifier bitmask on this path.
; The term modifier in earlier annotations is incorrect — the Amiga Hardware
; Reference Manual calls these keys qualifiers.
; ────────────────────────────────────────────────────────────────────────────
f_Decode40BitIRKeyboard:
                        LDA             zp_IRShift0         ; $0CA8: A5 09  ; Load IRShift0: modifier bitmask byte
                        STA             zp_ScratchA         ; $0CAA: 85 26  ; Stash modifier in zp_ScratchA (scratch use)
                        LDA             zp_IRShift1         ; $0CAC: A5 0A  ; Load IRShift1: keyboard table index
                        STA             zp_ScratchB         ; $0CAE: 85 27  ; Stash keyboard byte in zp_ScratchB (scratch use)
                        LDA             zp_IRShift2         ; $0CB0: A5 0B  ; Load IRShift2: complement byte
                        STA             zp_ScratchD         ; $0CB2: 85 29  ; Save for rotation chain
                        AND             #$0F                ; $0CB4: 29 0F  ; Isolate lower nibble
                        STA             zp_ScratchC         ; $0CB6: 85 28  ; Save for checksum 3
                        LDA             zp_IRShift3         ; $0CB8: A5 0C  ; Load IRShift3: complement of byte 1
                        STA             zp_PeriphTypeSave   ; $0CBA: 85 2A  ; Save for checksum 2 chain
                        LDA             zp_IRShift4         ; $0CBC: A5 0D  ; Load IRShift4: complement nibble
                        STA             zp_IRScratch        ; $0CBE: 85 2B  ; Store IRShift4 in zp_IRScratch — after 4 LSRs the upper nibble slides to bits[3:0] for checksum 3

; Align complement bytes by 4 right-rotations so lower nibbles align with data bytes for XOR comparison.
                        LDX             #$04                ; $0CC0: A2 04  ; X = 4: one nibble of rotation
RotateLoopC:
                        LSR             zp_IRScratch        ; $0CC2: 46 2B  ; LSR zp_IRScratch
                        ROR             zp_PeriphTypeSave   ; $0CC4: 66 2A  ; ROR through rotation chain
                        ROR             zp_ScratchD         ; $0CC6: 66 29  ; ROR next byte in chain
                        DEX                                 ; $0CC8: CA
                        BNE             RotateLoopC         ; $0CC9: D0 F7  ; Repeat until 4 shifts done (one nibble aligned)

; Checksum 1: modifier XOR complement XOR 0xFF = 0x00.
                        LDA             zp_ScratchA         ; $0CCB: A5 26  ; Reload modifier byte
                        EOR             zp_ScratchD         ; $0CCD: 45 29  ; XOR with aligned complement
                        EOR             #$FF                ; $0CCF: 49 FF  ; Invert: valid = 0x00
                        BNE             SetIRFlagAndExit    ; $0CD1: D0 24  ; Failed: abort

; Checksum 2: keyboard XOR complement XOR 0xFF = 0x00.
                        LDA             zp_ScratchB         ; $0CD3: A5 27  ; Reload keyboard byte
                        EOR             zp_PeriphTypeSave   ; $0CD5: 45 2A  ; XOR with complement
                        EOR             #$FF                ; $0CD7: 49 FF  ; Invert: valid = 0x00
                        BNE             SetIRFlagAndExit    ; $0CD9: D0 1C  ; Failed: abort

; Checksum 3: IRShift2[3:0] XOR IRShift4[7:4] (= IRScratch>>4 after 4 LSRs) XOR 0x0F = 0x00.
                        LDA             zp_ScratchC         ; $0CDB: A5 28  ; Reload lower nibble of IRShift2
                        EOR             zp_IRScratch        ; $0CDD: 45 2B  ; XOR with IRScratch (= IRShift4[7:4] shifted to lower nibble after 4 LSRs)
                        EOR             #$0F                ; $0CDF: 49 0F  ; Invert: valid = 0x00
                        BNE             SetIRFlagAndExit    ; $0CE1: D0 14  ; Failed: abort

; All passed. Right-rotate [IRShift2:1:0] by 4 to strip complement nibble. Destructive.
                        LDX             #$04                ; $0CE3: A2 04  ; X = 4: strip complement nibble
RotateLoopD:
                        LSR             zp_IRShift2         ; $0CE5: 46 0B  ; LSR IRShift2
                        ROR             zp_IRShift1         ; $0CE7: 66 0A  ; ROR IRShift1
                        ROR             zp_IRShift0         ; $0CE9: 66 09  ; ROR IRShift0: modifier bitmask assembles here
                        DEX                                 ; $0CEB: CA
                        BNE             RotateLoopD         ; $0CEC: D0 F7  ; Repeat until 4 shifts complete

; Store decoded fields. IRShift0 now = modifier bitmask (8 keys),
; IRShift1 now = keyboard table index (0 = no key pressed).
                        LDA             zp_IRShift0         ; $0CEE: A5 09  ; Load decoded modifier bitmask
                        STA             zp_IRCommandByte    ; $0CF0: 85 07  ; Store as zp_IRCommandByte (modifier bitmask)
                        LDA             zp_IRShift1         ; $0CF2: A5 0A  ; Load decoded keyboard index (0=no key)
                        STA             zp_KeyboardIndex    ; $0CF4: 85 08  ; Store as zp_KeyboardIndex
                        RTS                                 ; $0CF6: 60  ; Return: frame decoded

; Checksum failure. Set IREventFlag bit 0. Not reachable from valid frames.
SetIRFlagAndExit:
                        LDA             zp_IREventFlag      ; $0CF7: A5 0F  ; Reload IREventFlag
                        ORA             #$01                ; $0CF9: 09 01  ; Set bit 0: checksum failure
                        STA             zp_IREventFlag      ; $0CFB: 85 0F  ; Store error flag
                        RTS                                 ; $0CFD: 60  ; Return: frame discarded

; ────────────────────────────────────────────────────────────────────────────
; f_JumpTableDispatcher (0x0CFE)
; Purpose: Guard and dispatch IR frame. Checks 3 semaphores, then uses
; zp_IRHeaderNibble as index into tbl_PeripheralHandlers via RTS trick.
; Jump table (0x0D1B):
; 0 -> f_ProcessMouse (0x0D43)  1 -> f_ProcessJoystick (0x0D6C)
; 2 -> f_KeyboardDispatchThunk (0x0D21) -> f_ProcessKeyboardEvent
; ────────────────────────────────────────────────────────────────────────────

; Guard: check 3 semaphores. Then use zp_IRHeaderNibble as index into handler table via RTS trick.
f_JumpTableDispatcher:
                        LDA             zp_IREventFlag      ; $0CFE: A5 0F  ; Load IREventFlag: check error bit
                        AND             #$01                ; $0D00: 29 01  ; Isolate error bit
                        ORA             zp_IRInputReady     ; $0D02: 05 16  ; Combine with input-ready flag
                        ORA             zp_PeripheralDataReady; $0D04: 05 23  ; Combine with peripheral semaphore
                        BNE             ExitTableDispatcher ; $0D06: D0 12  ; Any flag set: exit without dispatch
                        LDA             zp_IRHeaderNibble   ; $0D08: A5 0E  ; Load zp_IRHeaderNibble
                        AND             #$0F                ; $0D0A: 29 0F  ; Mask to lower nibble
                        CMP             #$03                ; $0D0C: C9 03  ; Bounds check: only 0, 1, 2 valid
                        BCS             ExitTableDispatcher ; $0D0E: B0 0A  ; >= 3: no handler. Exit
                        ASL             A                   ; $0D10: 0A  ; Double for word offset into jump table
                        TAX                                 ; $0D11: AA  ; Transfer to X for indexed read
                        LDA             $0D3A,X             ; $0D12: BD 1C 0D  ; Load high byte of handler address (target-1)
                        PHA                                 ; $0D15: 48  ; Push high byte

; *** Ghidra bug, should point to the table.
                        LDA             StoreToPortD+1,X    ; $0D16: BD 1B 0D  ; Load low byte of handler address
                        PHA                                 ; $0D19: 48  ; Push low byte
ExitTableDispatcher:
                        RTS                                 ; $0D1A: 60  ; RTS pops address, adds 1, jumps to handler

; Jump table: [0] f_ProcessMouse, [1] f_ProcessJoystick, [2] f_KeyboardDispatchThunk.
tbl_PeripheralHandlers:
                        .word           f_ProcessMouse-1    ; $0D1B: 42 0D  ; Entry 0: f_ProcessMouse (IRHeaderNibble=0x0, mouse/portD)
                        .word           f_ProcessJoystick-1 ; $0D1D: 6B 0D  ; Entry 1: f_ProcessJoystick (IRHeaderNibble=0x1, joystick/portC)
                        .word           f_KeyboardDispatchThunk-1; $0D1F: 20 0D  ; Entry 2: f_KeyboardDispatchThunk (IRHeaderNibble=0x2, keyboard)

; ────────────────────────────────────────────────────────────────────────────
; f_KeyboardDispatchThunk ($0D21)
; Purpose: Relay dispatch for IR keyboard frames (zp_IRHeaderNibble=2).
; Reached via the RTS jump-table trick in f_JumpTableDispatcher: the table entry at $0D1F holds address $0D20 (target-1); RTS pops and adds 1 to land here.
; Jumps unconditionally to f_ProcessKeyboardEvent ($0F0E).
; The RTS at $0D24 is dead code — it immediately follows an unconditional JMP and has no callers.
; ────────────────────────────────────────────────────────────────────────────
f_KeyboardDispatchThunk:
                        JMP             f_ProcessKeyboardEvent; $0D21: 4C 0E 0F  ; Jump table entry for IRHeaderNibble=2 (keyboard). RTS trick lands here; JMP relays to f_ProcessKeyboardEvent

; ────────────────────────────────────────────────────────────────────────────
; DEAD CODE — unreachable after unconditional JMP at $0D21. Nothing branches or jumps directly to $0D24.
; ────────────────────────────────────────────────────────────────────────────
                        RTS                                 ; $0D24: 60  ; DEAD — unreachable; follows unconditional JMP at $0D21

; ────────────────────────────────────────────────────────────────────────────
; f_PrepareJoyMousePorts (0x0D25)
; Purpose: Encode 2-bit button field from zp_IRCommandByte bits[1:0] into
; active-low upper nibble. Route to PortD (mouse) or PortC (joystick).
; Encoding: 00->0x70 (none), 01->0x60 (A), 10->0x50 (B), 11->0x40 (both)
; ────────────────────────────────────────────────────────────────────────────
f_PrepareJoyMousePorts:
                        LDX             zp_IRHeaderNibble   ; $0D25: A6 0E  ; Load zp_IRHeaderNibble to select port
                        LDA             zp_IRCommandByte    ; $0D27: A5 07  ; Load zp_IRCommandByte for button field
                        AND             #$03                ; $0D29: 29 03  ; Mask bits[1:0]
                        EOR             #$07                ; $0D2B: 49 07  ; EOR #7: invert to active-low
                        ASL             A                   ; $0D2D: 0A  ; ASL step 1/4: shift to upper nibble
                        ASL             A                   ; $0D2E: 0A  ; Step 2 of 4
                        ASL             A                   ; $0D2F: 0A  ; Step 3 of 4
                        ASL             A                   ; $0D30: 0A  ; ASL step 4/4
                        CPX             #$00                ; $0D31: E0 00  ; Test: 0=mouse (PortD), non-zero=joystick (PortC)
                        BEQ             StoreToPortD        ; $0D33: F0 03  ; Mouse: merge into PortD
                        STA             zp_PortC            ; $0D35: 85 03  ; Joystick: write directly to PortC
                        RTS                                 ; $0D37: 60  ; Return (joystick path)
StoreToPortD:
                        STA             zp_ScratchA         ; $0D38: 85 26  ; Stage nibble in zp_ScratchA (temp)
                        LDA             zp_PortD            ; $0D3A: A5 02  ; Load PortD shadow (lower nibble = quadrature)
                        AND             #$0F                ; $0D3C: 29 0F  ; Clear upper nibble
                        ORA             zp_ScratchA         ; $0D3E: 05 26  ; Merge new button nibble
                        STA             zp_PortD            ; $0D40: 85 02  ; Write merged value to PortD shadow
                        RTS                                 ; $0D42: 60  ; Return (mouse path)

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessMouse (0x0D43)
; Purpose: Decode IR mouse frame (IRHeaderNibble=0). Routes by IRCommandByte>>2:
; 0x00-0x0A: button/idle -> PeripheralTypeTail -> f_Quadrature
; 0x0B-0x18: media key -> f_MediaKeyCPCP (CPCP nibble for U62)
; 0x19+: numpad repeat -> _KBSE check then f_ProcessNumbPad
; Outputs: portD (buttons), portB (CPCP), kbd serial (numpad).
; portC always 0xFF (mouse never writes joystick port).
; ────────────────────────────────────────────────────────────────────────────
f_ProcessMouse:
                        LDA             #$0F                ; $0D43: A9 0F  ; A = 0x0F: set button lines to idle

; f_ProcessMouse (0x0D43) — port output summary (fuzz-verified across all 256 mouse commands):
; portD bits[6:4] — mouse button state (active-low, set by f_PrepareJoyMousePorts):
; 0x7F = no button    (MI bits[1:0] = 00)
; 0x6F = Button A     (MI bits[1:0] = 01)
; 0x5F = Button B     (MI bits[1:0] = 10)
; 0x4F = Button A+B   (MI bits[1:0] = 11)
; portB bits[7:4] — CPCP media key (MI>>2 in 0x0B–0x18):
; 9 documented keys (CPCP 1–9) + 4 undocumented (CPCP 0xC–0xF)
; Scancode generated by U62 from portB signal — not by U75
; portC — always 0xFF; mouse path never writes joystick port
; Keyboard serial — MI>>2 >= 0x19 only; via f_ProcessNumbPad/_KBSE handshake
; tbl_NumPadScancodes[0–11] at 0x0F02–0x0F0D: KP0–9 Enter Escape
; Indices outside 0–11 are OOB reads into instruction bytes (27 unique cases)
                        STA             zp_PortB            ; $0D45: 85 01  ; Write idle to PortB shadow
                        JSR             f_PrepareJoyMousePorts; $0D47: 20 25 0D  ; Encode button nibble from IRCommandByte bits[1:0]
                        LDA             zp_IRCommandByte    ; $0D4A: A5 07  ; Reload IRCommandByte to extract command class
                        LSR             A                   ; $0D4C: 4A  ; Shift right twice: divide by 4
                        LSR             A                   ; $0D4D: 4A  ; Second shift — result is MI>>2; ranges: <0x0B=directional, 0x0B-0x18=media, >=0x19=numpad
                        CMP             #$0B                ; $0D4E: C9 0B  ; < 0x0B: directional/button command
                        BCC             PeripheralTypeTail  ; $0D50: 90 21  ; Branch to PeripheralTypeTail for quadrature
                        CMP             #$19                ; $0D52: C9 19  ; < 0x19: media key range
                        BCC             f_MediaKeyCPCP      ; $0D54: 90 32  ; Media key: encode CPCP for U62
                        CMP             zp_ModifierIndexPrior; $0D56: C5 14  ; Compare with prior for duplicate suppression
                        BNE             CheckKBSEHandshake  ; $0D58: D0 03  ; New state: process as fresh event

; ────────────────────────────────────────────────────────────────────────────
; No-change guard inside f_ProcessMouse — numpad/undocumented range ($D52-$D5C).
; This guard is reached when IRCommandByte>>2 is in the range $19-$3F (numpad/undocumented codes)
; AND the current value equals the value stored in zp_ModifierIndexPrior ($0014) from the previous
; frame. If equal the frame carries no new information and is silently discarded.
; Context:
; $0D56: CMP zp_ModifierIndexPrior  — compare current command>>2 against previous
; $0D58: BNE $0D5D                  — different: process event
; $0D5A: STA $14                    — same: update prior with the identical value (no-op semantically)
; $0D5C: RTS                        — return without transmitting any scancode
; This is the only early-exit path in f_ProcessMouse that avoids both f_ProcessNumbPad and the
; _KBSE wait loop. Triggered by repeat frames from a held button.
; ────────────────────────────────────────────────────────────────────────────
                        STA             zp_ModifierIndexPrior; $0D5A: 85 14  ; Same command as last frame: store (no-op) and return — no scancode sent for a held key
ReturnNoAction:
                        RTS                                 ; $0D5C: 60  ; Return without transmitting: held-key debounce complete
CheckKBSEHandshake:
                        TAX                                 ; $0D5D: AA  ; Save command in X
                        LDA             hw_PortB            ; $0D5E: A5 81  ; Read PortB: check _KBSE handshake
                        AND             #$04                ; $0D60: 29 04  ; Isolate _KBSE (PB2)
                        BEQ             ReturnNoAction      ; $0D62: F0 F8  ; Host not ready: return
                        TXA                                 ; $0D64: 8A  ; Restore command
                        STA             zp_ModifierIndexPrior; $0D65: 85 14  ; Record as current repeat state
                        LDA             #$01                ; $0D67: A9 01  ; A = 1: key-down for numpad
                        JMP             f_ProcessNumbPad    ; $0D69: 4C 90 0E  ; Tail-call f_ProcessNumbPad

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessJoystick (0x0D6C)
; Purpose: Handle IR joystick (IRHeaderNibble=1). Encode buttons into PortC
; upper nibble, merge direction bits[5:2] into lower nibble. Single PortC
; write (no quadrature loop).
; Direction (PortC[3:0], active-low):
; Up:0x7E  Down:0x7D  Left:0x7B  Right:0x77
; portD/portB always unchanged on joystick path.
; ────────────────────────────────────────────────────────────────────────────

; f_ProcessJoystick (0x0D6B) — port output summary (fuzz-verified across all 256 joystick commands):
; portC — sole output; encodes both direction and button state (active-low):
; bits[6:4]: button  0x7=none 0x6=Button A 0x5=Button B 0x4=A+B
; bits[3:0]: direction (active-low) bit3=up bit2=down bit1=left bit0=right
; 64 unique portC states (16 direction × 4 button combinations)
; Each state appears exactly 4 times (MI bits[7:6] are not decoded by this path)
; portD — always 0xFF; joystick path never writes mouse port
; portB — always 0x0F; no CPCP output on joystick path
; No keyboard serial output on this path
f_ProcessJoystick:
                        LDA             #$0F                ; $0D6C: A9 0F  ; A = 0x0F: idle button lines
                        STA             zp_PortB            ; $0D6E: 85 01  ; Write idle to PortB shadow
                        JSR             f_PrepareJoyMousePorts; $0D70: 20 25 0D  ; Encode button nibble into PortC upper nibble

; PeripheralTypeTail: shared exit. IRHeaderNibble=0: mouse quadrature. =1: joystick direction merge. =2: return.
PeripheralTypeTail:
                        LDA             zp_IRHeaderNibble   ; $0D73: A5 0E  ; Load zp_IRHeaderNibble
                        BEQ             MouseQuadraturePath ; $0D75: F0 1D  ; 0: mouse path -> MouseQuadraturePath
                        CMP             #$02                ; $0D77: C9 02  ; Test for 2 (Y-axis/unsupported)
                        BEQ             JoystickButton_Exit ; $0D79: F0 0C  ; 2: return without writing direction
                        LDA             zp_IRCommandByte    ; $0D7B: A5 07  ; Load IRCommandByte: bits[5:2] = direction
                        AND             #$3C                ; $0D7D: 29 3C  ; Isolate bits[5:2]
                        EOR             #$3C                ; $0D7F: 49 3C  ; Invert to active-low
                        LSR             A                   ; $0D81: 4A  ; Shift to bits[3:0] for PortC alignment
                        LSR             A                   ; $0D82: 4A  ; Complete shift into bits[3:0] — now a 4-bit value encoding key or direction
                        ORA             zp_PortC            ; $0D83: 05 03  ; Merge into PortC shadow
                        STA             zp_PortC            ; $0D85: 85 03  ; Write to PortC shadow
JoystickButton_Exit:
                        RTS                                 ; $0D87: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_MediaKeyCPCP (0x0D88)
; Purpose: Encode IR media key as CPCP nibble in PortB[7:4] for U62.
; CPCP = ((IRCommandByte>>2) - 0x0F) << 4. PortB[3:0] forced to 0x0F.
; Verified: 1=CD/TV, 2=Genlock, 3=Power, 4=Rew, 5=Play, 6=Stop,
; 7=FF, 8=VolDown, 9=VolUp. 0xC-0xF undocumented.
; Key-up: periodic PortB reset at 0x0876 writes 0x0F (CPCP=0=idle).
; ────────────────────────────────────────────────────────────────────────────

; f_MediaKeyCPCP — CPCP nibble encoding:
; 9 documented commands (CPCP 1–9) map to IR decimals:
; 1=CD/TV(2)  2=Genlock(34) 3=Power(18)  4=Rewind(50)  5=Play/Pause(10)
; 6=Stop(42)  7=FF(26)      8=Vol Down(58) 9=Vol Up(6)
; 4 undocumented commands (CPCP 0xC–0xF) from MI>>2 = 0x0B–0x0E:
; 0xC=dec 52  0xD=dec 12  0xE=dec 44  0xF=dec 28
; These reach f_MediaKeyCPCP via negative SBC result — PB4/PB5 cycle 00/01/10/11.
; U62 behaviour for CPCP 0xC–0xF is unknown (no U62 documentation available).
; Key-up: not sent as a CPCP command. The periodic portB reset at 0x0876
; (~512 IRQs, ~83ms) writes 0x0F to portB — PB7:4=0x0 — which the U62 treats
; as CPCP=0 (idle), completing the key-up.
f_MediaKeyCPCP:
                        SEC                                 ; $0D88: 38  ; SEC before subtraction
                        SBC             #$0F                ; $0D89: E9 0F  ; Subtract 0x0F: map to CPCP index 1-9
                        ASL             A                   ; $0D8B: 0A  ; ASL x4: shift into bits[7:4]
                        ASL             A                   ; $0D8C: 0A  ; (*4)
                        ASL             A                   ; $0D8D: 0A  ; (*8)
                        ASL             A                   ; $0D8E: 0A  ; (*16) — command index now occupies bits[7:4]
                        ORA             #$0F                ; $0D8F: 09 0F  ; ORA #0x0F: preserve _KBSE and AUS lines
                        STA             zp_PortB            ; $0D91: 85 01  ; Write CPCP to PortB shadow
                        RTS                                 ; $0D93: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; MouseQuadraturePath (0x0D94)
; Checks bit 1 of zp_IREventFlag to select between single-step and
; continuous quadrature output. Reached from PeripheralTypeTail when
; zp_IRHeaderNibble=0 (mouse path).
; Bit 1 clear: BEQ directly into f_Quadrature (one 4-step pass).
; Bit 1 set: JSR f_Quadrature then fall through for a second pass.
; ────────────────────────────────────────────────────────────────────────────
MouseQuadraturePath:
                        LDA             zp_IREventFlag      ; $0D94: A5 0F  ; Load IREventFlag for continuous-mode check
                        AND             #$02                ; $0D96: 29 02  ; Isolate bit 1 (set by repeat handler)
                        BEQ             f_Quadrature        ; $0D98: F0 03  ; Bit 1 clear: single-step quadrature
                        JSR             f_Quadrature        ; $0D9A: 20 9D 0D  ; Continuous: call then fall through for double

; ────────────────────────────────────────────────────────────────────────────
; f_Quadrature (0x0D9D)
; Purpose: Drive 4 quadrature phase transitions on PortD.
; X phase from IRCommandByte bits[3:2], Y from bits[5:4].
; XOR with tbl_QuadratureX (0x0DEB) and tbl_QuadratureY (0x0DFB).
; Sequences (PortD[3:0] = XB1 YA1 XA1 YB1):
; Up: F->B->A->E->F  Down: F->E->A->B->F
; Left: F->7->5->D->F  Right: F->D->5->7->F
; Each step waits ~217 us (2 IRQ ticks). Total ~868 us.
; ────────────────────────────────────────────────────────────────────────────
f_Quadrature:
                        LDY             #$04                ; $0D9D: A0 04  ; Y = 4: four steps per call
                        LDA             zp_IRCommandByte    ; $0D9F: A5 07  ; Load IRCommandByte for X-axis phase
                        LSR             A                   ; $0DA1: 4A  ; Shift bits[3:2] to bits[1:0]
                        LSR             A                   ; $0DA2: 4A  ; Shift right again — X phase now in bits[1:0]
                        AND             #$03                ; $0DA3: 29 03  ; Mask to 2 bits
                        ASL             A                   ; $0DA5: 0A  ; Scale by 4 for table byte offset
                        ASL             A                   ; $0DA6: 0A  ; Scale step 2 — X table byte offset ready
                        STA             zp_ScratchA         ; $0DA7: 85 26  ; Save X-axis offset in zp_ScratchA
                        LDA             zp_IRCommandByte    ; $0DA9: A5 07  ; Reload for Y-axis phase (bits[5:4])
                        LSR             A                   ; $0DAB: 4A  ; Shift 4 right to bits[1:0]
                        LSR             A                   ; $0DAC: 4A  ; Step 2
                        LSR             A                   ; $0DAD: 4A  ; Step 3
                        LSR             A                   ; $0DAE: 4A  ; Step 4 — Y phase now in bits[1:0]
                        AND             #$03                ; $0DAF: 29 03  ; Mask to 2 bits
                        ASL             A                   ; $0DB1: 0A  ; Scale by 4 for Y-axis offset
                        ASL             A                   ; $0DB2: 0A  ; Step 2 — Y table byte offset ready
                        STA             zp_ScratchB         ; $0DB3: 85 27  ; Save Y-axis offset in zp_ScratchB

; Output loop: XOR idle PortD with X and Y phase masks, write to hardware, wait 2 IRQ ticks per step.
OutputUpdateLoop:
                        LDA             zp_PortD            ; $0DB5: A5 02  ; Load PortD shadow
                        ORA             #$0F                ; $0DB7: 09 0F  ; Force quadrature nibble to idle (0xF)
                        STA             zp_PortD            ; $0DB9: 85 02  ; Store idle baseline
                        LDX             zp_ScratchA         ; $0DBB: A6 26  ; Load X-axis table offset
                        LDA             zp_PortD            ; $0DBD: A5 02  ; Reload PortD shadow
                        EOR             $0DF7,X             ; $0DBF: 5D EB 0D  ; XOR with X-axis transition mask
                        STA             zp_PortD            ; $0DC2: 85 02  ; Write X-axis state
                        INX                                 ; $0DC4: E8  ; Advance X offset to next entry
                        STX             zp_ScratchA         ; $0DC5: 86 26  ; Save updated X offset
                        LDX             zp_ScratchB         ; $0DC7: A6 27  ; Load Y-axis table offset
                        LDA             zp_PortD            ; $0DC9: A5 02  ; Reload PortD (has X applied)
                        EOR             $0E07,X             ; $0DCB: 5D FB 0D  ; XOR with Y-axis transition mask
                        STA             zp_PortD            ; $0DCE: 85 02  ; Write combined X+Y state
                        INX                                 ; $0DD0: E8  ; Advance Y offset
                        STX             zp_ScratchB         ; $0DD1: 86 27  ; Save updated Y offset
                        LDA             zp_PortD            ; $0DD3: A5 02  ; Load final combined PortD value
                        STA             hw_PortD            ; $0DD5: 85 83  ; Push to hw_PortD
                        LDA             #$00                ; $0DD7: A9 00  ; A = 0: reset IRQ counter
                        STA             zp_IRQCount_LSB     ; $0DD9: 85 10  ; Reset tick counter for phase wait
IRQ_WaitLoop:
                        LDA             zp_IRQCount_LSB     ; $0DDB: A5 10  ; Sample tick counter
                        CMP             #$02                ; $0DDD: C9 02  ; Wait for 2 ticks (~217 us)
                        BCC             IRQ_WaitLoop        ; $0DDF: 90 FA  ; Spin until elapsed
                        DEY                                 ; $0DE1: 88  ; Decrement step counter
                        BNE             OutputUpdateLoop    ; $0DE2: D0 D1  ; More steps: loop back
                        LDA             zp_PortD            ; $0DE4: A5 02  ; Load PortD after final step
                        ORA             #$0F                ; $0DE6: 09 0F  ; Force quadrature back to idle
                        STA             zp_PortD            ; $0DE8: 85 02  ; Store idle-restored state
                        RTS                                 ; $0DEA: 60  ; Return: 4 steps delivered

; X-axis quadrature EOR table (16 bytes). XOR with idle 0x0F to produce pin pattern.
                        .byte           $00                 ; $0DEB: 00  ; Quadrature table row 1 start
                        .byte           $00                 ; $0DEC: 00  ; Quadrature state 0→0 (no change)
                        .byte           $00                 ; $0DED: 00  ; Quadrature state 0→1 (CW)
                        .byte           $00                 ; $0DEE: 00  ; Quadrature state 0→2 (CCW)
                        .byte           $04                 ; $0DEF: 04  ; Quadrature state 0→3 (error)
                        .byte           $05                 ; $0DF0: 05  ; Quadrature state 1→0 (CCW)
                        .byte           $01                 ; $0DF1: 01  ; Quadrature state 1→1 (no change)
                        .byte           $00                 ; $0DF2: 00  ; Quadrature state 1→2 (error)
                        .byte           $01                 ; $0DF3: 01  ; Quadrature state 1→3 (CW)
                        .byte           $05                 ; $0DF4: 05  ; Quadrature state 2→0 (CW)
                        .byte           $04                 ; $0DF5: 04  ; Quadrature state 2→1 (error)
                        .byte           $00                 ; $0DF6: 00  ; Quadrature state 2→2 (no change)
                        .byte           $00                 ; $0DF7: 00  ; Quadrature state 2→3 (CCW)
                        .byte           $00                 ; $0DF8: 00  ; Quadrature state 3→0 (error)
                        .byte           $00                 ; $0DF9: 00  ; Quadrature state 3→1 (CCW)
                        .byte           $00                 ; $0DFA: 00  ; Quadrature state 3→2 (CW)

; Y-axis quadrature EOR table (16 bytes). Drives YA1/YB1.
                        .byte           $00                 ; $0DFB: 00  ; Quadrature table row 2 start
                        .byte           $00                 ; $0DFC: 00  ; Alt quadrature mapping 0→0
                        .byte           $00                 ; $0DFD: 00  ; Alt quadrature mapping 0→1
                        .byte           $00                 ; $0DFE: 00  ; Alt quadrature mapping 0→2
                        .byte           $08                 ; $0DFF: 08  ; Alt quadrature mapping 0→3
                        .byte           $0A                 ; $0E00: 0A  ; Alt quadrature mapping 1→0
                        .byte           $02                 ; $0E01: 02  ; Alt quadrature mapping 1→1
                        .byte           $00                 ; $0E02: 00  ; Alt quadrature mapping 1→2
                        .byte           $02                 ; $0E03: 02  ; Alt quadrature mapping 1→3
                        .byte           $0A                 ; $0E04: 0A  ; Alt quadrature mapping 2→0
                        .byte           $08                 ; $0E05: 08  ; Alt quadrature mapping 2→1
                        .byte           $00                 ; $0E06: 00  ; Alt quadrature mapping 2→2
                        .byte           $00                 ; $0E07: 00  ; Alt quadrature mapping 2→3
                        .byte           $00                 ; $0E08: 00  ; Alt quadrature mapping 3→0
                        .byte           $00                 ; $0E09: 00  ; Alt quadrature mapping 3→1
                        .byte           $00                 ; $0E0A: 00  ; Alt quadrature mapping 3→2

; ────────────────────────────────────────────────────────────────────────────
; f_WriteAllPorts (0x0E0B)
; Purpose: Flush port shadows to hardware. Guarded: skips if IREventFlag
; bit 0 or IRInputReady is non-zero. Write order: A->B->D->C.
; ────────────────────────────────────────────────────────────────────────────
f_WriteAllPorts:
                        LDA             zp_IREventFlag      ; $0E0B: A5 0F  ; Load IREventFlag: check bit 0
                        AND             #$01                ; $0E0D: 29 01  ; Isolate IR-busy bit
                        ORA             zp_IRInputReady     ; $0E0F: 05 16  ; Combine with data-pending flag
                        BNE             SkipPortUpdate      ; $0E11: D0 11  ; Either set: skip all writes
                        LDA             zp_PortA            ; $0E13: A5 00  ; Load PortA shadow
                        STA             hw_PortA            ; $0E15: 85 80  ; Write to hw_PortA
                        LDA             zp_PortB            ; $0E17: A5 01  ; Load PortB shadow
                        STA             hw_PortB            ; $0E19: 85 81  ; Write to hw_PortB
                        LDA             zp_PortD            ; $0E1B: A5 02  ; Load PortD shadow
                        STA             hw_PortD            ; $0E1D: 85 83  ; Write to hw_PortD
                        LDA             zp_PortC            ; $0E1F: A5 03  ; Load PortC shadow
                        STA             hw_PortC            ; $0E21: 85 82  ; Write to hw_PortC
                        RTS                                 ; $0E23: 60  ; Return: all ports updated
SkipPortUpdate:
                        RTS                                 ; $0E24: 60  ; Skip path: return without writing

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessKeyboard (0x0E25)
; Purpose: Check for keyboard events and route. Media keys get hardcoded
; Space (0x40) injected. Wired keyboard timing validated against IRQ counter.
; Ends by clearing IREventFlag and StatusCheck for next cycle.
; BIT trick at 0x0E84: hides LDA #0x01 for keyboard-active path.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessKeyboard:
                        LDA             zp_IREventFlag      ; $0E25: A5 0F  ; Guard: same as f_WriteAllPorts
                        AND             #$01                ; $0E27: 29 01  ; Isolate error bit
                        ORA             zp_IRInputReady     ; $0E29: 05 16  ; Combine with IR pending flag
                        BNE             FinalCleanup        ; $0E2B: D0 55  ; IR active: skip keyboard this cycle
                        LDA             #$00                ; $0E2D: A9 00  ; A = 0: reset counters
                        STA             zp_IRQCount_LSB     ; $0E2F: 85 10  ; Reset IRQ counter LSB
                        STA             zp_IRQCount_MSB     ; $0E31: 85 11  ; Reset IRQ counter MSB
                        LDA             zp_PortA            ; $0E33: A5 00  ; Load PortA shadow for idle assertion
                        ORA             #$09                ; $0E35: 09 09  ; Force PA0/PA3 high during keyboard polling
                        STA             hw_PortA            ; $0E37: 85 80  ; Write to hw_PortA
                        LDA             zp_Remote_NP_Media  ; $0E39: A5 13  ; Check media key pending (bit 1)
                        AND             #$02                ; $0E3B: 29 02  ; Isolate media flag
                        BEQ             Process_FullKeyboard; $0E3D: F0 08  ; No media: skip Space injection

; ────────────────────────────────────────────────────────────────────────────
; Media space-injection path inside f_ProcessKeyboard.
; Reached when zp_Remote_NP_Media ($0013) bit 1 is set — but note: NO firmware path ever sets bit 1.
; All three writers of $0013 store either 0x00 (clear) or 0x01 (numpad press flag):
; $08A4: STA 0 (periodic clear)
; $0E72: STA 0 (after media key dispatch)
; $0E90: STA A where A is 0 or 1 (numpad press/release flag)
; Bit 1 (value $02) is never written. The BEQ at $0E3D therefore always branches to $0E47
; in normal execution. This code block ($0E3F-$0E45) is vestigial — likely a relic from an
; early firmware revision that had a separate media key pending flag before CPCP routing was
; implemented.
; If somehow reached: injects scancode $40 (Space) into zp_ScratchA and type indicator
; $06 into zp_ScratchB. These values are then used by the timing check at $0E47-$0E56
; and the dispatch at $0E6D (JSR f_ProcessKeyboardEvent).
; ────────────────────────────────────────────────────────────────────────────
                        LDA             #$40                ; $0E3F: A9 40  ; Inject Space (scancode $40) as the media key proxy to send to the Amiga
                        STA             zp_ScratchA         ; $0E41: 85 26  ; Stage Space in zp_ScratchA — used as timing reference and dispatch input
                        LDA             #$06                ; $0E43: A9 06  ; A = $06: media type indicator stored in zp_ScratchB
                        STA             zp_ScratchB         ; $0E45: 85 27  ; Stage type indicator in zp_ScratchB — read at $0E54 in the timing check loop

; ────────────────────────────────────────────────────────────────────────────
; Keyboard-lines idle check and IRQ-based debounce loop.
; PA0 (IRDT) or PA3 (PRDT) — whichever is the active protocol line — must be LOW (marking) for this loop to spin.
; If the line is idle (PA0=1 after AND mask): BNE diverts to BIT trick at $0E84 (FinalPortUpdate path); $0E58 is never reached.
; If the line is still marking: the 16-bit IRQ counter (zp_IRQCount_LSB:MSB) is compared against the timing reference in zp_ScratchA:ScratchB. The loop re-samples until the counter catches up
; ────────────────────────────────────────────────────────────────────────────

; Keyboard-lines idle check and IRQ-based debounce loop.
; PA0 (IRDT) or PA3 (PRDT) — whichever is the active protocol line — must be LOW (marking) for this loop to spin.
; If the line is idle (PA0=1 after AND mask): BNE diverts to BIT trick at $0E84 (FinalPortUpdate path); $0E58 is never reached.
; If the line is still marking:
; The 16-bit IRQ counter (zp_IRQCount_LSB:MSB) is compared against the timing reference in zp_ScratchA:ScratchB.
; The loop re-samples until the counter catches up
Process_FullKeyboard:
                        LDA             hw_PortA            ; $0E47: A5 80  ; Sample PortA: is the protocol line still active (marking)?
                        AND             zp_ProtocolMask     ; $0E49: 25 06  ; Mask to active protocol line (0x01=IR/PA0  0x06=wired kbd/PA1+PA2  0x08=PRDT/PA3)
                        BNE             FinalPortUpdate+1   ; $0E4B: D0 38  ; Line idle (carry set by BIT trick on idle path): skip to FinalPortUpdate. Line still active: fall through to timing check
                        LDA             zp_IRQCount_LSB     ; $0E4D: A5 10  ; Load IRQ tick counter LSB as elapsed-time reference
                        SEC                                 ; $0E4F: 38  ; SEC before 16-bit subtraction
                        SBC             zp_ScratchA         ; $0E50: E5 26  ; Subtract timing reference LSB (zp_ScratchA): set by media path ($0E41) or 0 otherwise
                        LDA             zp_IRQCount_MSB     ; $0E52: A5 11  ; Load IRQ tick counter MSB
                        SBC             zp_ScratchB         ; $0E54: E5 27  ; Subtract timing reference MSB (zp_ScratchB): set by media path ($0E43=0x06) or 0 otherwise
                        BCC             Process_FullKeyboard; $0E56: 90 EF  ; Carry clear = counter has not yet reached reference: re-sample PortA and subtract again

; Timing window elapsed (or protocol line confirmed active).
; All output ports are reset to their idle/inactive state before dispatching any pending remote event.
; PortB carries the CPCP nibble for U62 and the _KBSE line; resetting it to 0x0F clears any live CPCP command (key-up).
; PortC and PortD carry mouse and joystick quadrature; resetting them to 0xFF asserts all lines inactive for the Amiga.
                        LDA             #$0F                ; $0E58: A9 0F  ; A = 0x0F: idle PortB value (_KBSE high  AUS=1  CPCP=0)
                        STA             hw_PortB            ; $0E5A: 85 81  ; Reset hw_PortB: clears any live CPCP key command and restores _KBSE and AUS lines
                        LDA             #$FF                ; $0E5C: A9 FF  ; A = 0xFF: all port lines inactive
                        STA             hw_PortD            ; $0E5E: 85 83  ; Reset hw_PortD: de-assert all mouse quadrature and button outputs
                        STA             hw_PortC            ; $0E60: 85 82  ; Reset hw_PortC: de-assert all joystick quadrature and button outputs

; Dispatch any pending remote event. Priority: numpad (bit 0) is tested first via LSR; media (bit 1) checked only when numpad is absent.
; Both paths converge at FinalReset ($0E7C) to clear state. If neither flag is set  BEQ skips to FinalCleanup ($0E82).
                        LDA             zp_Remote_NP_Media  ; $0E62: A5 13  ; Reload zp_Remote_NP_Media to check for pending remote events
                        LSR             A                   ; $0E64: 4A  ; Shift bit 0 (numpad pending) into carry
                        BCS             Process_NP_Branch   ; $0E65: B0 10  ; Numpad event pending: branch to handler at $0E77
                        LDA             zp_Remote_NP_Media  ; $0E67: A5 13  ; Reload zp_Remote_NP_Media for media-key check
                        AND             #$02                ; $0E69: 29 02  ; Isolate bit 1: media key pending
                        BEQ             FinalCleanup        ; $0E6B: F0 15  ; Neither flag set: no event to dispatch; fall through to FinalCleanup
                        JSR             f_ProcessKeyboardEvent; $0E6D: 20 0E 0F  ; Media key pending: call f_ProcessKeyboardEvent to transmit the scancode via PA1/PA2
                        LDA             #$00                ; $0E70: A9 00  ; A = 0: clear remote flags after media dispatch
                        STA             zp_Remote_NP_Media  ; $0E72: 85 13  ; Clear zp_Remote_NP_Media: media event consumed
                        JMP             FinalReset          ; $0E74: 4C 7C 0E  ; Skip numpad handler; go directly to state reset
Process_NP_Branch:
                        LDA             #$00                ; $0E77: A9 00  ; A = 0: press flag for numpad key (0=press  passed to f_ProcessNumbPad)
                        JSR             f_ProcessNumbPad    ; $0E79: 20 90 0E  ; Send numpad scancode via f_ProcessNumbPad (table lookup + f_SendKeyboardSerial)

; State reset after event dispatch. Clears the prior-state registers so the next iteration treats every key as a fresh event rather than a repeat.
FinalReset:
                        LDA             #$00                ; $0E7C: A9 00  ; A = 0: clear prior-state registers
                        STA             zp_ModifierIndexPrior; $0E7E: 85 14  ; Clear zp_ModifierIndexPrior: next modifier frame always detected as changed
                        STA             zp_KeyboardIndexPrior; $0E80: 85 15  ; Clear zp_KeyboardIndexPrior: next key frame always detected as changed
FinalCleanup:
                        LDA             #$00                ; $0E82: A9 00  ; A = 0: cleanup
FinalPortUpdate:
                        BIT             $01A9               ; $0E84: 2C A9 01  ; BIT trick: hides LDA #0x01 from 0x0E4B path
                        STA             zp_KB_Temp          ; $0E87: 85 12  ; A->zp_KB_Temp: 1=enable repeat test, 0=disable
                        LDA             #$00                ; $0E89: A9 00  ; A = 0: clear cycle flags
                        STA             zp_IREventFlag      ; $0E8B: 85 0F  ; Clear IREventFlag: cycle complete
                        STA             zp_StatusCheck      ; $0E8D: 85 22  ; Clear StatusCheck: allow next acquisition
                        RTS                                 ; $0E8F: 60  ; Return to main loop

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessNumbPad (0x0E90)
; Purpose: Convert remote numpad button to Amiga scancode and transmit.
; Algorithm: store flag, IRCommandByte>>2, subtract 0x20, table lookup,
; ASL, merge press/release into bit 0, transmit.
; Table: tbl_NumPadScancodes (0x0F02), 12 entries.
; Indices >11 produce OOB reads into instruction bytes.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessNumbPad:
                        STA             zp_Remote_NP_Media  ; $0E90: 85 13  ; Store press/release flag (0=press, 1=release)
                        LDA             zp_IRCommandByte    ; $0E92: A5 07  ; Load button code from IR data
                        LSR             A                   ; $0E94: 4A  ; Shift right twice (divide by 4)
                        LSR             A                   ; $0E95: 4A  ; Shift right again (÷4 total)
                        SEC                                 ; $0E96: 38  ; SEC for subtraction
                        SBC             #$20                ; $0E97: E9 20  ; Subtract 0x20: create table index (0-11)
                        TAX                                 ; $0E99: AA  ; Transfer index to X
                        LDA             LAB_0f20+1,X        ; $0E9A: BD 02 0F  ; Load scancode from table[X]
                        ASL             A                   ; $0E9D: 0A  ; ASL: scancode x2 for press/release bit space
                        STA             zp_ScratchA         ; $0E9E: 85 26  ; Store doubled scancode in zp_ScratchA
                        LDA             zp_Remote_NP_Media  ; $0EA0: A5 13  ; Load press/release flag
                        AND             #$01                ; $0EA2: 29 01  ; Isolate bit 0
                        EOR             #$01                ; $0EA4: 49 01  ; Invert (Amiga convention: 0=release, 1=press)
                        ORA             zp_ScratchA         ; $0EA6: 05 26  ; Merge into bit 0
                        STA             zp_ScratchA         ; $0EA8: 85 26  ; Store final scancode in zp_ScratchA
                        JMP             Send_Key            ; $0EAA: 4C B4 0E  ; Tail-call f_SendKeyboardSerial

; ────────────────────────────────────────────────────────────────────────────
; f_SendKeyboardSerial ($0EAD-$0EEC).
; Purpose: Transmit one 8-bit Amiga scancode to the CIA over the PA1(_KBDATA)/PA2(_KBCLOCK) serial lines.
; Inputs: A = scancode byte (caller-supplied).
; bit 7 = 0: key press. bit 7 = 1: key release.
; Amiga keyboard serial protocol:
; - MSB-first transmission
; - Clock generated on PA2 (_KBCLOCK). CIA samples KDAT on the falling edge.
; - Data inverted: 0 on PA1 = send 1; 1 on PA1 = send 0.
; - Bit order on wire: 6-5-4-3-2-1-0-7 (up/down bit last per Amiga hardware spec).
; - CIA acknowledges by pulling _KBSE (PB2) low for ~20 µs.
; Entry points:
; $0EAD: normal entry (A = raw scancode from caller)
; $0EB4: Send_Key (A = prescrambled scancode; used by JMP tail-calls from f_ProcessNumbPad)
; RC4 coverage:
; Press (bit 7=0): $0EAD (ASL)  $0EAE (BCC taken)  $0EB2 (STA).
; Release (bit 7=1): $0EAD (ASL)  $0EAE (BCC not taken)  $0EB0 (ORA #$01)  $0EB2 (STA).
; Both paths are exercised by the press/release pair in f_ProcessFrontPanel.
; ────────────────────────────────────────────────────────────────────────────
f_SendKeyboardSerial:
                        ASL             A                   ; $0EAD: 0A  ; ASL A: shift scancode left; bit 7 exits into carry (1=release  0=press) and the remaining 7 bits shift up
                        BCC             StoreScancode       ; $0EAE: 90 02  ; Carry clear = press (bit 7 was 0): jump past the release-bit insertion to store
                        ORA             #$01                ; $0EB0: 09 01  ; Release path: carry was set (bit 7=1); set LSB to mark this as a key-up event in the Amiga protocol
StoreScancode:
                        STA             zp_ScratchA         ; $0EB2: 85 26  ; Store the transformed scancode for the 8-bit shift loop that follows
Send_Key:
                        SEI                                 ; $0EB4: 78  ; SEI: critical section for serial TX
WaitFor_KBSE:
                        LDA             hw_PortB            ; $0EB5: A5 81  ; Read PortB for _KBSE check
                        AND             #$04                ; $0EB7: 29 04  ; Mask _KBSE (PB2)
                        BEQ             WaitFor_KBSE        ; $0EB9: F0 FA  ; Spin until CIA ready
                        LDA             hw_PortB            ; $0EBB: A5 81  ; Read PortB
                        AND             #$FB                ; $0EBD: 29 FB  ; Clear _KBCLOCK (PB2 low)
                        STA             hw_PortB            ; $0EBF: 85 81  ; Write to hw_PortB
                        LDA             zp_PortA            ; $0EC1: A5 00  ; Load PortA shadow for data setup
                        ORA             #$06                ; $0EC3: 09 06  ; Set PA1/PA2 high (idle)
                        STA             zp_PortA            ; $0EC5: 85 00  ; Update shadow
                        STA             hw_PortA            ; $0EC7: 85 80  ; Write to hw_PortA
                        LDX             #$08                ; $0EC9: A2 08  ; X = 8: transmit 8 bits
BitLoop_Start:
                        ASL             zp_ScratchA         ; $0ECB: 06 26  ; Shift next bit out of zp_ScratchA (MSB first)
                        BCS             Branch_ClearKBDATA  ; $0ECD: B0 06  ; Bit=1: clear _KBDATA (inverted protocol)
                        LDA             hw_PortA            ; $0ECF: A5 80  ; Read PortA for bit 0 path
                        ORA             #$02                ; $0ED1: 09 02  ; Set _KBDATA high = send 0 (inverted)
                        BNE             Continue_Bit        ; $0ED3: D0 04  ; Branch to store (always taken)
Branch_ClearKBDATA:
                        LDA             hw_PortA            ; $0ED5: A5 80  ; Read PortA for bit 1 path
                        AND             #$FD                ; $0ED7: 29 FD  ; Clear _KBDATA low = send 1 (inverted)
Continue_Bit:
                        STA             hw_PortA            ; $0ED9: 85 80  ; Write bit to _KBDATA line
                        JSR             f_GenerateClock     ; $0EDB: 20 ED 0E  ; Generate _KBCLOCK pulse (~68.7 us)
                        DEX                                 ; $0EDE: CA  ; Decrement bit counter
                        BNE             BitLoop_Start       ; $0EDF: D0 EA  ; Loop until 8 bits sent
                        LDA             zp_PortA            ; $0EE1: A5 00  ; Restore PortA from shadow
                        STA             hw_PortA            ; $0EE3: 85 80  ; Write to hw_PortA
                        LDA             hw_PortB            ; $0EE5: A5 81  ; Read PortB
                        ORA             #$04                ; $0EE7: 09 04  ; Set _KBSE high (re-enable)
                        STA             hw_PortB            ; $0EE9: 85 81  ; Write to hw_PortB
                        CLI                                 ; $0EEB: 58  ; CLI: end critical section
                        RTS                                 ; $0EEC: 60  ; Return

; ────────────────────────────────────────────────────────────────────────────
; f_GenerateClock (0x0EED)
; Purpose: One _KBCLOCK pulse on PA2. LOW ~33 us, HIGH ~35 us, total ~68.7 us.
; CIA samples data on falling edge. Called once per bit.
; ────────────────────────────────────────────────────────────────────────────
f_GenerateClock:
                        LDY             #$08                ; $0EED: A0 08  ; Y = 8: pre-low delay count
OffLoop:
                        DEY                                 ; $0EEF: 88  ; Decrement delay
                        BNE             OffLoop             ; $0EF0: D0 FD  ; Loop until complete
                        LDA             hw_PortA            ; $0EF2: A5 80  ; Read PortA
                        AND             #$FB                ; $0EF4: 29 FB  ; Clear PA2: drive _KBCLOCK low
                        STA             hw_PortA            ; $0EF6: 85 80  ; Drive _KBCLOCK low (falling edge) — CIA latches KDAT here per Amiga keyboard spec (data set up ~20 us before clock falls)
                        LDY             #$08                ; $0EF8: A0 08  ; Y = 8: clock-low delay
OnLoop:
                        DEY                                 ; $0EFA: 88  ; Decrement
                        BNE             OnLoop              ; $0EFB: D0 FD  ; Loop
                        ORA             #$04                ; $0EFD: 09 04  ; Set PA2: release _KBCLOCK high
                        STA             hw_PortA            ; $0EFF: 85 80  ; Release _KBCLOCK high — CIA already latched KDAT on the falling edge at 0x0EF6; this rising edge only restores the clock line
                        RTS                                 ; $0F01: 60  ; Return

; Numpad scancode table (12 entries). 0=KP1, 1=KP2, 2=KP3, 3=Esc, 4=KP4, 5=KP5, 6=KP6, 7=KP0, 8=KP7, 9=KP8, 10=KP9, 11=KP Enter.
tbl_NumPadScancodes:
                        .byte           $1D                 ; $0F02: 1D  ; Number Pad 1
                        .byte           $1E                 ; $0F03: 1E  ; Number Pad 2
                        .byte           $1F                 ; $0F04: 1F  ; Number Pad 3
                        .byte           $45                 ; $0F05: 45  ; Number Pad Escape
                        .byte           $2D                 ; $0F06: 2D  ; Number Pad 4
                        .byte           $2E                 ; $0F07: 2E  ; Number Pad 5
                        .byte           $2F                 ; $0F08: 2F  ; Number Pad 6
                        .byte           $0F                 ; $0F09: 0F  ; Number Pad 0
                        .byte           $3D                 ; $0F0A: 3D  ; Number Pad 7
                        .byte           $3E                 ; $0F0B: 3E  ; Number Pad 8
                        .byte           $3F                 ; $0F0C: 3F  ; Number Pad 9
                        .byte           $43                 ; $0F0D: 43  ; Number Pad Enter

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessKeyboardEvent (0x0F0E)
; Compares current qualifier bitmask and keycode index against prior frame values.
; Transmits exactly one scancode per call if either has changed.
; Priority: qualifier change is handled before keycode change.
; Note: modifier in variable names (zp_ModifierIndexPrior etc.) reflects an
; earlier annotation error — the Amiga canonical term is qualifier key.
; ────────────────────────────────────────────────────────────────────────────
f_ProcessKeyboardEvent:
                        LDA             zp_IRCommandByte    ; $0F0E: A5 07  ; Load current modifier bitmask
                        CMP             zp_ModifierIndexPrior; $0F10: C5 14  ; Compare with prior
                        BNE             SendModifierValue   ; $0F12: D0 0F  ; Modifier changed: handle it before checking key (modifier has priority this call)
                        LDA             zp_KeyboardIndex    ; $0F14: A5 08  ; Unchanged: check keyboard index
                        CMP             zp_KeyboardIndexPrior; $0F16: C5 15  ; Compare with prior
                        BNE             ProcessKeyboardScancode; $0F18: D0 40  ; Key index also unchanged: both unchanged this frame — commit priors and return
                        LDA             zp_IRCommandByte    ; $0F1A: A5 07  ; No change: refresh prior values
                        STA             zp_ModifierIndexPrior; $0F1C: 85 14  ; Commit modifier as prior
                        LDA             zp_KeyboardIndex    ; $0F1E: A5 08  ; Load keyboard index
                        STA             zp_KeyboardIndexPrior; $0F20: 85 15  ; Commit key as prior
                        RTS                                 ; $0F22: 60  ; Nothing to transmit — return to main loop

; ────────────────────────────────────────────────────────────────────────────
; SendModifierValue (0x0F23)
; Modifier bitmask has changed. If non-zero, find the lowest set bit,
; look up its Amiga scancode in tbl_ModifierKeys[Y], and transmit as
; a key-press event. If zero, branch to Modifier_Default to send
; release events for each previously-held modifier.
; ────────────────────────────────────────────────────────────────────────────

; Modifier changed. Non-zero: scan bits LSB-first and transmit press for lowest set bit. Zero: release all.
SendModifierValue:
                        LDA             zp_IRCommandByte    ; $0F23: A5 07  ; Reload modifier bitmask
                        BEQ             Modifier_Default    ; $0F25: F0 1F  ; Modifier = 0x00: all released — branch to send release events from prior bitmask
                        STA             zp_ModifierIndexPrior; $0F27: 85 14  ; Record new modifier as prior
                        LDA             #$00                ; $0F29: A9 00  ; A = 0: press flag
                        STA             zp_ScratchB         ; $0F2B: 85 27  ; Set direction = press
                        LDA             zp_ModifierIndexPrior; $0F2D: A5 14  ; Reload for bit-scan
IterateModifiers:
                        LDY             #$00                ; $0F2F: A0 00  ; Y = 0: start from R.Shift
                        LDX             #$08                ; $0F31: A2 08  ; X = 8: test all 8 bits
NextModifier:
                        LSR             A                   ; $0F33: 4A  ; Shift next modifier bit into carry — carry set = this modifier active
                        BCS             SendModifier        ; $0F34: B0 05  ; Carry set: found lowest-active modifier bit — Y = table index for this modifier
                        INY                                 ; $0F36: C8  ; Not set: advance table index
                        DEX                                 ; $0F37: CA  ; Decrement bits remaining
                        BNE             NextModifier        ; $0F38: D0 F9  ; Loop until all tested
                        RTS                                 ; $0F3A: 60  ; All tested: return (shouldn't reach if !=0)
SendModifier:
                        LDA             tbl_ModifierKeys,Y  ; $0F3B: B9 52 0F  ; Load pre-shifted scancode from tbl_ModifierKeys[Y] — ASL at 0x0F3E makes the wire byte
                        ASL             A                   ; $0F3E: 0A  ; ASL: scancode x2 for press/release bit
                        ORA             zp_ScratchB         ; $0F3F: 05 27  ; Merge direction flag
                        STA             zp_ScratchA         ; $0F41: 85 26  ; Store wire byte in zp_ScratchA
                        JMP             Send_Key            ; $0F43: 4C B4 0E  ; Tail-call to f_SendKeyboardSerial — execution does not return here

; All modifiers released (modifier byte = 0x00). Send a release event for each bit set in the prior bitmask then clear the prior.
Modifier_Default:
                        LDA             #$01                ; $0F46: A9 01  ; Direction = 1 (release)
                        STA             zp_ScratchB         ; $0F48: 85 27  ; Store release flag
                        LDA             zp_ModifierIndexPrior; $0F4A: A5 14  ; Load prior bitmask — these are the modifiers that were pressed and now need releasing
                        LDX             #$00                ; $0F4C: A2 00  ; X = 0: clear prior
                        STX             zp_ModifierIndexPrior; $0F4E: 86 14  ; Clear ModifierIndexPrior
                        BEQ             IterateModifiers    ; $0F50: F0 DD  ; Branch always (A=0 after STX cleared the prior) — iterate over bits to release each

; ────────────────────────────────────────────────────────────────────────────
; tbl_QualifierKeys (0x0F52) — RENAME CANDIDATE from tbl_ModifierKeys
; Pre-shifted Amiga scancodes for the eight qualifier keys.
; ASL at 0x0F3E produces the final wire byte.
; Order matches IR bitmask LSB-first scan:
; Y=0:R.Shift(0x61) Y=1:R.Alt(0x65) Y=2:R.Amiga(0x67) Y=3:Ctrl(0x63)
; Y=4:L.Shift(0x60) Y=5:L.Alt(0x64) Y=6:L.Amiga(0x66) Y=7:CapsLock(0x62)
; Reboot combo: bits 4+5+6 (R.Amiga + L.Amiga + Ctrl = 0x70).
; ────────────────────────────────────────────────────────────────────────────

; Modifier key table (8 entries).
; Pre-shift raw scancodes;
; ASL at 0x0F3E creates wire byte.
; Y=0:R.Shift(0x61) Y=1:R.Alt(0x65) Y=2:R.Amiga(0x67) Y=3:Ctrl(0x63) Y=4:L.Shift(0x60) Y=5:L.Alt(0x64) Y=6:L.Amiga(0x66) Y=7:CapsLock(0x62).
; Reboot combo: bits 4+5+6 (R.Amiga+L.Amiga+Ctrl).
tbl_ModifierKeys:
                        .byte           $61                 ; $0F52: 61  ; Y=0: R.Shift — wire press=0xC2, release=0xC3 (IR bit0; single-key frame 1025)
                        .byte           $65                 ; $0F53: 65  ; Y=1: R.Alt   — wire press=0xCA, release=0xCB (IR bit2; single-key frame 1028)
                        .byte           $67                 ; $0F54: 67  ; Y=2: R.Amiga — wire press=0xCE, release=0xCF (IR bit4; single-key frame 1040)
                        .byte           $63                 ; $0F55: 63  ; Y=3: Control — wire press=0xC6, release=0xC7 (IR bit6; single-key frame 1088)
                        .byte           $60                 ; $0F56: 60  ; Y=4: L.Shift — wire press=0xC0, release=0xC1 (IR bit1; single-key frame 1026)
                        .byte           $64                 ; $0F57: 64  ; Y=5: L.Alt   — wire press=0xC8, release=0xC9 (IR bit3; single-key frame 1032)
                        .byte           $66                 ; $0F58: 66  ; Y=6: L.Amiga — wire press=0xCC, release=0xCD (IR bit5; single-key frame 1056)
                        .byte           $62                 ; $0F59: 62  ; Y=7: Caps Lock — wire press=0xC4, release=0xC5 (IR bit7; single-key frame 1152)

; ────────────────────────────────────────────────────────────────────────────
; f_ProcessKeyboardScancode (0x0F5A)
; Converts a decoded IR keyboard keycode index to an Amiga scancode and
; transmits it to the CIA over PA1 (_KBDATA) / PA2 (_KBCLOCK).
; Source: IR 40-bit frame decode via f_Decode40BitIRKeyboard.
; Not used for the wired CD1221 keyboard — that device talks directly to the CIA.
; ────────────────────────────────────────────────────────────────────────────

; Key index changed. Non-zero: transmit press for new key. Zero: transmit release for prior key.
ProcessKeyboardScancode:
                        LDA             zp_KeyboardIndex    ; $0F5A: A5 08  ; Loads IR keyboard table index (zp_KeyboardIndex). Non-zero = key pressed via IR; zero = release prior key
                        BEQ             HandleKeyRelease    ; $0F5C: F0 12  ; Index = 0x00: no key pressed this frame — send release for prior key

; Key press path - new key detected
                        STA             zp_KeyboardIndexPrior; $0F5E: 85 15  ; Store as previous
                        TAY                                 ; $0F60: A8  ; Y = index for table lookup
                        LDA             #$00                ; $0F61: A9 00  ; A = 0: press flag
                        STA             zp_ScratchB         ; $0F63: 85 27  ; Set direction = press

; Lookup scancode and transmit
TransmitScancode:
                        LDA             $107B,Y             ; $0F65: B9 7C 0F  ; Look up Amiga scancode from tbl_KeyboardScancodes[Y] — IR keyboard keycode index to Amiga scancode
                        ASL             A                   ; $0F68: 0A  ; Multiply scancode by 2 — bit 0 will hold press(0) or release(1) flag
                        ORA             zp_ScratchB         ; $0F69: 05 27  ; Merge press/release flag into bit 0 — result is the final wire byte
                        STA             zp_ScratchA         ; $0F6B: 85 26  ; Store final scancode in zp_ScratchA
                        JMP             Send_Key            ; $0F6D: 4C B4 0E  ; Tail-call to Send_Key — execution does not return here

; Key released (index = 0x00). Look up scancode for prior key and transmit release event.
HandleKeyRelease:
                        LDA             #$01                ; $0F70: A9 01  ; A = 1: release flag
                        STA             zp_ScratchB         ; $0F72: 85 27  ; Set direction = release
                        LDY             zp_KeyboardIndexPrior; $0F74: A4 15  ; Reload prior key index to look up its scancode for the release event
                        LDA             #$00                ; $0F76: A9 00  ; A = 0: clear prior
                        STA             zp_KeyboardIndexPrior; $0F78: 85 15  ; Clear prior key index (key is now released and acknowledged)
                        BEQ             TransmitScancode    ; $0F7A: F0 E9  ; Branch always (A=0 after clear) — transmit release using the prior index saved in Y

; ────────────────────────────────────────────────────────────────────────────
; tbl_KeyboardScancodes (0x0F7C)
; Maps IR keyboard keycode indices (0-127) to Amiga scancodes.
; Used exclusively by the IR keyboard path — not the wired CD1221.
; The CD1221 communicates directly with the CIA and does not use this table.
; NOTE: US Amiga keymap. Missing: KP ( ) / * +, European keys 0x30 and 0x2B.
; Space (0x40) is hardcoded at 0x0E3F rather than appearing here.
; ────────────────────────────────────────────────────────────────────────────

; Amiga keyboard scancode table. Indexed by KeyboardIndex (0-127).
; Maps CD1221 positions to Amiga raw scancodes. NOTE: appears to be US Amiga 1000 keymap.
; Missing: KP ()/*/+, European keys 0x30/0x2B, Space (hardcoded at 0x0E3F).
tbl_KeyboardScancodes:
                        .byte           $00                 ; $0F7C: 00  ; IR keyboard keycode table — indexed by zp_KeyboardIndex from 40-bit IR frame decode
                        .byte           $00                 ; $0F7D: 00  ; Key: `/~ (0x00)
                        .byte           $01                 ; $0F7E: 01  ; Key: 1/! (0x01)
                        .byte           $02                 ; $0F7F: 02  ; Key: 2/@ (0x02)
                        .byte           $03                 ; $0F80: 03  ; Key: 3/# (0x03)
                        .byte           $04                 ; $0F81: 04  ; Key: 4/$ (0x04)
                        .byte           $05                 ; $0F82: 05  ; Key: 5/% (0x05)
                        .byte           $06                 ; $0F83: 06  ; Key: 6/^ (0x06)
                        .byte           $07                 ; $0F84: 07  ; Key: 7/& (0x07)
                        .byte           $08                 ; $0F85: 08  ; Key: 8/* (0x08)
                        .byte           $09                 ; $0F86: 09  ; Key: 9/( (0x09)
                        .byte           $0A                 ; $0F87: 0A  ; Key: 0/) (0x0A)
                        .byte           $0B                 ; $0F88: 0B  ; Key: -/* (0x0B)
                        .byte           $0C                 ; $0F89: 0C  ; Key: =/+ (0x0C)
                        .byte           $41                 ; $0F8A: 41  ; Key: Backspace (0x41)
                        .byte           $42                 ; $0F8B: 42  ; Key: Tab (0x42)
                        .byte           $10                 ; $0F8C: 10  ; Key: Q (0x10)
                        .byte           $11                 ; $0F8D: 11  ; Key: W (0x11)
                        .byte           $12                 ; $0F8E: 12  ; Key: E (0x12)
                        .byte           $13                 ; $0F8F: 13  ; Key: R (0x13)
                        .byte           $14                 ; $0F90: 14  ; Key: T (0x14)
                        .byte           $15                 ; $0F91: 15  ; Key: Y (0x15)
                        .byte           $16                 ; $0F92: 16  ; Key: U (0x16)
                        .byte           $17                 ; $0F93: 17  ; Key: I (0x17)
                        .byte           $18                 ; $0F94: 18  ; Key: O (0x18)
                        .byte           $19                 ; $0F95: 19  ; Key: P (0x19)
                        .byte           $1A                 ; $0F96: 1A  ; Key: [/{ (0x1A)
                        .byte           $1B                 ; $0F97: 1B  ; Key: ]/} (0x1B)
                        .byte           $44                 ; $0F98: 44  ; Key: Return (0x44)
                        .byte           $00                 ; $0F99: 00
                        .byte           $20                 ; $0F9A: 20  ; Key: A (0x20)
                        .byte           $21                 ; $0F9B: 21  ; Key: S (0x21)
                        .byte           $22                 ; $0F9C: 22  ; Key: D (0x22)
                        .byte           $23                 ; $0F9D: 23  ; Key: F (0x23)
                        .byte           $24                 ; $0F9E: 24  ; Key: G (0x24)
                        .byte           $25                 ; $0F9F: 25  ; Key: H (0x25)
                        .byte           $26                 ; $0FA0: 26  ; Key: J (0x26)
                        .byte           $27                 ; $0FA1: 27  ; Key: K (0x27)
                        .byte           $28                 ; $0FA2: 28  ; Key: L (0x28)
                        .byte           $29                 ; $0FA3: 29  ; Key: semicolon/colon (0x29)
                        .byte           $2A                 ; $0FA4: 2A  ; Key: quote/doublequote (0x2A)
                        .byte           $00                 ; $0FA5: 00
                        .byte           $00                 ; $0FA6: 00
                        .byte           $00                 ; $0FA7: 00
                        .byte           $31                 ; $0FA8: 31  ; Key: Z (0x31)
                        .byte           $32                 ; $0FA9: 32  ; Key: X (0x32)
                        .byte           $33                 ; $0FAA: 33  ; Key: C (0x33)
                        .byte           $34                 ; $0FAB: 34  ; Key: V (0x34)
                        .byte           $35                 ; $0FAC: 35  ; Key: B (0x35)
                        .byte           $36                 ; $0FAD: 36  ; Key: N (0x36)
                        .byte           $37                 ; $0FAE: 37  ; Key: M (0x37)
                        .byte           $38                 ; $0FAF: 38  ; Key: comma/less (0x38)
                        .byte           $39                 ; $0FB0: 39  ; Key: period/greater (0x39)
                        .byte           $3A                 ; $0FB1: 3A  ; Key: slash/question (0x3A)
                        .byte           $00                 ; $0FB2: 00
                        .byte           $00                 ; $0FB3: 00
                        .byte           $00                 ; $0FB4: 00
                        .byte           $3B                 ; $0FB5: 3B  ; Unknown key (0x3B)
                        .byte           $00                 ; $0FB6: 00
                        .byte           $50                 ; $0FB7: 50  ; Key: F1 (0x50)
                        .byte           $51                 ; $0FB8: 51  ; Key: F2 (0x51)
                        .byte           $52                 ; $0FB9: 52  ; Key: F3 (0x52)
                        .byte           $53                 ; $0FBA: 53  ; Key: F4 (0x53)
                        .byte           $54                 ; $0FBB: 54  ; Key: F5 (0x54)
                        .byte           $55                 ; $0FBC: 55  ; Key: F6 (0x55)
                        .byte           $56                 ; $0FBD: 56  ; Key: F7 (0x56)
                        .byte           $57                 ; $0FBE: 57  ; Key: F8 (0x57)
                        .byte           $58                 ; $0FBF: 58  ; Key: F9 (0x58)
                        .byte           $59                 ; $0FC0: 59  ; Key: F10 (0x59)
                        .byte           $00                 ; $0FC1: 00
                        .byte           $00                 ; $0FC2: 00
                        .byte           $00                 ; $0FC3: 00
                        .byte           $00                 ; $0FC4: 00
                        .byte           $00                 ; $0FC5: 00
                        .byte           $00                 ; $0FC6: 00
                        .byte           $00                 ; $0FC7: 00
                        .byte           $00                 ; $0FC8: 00
                        .byte           $00                 ; $0FC9: 00
                        .byte           $00                 ; $0FCA: 00
                        .byte           $00                 ; $0FCB: 00
                        .byte           $00                 ; $0FCC: 00
                        .byte           $00                 ; $0FCD: 00
                        .byte           $00                 ; $0FCE: 00
                        .byte           $00                 ; $0FCF: 00
                        .byte           $45                 ; $0FD0: 45  ; Key: Escape (0x45)
                        .byte           $46                 ; $0FD1: 46  ; Key: Delete (0x46)
                        .byte           $5F                 ; $0FD2: 5F  ; Key: Help (0x5F)
                        .byte           $4C                 ; $0FD3: 4C  ; Key: Up Arrow (0x4C)
                        .byte           $4F                 ; $0FD4: 4F  ; Key: Left Arrow (0x4F)
                        .byte           $4E                 ; $0FD5: 4E  ; Key: Right Arrow (0x4E)
                        .byte           $4D                 ; $0FD6: 4D  ; Key: Down Arrow (0x4D)
                        .byte           $00                 ; $0FD7: 00
                        .byte           $00                 ; $0FD8: 00
                        .byte           $00                 ; $0FD9: 00
                        .byte           $00                 ; $0FDA: 00
                        .byte           $00                 ; $0FDB: 00
                        .byte           $00                 ; $0FDC: 00
                        .byte           $00                 ; $0FDD: 00
                        .byte           $00                 ; $0FDE: 00
                        .byte           $00                 ; $0FDF: 00
                        .byte           $00                 ; $0FE0: 00
                        .byte           $00                 ; $0FE1: 00
                        .byte           $00                 ; $0FE2: 00
                        .byte           $00                 ; $0FE3: 00
                        .byte           $00                 ; $0FE4: 00
                        .byte           $00                 ; $0FE5: 00
                        .byte           $0D                 ; $0FE6: 0D  ; Key: backslash/pipe (0x0D)
                        .byte           $00                 ; $0FE7: 00
                        .byte           $00                 ; $0FE8: 00
                        .byte           $00                 ; $0FE9: 00
                        .byte           $00                 ; $0FEA: 00
                        .byte           $00                 ; $0FEB: 00
                        .byte           $3D                 ; $0FEC: 3D  ; Numpad 7 (0x3D)
                        .byte           $3E                 ; $0FED: 3E  ; Numpad 8 (0x3E)
                        .byte           $3F                 ; $0FEE: 3F  ; Numpad 9 (0x3F)
                        .byte           $2D                 ; $0FEF: 2D  ; Numpad 4 (0x2D)
                        .byte           $2E                 ; $0FF0: 2E  ; Numpad 5 (0x2E)
                        .byte           $2F                 ; $0FF1: 2F  ; Numpad 6 (0x2F)
                        .byte           $1D                 ; $0FF2: 1D  ; Numpad 1 (0x1D)
                        .byte           $1E                 ; $0FF3: 1E  ; Numpad 2 (0x1E)
                        .byte           $1F                 ; $0FF4: 1F  ; Numpad 3 (0x1F)
                        .byte           $0F                 ; $0FF5: 0F  ; Numpad 0 (0x0F)
                        .byte           $3C                 ; $0FF6: 3C  ; Numpad period (0x3C)
                        .byte           $4A                 ; $0FF7: 4A  ; Numpad minus (0x4A)
                        .byte           $43                 ; $0FF8: 43  ; Numpad Enter (0x43)

; Unused ROM byte.
                        .byte           $FF                 ; $0FF9: FF  ; Unused ROM byte (0xFF)
NMIVector:
                        .word           NMI                 ; $0FFA: DA 0B  ; NMI vector -> 0x0BDA (RTI only, no NMI sources)
ResetVector:
                        .word           RES                 ; $0FFC: 00 08  ; Reset vector -> 0x0800
IRQVector:
                        .word           IRQ                 ; $0FFE: 96 0B  ; IRQ vector -> 0x0B96

; ────────────────────────────────────────────────────────────────────────────
; End of ROM
; ────────────────────────────────────────────────────────────────────────────
