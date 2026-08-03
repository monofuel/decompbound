; sramMirrorPiracyCheck
; Ported from snes_src/sram_piracy.nim :: sramMirrorPiracyCheck (evidence-preserving re-port).
;
; SRAM mirror anti-piracy check (file 0x00A11C / SNES $C0A11C).
; First Goal 1.5 adoption: curated names and constants, same assembler as
; generated regions. See docs/goal-1.5.md.
;
;
; --- sramMirrorPiracyCheck ---
; Copier detection via SRAM bank mirrors.
;
; Writes distinct bytes to $30:7FF0 and $31:7FF0. On real 8KB cart SRAM
; those addresses alias, so CMP sees equal values and the routine continues.
; Oversized copier SRAM keeps the banks separate; the mismatch path long-
; jumps to the crime-lecture screen at $C30100.
;
; On success, samples STAT78 ($213F), gates on bit 4, then either RTL or
; restores a caller direct-page frame and long-jumps to $C30142.
;
; Entry: native mode, 16-bit A/X (M/X clear). Clobbers A; uses long stores.
; Called via JSL (see $C0B9A8).
;
; Named constants (values inlined below; names preserved as comments):
;   SramPiracyCheckOffset = $A11C
;   SramPiracyCheckSnes = $C0A11C
;   SramProbeA = $307FF0
;     HiROM cart window: banks $20-$3F / $A0-$BF, $6000-$7FFF → 8KB battery
;     SRAM. $30:7FF0 and $31:7FF0 both map to the same physical byte on an
;     8KB cart; oversized copier SRAM keeps them separate.
;   SramProbeB = $317FF0
;   SramProbePattern = $30
;     Distinct probe values written to A then B (INC A makes B = A+1).
;   Stat78Addr = $213F
;     PPU status register STAT78. Mask is bit 4; full meaning still open.
;   Stat78GateMask = $10
;     TODO: confirm what STAT78 bit 4 gates here (PPU2 version nibble vs field).
;   CallerFrameDelta = $0100
;     Bytes subtracted from S after PLA before installing a new direct page.
;   PiracyLectureAddr = $C30100
;     Long jump when SRAM mirrors do not collide (copier / bad cart path).
;   BootContinueAddr = $C30142
;     Long jump when the cart passes the mirror test and STAT78 gate is set.
;   StatusM = $20
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
LDA #$30  ; SramProbePattern — Distinct probe values written to A then B (INC A makes B = A+1).
STA $307FF0  ; SramProbeA — HiROM cart window: banks $20-$3F / $A0-$BF, $6000-$7FFF → 8KB battery
INC A
STA $317FF0  ; SramProbeB
CMP $307FF0  ; SramProbeA — HiROM cart window: banks $20-$3F / $A0-$BF, $6000-$7FFF → 8KB battery
BEQ sramMirrorsOk
; Mirrors did not collide: treat as copier / oversized SRAM.
REP #$20  ; StatusM
.a16
.i16
PLA
TSC
SBC #$0100  ; CallerFrameDelta — Bytes subtracted from S after PLA before installing a new direct page.
TCD
JML $C30100  ; PiracyLectureAddr — Long jump when SRAM mirrors do not collide (copier / bad cart path).
sramMirrorsOk:
; Branch target still has 8-bit A from the entry SEP; linear flag tracking
; would inherit the fall-through path's REP, so re-assert m8 here.
.a8
.i16
LDA $00213F  ; Stat78Addr — PPU status register STAT78. Mask is bit 4; full meaning still open.
AND #$10  ; Stat78GateMask — TODO: confirm what STAT78 bit 4 gates here (PPU2 version nibble vs field).
BEQ returnNative
REP #$20  ; StatusM
.a16
.i16
PLA
TSC
SBC #$0100  ; CallerFrameDelta — Bytes subtracted from S after PLA before installing a new direct page.
TCD
JML $C30142  ; BootContinueAddr — Long jump when the cart passes the mirror test and STAT78 gate is set.
returnNative:
REP #$20  ; StatusM
.a16
.i16
RTL
