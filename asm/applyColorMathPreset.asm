; applyColorMathPreset
; Ported from snes_src/ppu_color_math.nim :: applyColorMathPreset (evidence-preserving re-port).
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
; --- applyColorMathPreset ---
; Load a color-math preset: shadows $001A/$001B plus CGWSEL/CGADSUB.
;
; Entry (JSL): 16-bit A holds the preset index (low byte used after TAX).
; Forces 8-bit A for the table loads, restores 16-bit A before RTL.
;
; Evidence: `TAX` then four `LDA longx $C0xxxx / STA ...` pairs write
; `$001A`, `$001B`, long `$2130` (CGWSEL), and long `$2131` (CGADSUB) from
; the parallel ROM tables immediately following this routine. Callers JSL
; with small constants (scene/battle color-math modes). Does not touch
; COLDATA — that is `setFixedColorRgb` next door.
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
TAX
SEP #$20  ; StatusM
.a8
.i16
LDA $C0AFF1,X  ; PresetShadowATable — ROM tables indexed by the preset number (A on entry → TAX).
STA $001A  ; ColorMathShadowA — WRAM shadows filled by the preset tables (main/sub screen designation
LDA $C0AFFC,X  ; PresetShadowBTable
STA $001B  ; ColorMathShadowB
LDA $C0B006,X  ; PresetCgwselTable
STA $002130  ; CgwselReg — PPU: CGWSEL — color-math enable / clip / fixed-vs-subscreen select.
LDA $C0B010,X  ; PresetCgadsubTable
STA $002131  ; CgadsubReg — PPU: CGADSUB — add/sub mode and per-layer math enable mask.
REP #$20  ; StatusM
.a16
.i16
RTL

