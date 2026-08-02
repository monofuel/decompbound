; setBg3Bases
; Ported from snes_src/bg_layer_setup.nim :: setBg3Bases (evidence-preserving re-port).
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
; --- setBg3Bases ---
; Configure BG3 tilemap base/size ($2109) and BG3 character base ($210C lo).
;
; Entry (JSL): same A/X/Y convention as setBg1Bases. Writes `$0013` /
; `$2109` for the tilemap, and updates the low nibble of `$0016` /
; `$210C` (BG34NBA) from Y via 4× LSR — same packing as setBg1Bases but
; on the BG3/BG4 character-base register. Clears BG3 scroll shadows
; `$0039` / `$003B`. Sibling `$C08E5C` does the BG4 half and is not adopted.
;
; Boot call: `LDY #$6000 / LDX #$7C00 / LDA #$0000 / JSL $C08E1C`.
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
STA $0013  ; Bg3ScShadow
REP #$20  ; StatusM
.a16
.i16
TXA
XBA
SEP #$20  ; StatusM
.a8
.i16
AND #$FC  ; BgScBaseMask
ORA $0013  ; Bg3ScShadow
STA $0013  ; Bg3ScShadow
STA $002109  ; Bg3ScReg
LDA $0016  ; Bg34NbaShadow
AND #$F0  ; HighNibbleMask
STA $0016  ; Bg34NbaShadow
REP #$20  ; StatusM
.a16
.i16
STZ $0039  ; Bg3ScrollH
STZ $003B  ; Bg3ScrollV
TYA
XBA
SEP #$20  ; StatusM
.a8
.i16
LSR A
LSR A
LSR A
LSR A
ORA $0016  ; Bg34NbaShadow
STA $0016  ; Bg34NbaShadow
STA $00210C  ; Bg34NbaReg — PPU: BG34NBA — BG3 char base in low nibble, BG4 in high.
PLP
RTL
