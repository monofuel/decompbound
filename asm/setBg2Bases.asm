; setBg2Bases
; Ported from snes_src/bg_layer_setup.nim :: setBg2Bases (evidence-preserving re-port).
;
; PPU background layer setup — BGMODE / BGnSC / BGnNBA helpers
; (file 0x008D79 / SNES $C08D79 and siblings through $C08E5B).
;
; Boot and many scene transitions call these via JSL after loading A/X/Y with
; mode bits, tilemap VRAM word address, and character VRAM word address.
; They are NOT DMA or VRAM uploaders: every store targets a PPU configuration
; register ($2105 / $2107-$2109 / $210B-$210C) plus matching WRAM shadows.
; ADOPTED into the region registry (adopted.nim); gold-gated by
; tests/test_regions.nim.
;
;
; --- setBg2Bases ---
; Configure BG2 tilemap base/size ($2108) and BG2 character base ($210B hi).
;
; Entry (JSL): same A/X/Y convention as setBg1Bases. Packs size+base into
; `$0012` / `$2108`. For BG12NBA, keeps the low nibble of `$0015` (BG1 char)
; and sets the high nibble from Y's high byte (`AND #$F0` — no 4× LSR,
; because BG2 already owns bits 4-7). Clears BG2 scroll shadows `$0035` /
; `$0037`.
;
; Boot call: `LDY #$2000 / LDX #$5800 / LDA #$0001 / JSL $C08DDE`.
;
; Named constants (values inlined below; names preserved as comments):
;   SetBgModeOffset = $8D79
;   SetBgModeSnes = $C08D79
;   SetBg1BasesOffset = $8D9E
;   SetBg1BasesSnes = $C08D9E
;   SetBg2BasesOffset = $8DDE
;   SetBg2BasesSnes = $C08DDE
;   SetBg3BasesOffset = $8E1C
;   SetBg3BasesSnes = $C08E1C
;   BgModeReg = $2105
;     PPU: BGMODE — screen mode (bits 0-2) and BG character sizes.
;   Bg1ScReg = $2107
;     PPU: BG1SC / BG2SC / BG3SC — tilemap base (bits 2-7, units of $400) and
;     screen size (bits 0-1).
;   Bg2ScReg = $2108
;   Bg3ScReg = $2109
;   Bg12NbaReg = $210B
;     PPU: BG12NBA — BG1 char base in low nibble, BG2 in high (units of $1000).
;   Bg34NbaReg = $210C
;     PPU: BG34NBA — BG3 char base in low nibble, BG4 in high.
;   BgModeShadow = $0F
;     WRAM shadows of the PPU regs above (mirrored so game code can read them).
;   Bg1ScShadow = $11
;   Bg2ScShadow = $12
;   Bg3ScShadow = $13
;   Bg12NbaShadow = $15
;   Bg34NbaShadow = $16
;   Bg1ScrollH = $31
;     WRAM scroll shadows cleared when a BG layer is reconfigured (pairs are
;     H then V). Consumers treat these as BG1/BG2/BG3 camera offsets.
;   Bg1ScrollV = $33
;   Bg2ScrollH = $35
;   Bg2ScrollV = $37
;   Bg3ScrollH = $39
;   Bg3ScrollV = $3B
;   BgScSizeMask = $03
;     Masks for packing BGnSC / BGnNBA fields.
;   BgScBaseMask = $FC
;   HighNibbleMask = $F0
;   LowNibbleMask = $0F
;   StatusM = $20
;   StatusX = $10
;
.a16
.i16
PHP
SEP #$20  ; StatusM
.a8
.i16
REP #$10  ; StatusX
.a8
.i16
AND #$03  ; BgScSizeMask — Masks for packing BGnSC / BGnNBA fields.
STA $0012  ; Bg2ScShadow
REP #$20  ; StatusM
.a16
.i16
TXA
XBA
SEP #$20  ; StatusM
.a8
.i16
AND #$FC  ; BgScBaseMask
ORA $0012  ; Bg2ScShadow
STA $0012  ; Bg2ScShadow
STA $002108  ; Bg2ScReg
LDA $0015  ; Bg12NbaShadow
AND #$0F  ; LowNibbleMask
STA $0015  ; Bg12NbaShadow
REP #$20  ; StatusM
.a16
.i16
STZ $0035  ; Bg2ScrollH
STZ $0037  ; Bg2ScrollV
TYA
XBA
SEP #$20  ; StatusM
.a8
.i16
AND #$F0  ; HighNibbleMask
ORA $0015  ; Bg12NbaShadow
STA $0015  ; Bg12NbaShadow
STA $00210B  ; Bg12NbaReg — PPU: BG12NBA — BG1 char base in low nibble, BG2 in high (units of $1000).
PLP
RTL

