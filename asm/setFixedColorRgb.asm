; setFixedColorRgb
; Ported from snes_src/ppu_color_math.nim :: setFixedColorRgb (evidence-preserving re-port).
;
; PPU color-math helpers — CGWSEL / CGADSUB / COLDATA
; (file 0x00AFCD / SNES $C0AFCD and siblings through $C0B046).
;
; Small JSL-callable register writers used by scene / battle transitions to
; load a color-math preset, program the fixed color (COLDATA), or poke
; CGWSEL+CGADSUB directly. ADOPTED into the region registry (adopted.nim);
; gold-gated by tests/test_regions.nim.
;
;
; --- setFixedColorRgb ---
; Program COLDATA ($2132) with separate R/G/B intensities from A/X/Y.
;
; Entry (JSL): any M; forces 8-bit A. A = red (0-31), X = green, Y = blue
; (low 5 bits used; high bits of each are masked off). Each component is
; ORA'd with its COLDATA channel-select bit and written write-once to
; `$2132` (hardware latches R, then G, then B on successive writes).
; Restores 16-bit A before RTL.
;
; Evidence: `AND #$1F / ORA #$20 / STA long $2132` then the same for X with
; `#$40` and Y with `#$80`. Sibling of `writeColorMathRegs` (CGWSEL/CGADSUB).
;
; Named constants (values inlined below; names preserved as comments):
;   ApplyColorMathPresetOffset = $AFCD
;   ApplyColorMathPresetSnes = $C0AFCD
;   SetFixedColorRgbOffset = $B01A
;   SetFixedColorRgbSnes = $C0B01A
;   WriteColorMathRegsOffset = $B039
;   WriteColorMathRegsSnes = $C0B039
;   CgwselReg = $2130
;     PPU: CGWSEL — color-math enable / clip / fixed-vs-subscreen select.
;   CgadsubReg = $2131
;     PPU: CGADSUB — add/sub mode and per-layer math enable mask.
;   ColdataReg = $2132
;     PPU: COLDATA — fixed-color write; channel select in bits 5-7, intensity 0-4.
;   ColorMathShadowA = $1A
;     WRAM shadows filled by the preset tables (main/sub screen designation
;     style bytes — consumers read these; this routine does not STA $212C/$212D).
;   ColorMathShadowB = $1B
;   PresetShadowATable = $C0AFF1
;     ROM tables indexed by the preset number (A on entry → TAX).
;     Four parallel 10/11-byte rows live at $C0AFF1 / $C0AFFC / $C0B006 / $C0B010
;     (data, not adopted — only the loader is curated).
;   PresetShadowBTable = $C0AFFC
;   PresetCgwselTable = $C0B006
;   PresetCgadsubTable = $C0B010
;   ColdataRedSelect = $20
;     COLDATA channel-select bits ORA'd onto the low 5 intensity bits.
;   ColdataGreenSelect = $40
;   ColdataBlueSelect = $80
;   ColdataIntensityMask = $1F
;   StatusM = $20
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
AND #$1F  ; ColdataIntensityMask
ORA #$20  ; ColdataRedSelect — COLDATA channel-select bits ORA'd onto the low 5 intensity bits.
STA $002132  ; ColdataReg — PPU: COLDATA — fixed-color write; channel select in bits 5-7, intensity 0-4.
TXA
AND #$1F  ; ColdataIntensityMask
ORA #$40  ; ColdataGreenSelect
STA $002132  ; ColdataReg — PPU: COLDATA — fixed-color write; channel select in bits 5-7, intensity 0-4.
TYA
AND #$1F  ; ColdataIntensityMask
ORA #$80  ; ColdataBlueSelect
STA $002132  ; ColdataReg — PPU: COLDATA — fixed-color write; channel select in bits 5-7, intensity 0-4.
REP #$20  ; StatusM
.a16
.i16
RTL

