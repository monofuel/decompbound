; setBg4Bases
; Ported from snes_src/bg4_bases.nim :: setBg4Bases (evidence-preserving re-port).
;
; PPU BG4 tilemap/character base helper
; (file 0x008E5C / SNES $C08E5C).
;
; Completes the setBg1Bases / setBg2Bases / setBg3Bases family with the BG4
; half: BG4SC ($210A) plus the high nibble of BG34NBA ($210C). ADOPTED into
; the region registry (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- setBg4Bases ---
; Configure BG4 tilemap base/size ($210A) and BG4 character base ($210C hi).
;
; Entry (JSL): same A/X/Y convention as setBg1Bases / setBg3Bases. A =
; tilemap size bits 0-1 (masked with `#$03`); X = tilemap VRAM word address
; (high byte bits 2-7 become BG4SC base); Y = character VRAM word address
; (high byte becomes BG34NBA high nibble). Forces 8-bit A / 16-bit X,Y.
;
; Mirrors setBg3Bases on the opposite half of the shared registers:
; - Tilemap → `$0014` / `$210A` (BG4SC) instead of `$0013` / `$2109`.
; - Character base → high nibble of `$0016` / `$210C` (keeps BG3's low
; nibble via `AND #$0F`, then `AND #$F0` on Y's high byte — same packing
; as setBg2Bases, no 4× LSR, because BG4 already owns bits 4-7).
; - Clears BG4 scroll shadows `$003D` / `$003F`.
;
; Named constants (values inlined below; names preserved as comments):
;   SetBg4BasesOffset = $8E5C
;   SetBg4BasesSnes = $C08E5C
;   Bg4ScReg = $210A
;     PPU: BG4SC — tilemap base (bits 2-7, units of $400) and screen size (0-1).
;   Bg34NbaReg = $210C
;     PPU: BG34NBA — BG3 char base in low nibble, BG4 in high (units of $1000).
;   Bg4ScShadow = $14
;     WRAM shadows of the PPU regs above.
;   Bg34NbaShadow = $16
;   Bg4ScrollH = $3D
;     WRAM scroll shadows cleared when BG4 is reconfigured (H then V).
;   Bg4ScrollV = $3F
;   BgScSizeMask = $03
;     Masks for packing BGnSC / BGnNBA fields (same as bg_layer_setup.nim).
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
AND #$03  ; BgScSizeMask — Masks for packing BGnSC / BGnNBA fields (same as bg_layer_setup.nim).
STA $0014  ; Bg4ScShadow — WRAM shadows of the PPU regs above.
REP #$20  ; StatusM
.a16
.i16
TXA
XBA
SEP #$20  ; StatusM
.a8
.i16
AND #$FC  ; BgScBaseMask
ORA $0014  ; Bg4ScShadow — WRAM shadows of the PPU regs above.
STA $0014  ; Bg4ScShadow — WRAM shadows of the PPU regs above.
STA $00210A  ; Bg4ScReg — PPU: BG4SC — tilemap base (bits 2-7, units of $400) and screen size (0-1).
LDA $0016  ; Bg34NbaShadow
AND #$0F  ; LowNibbleMask
STA $0016  ; Bg34NbaShadow
REP #$20  ; StatusM
.a16
.i16
STZ $003D  ; Bg4ScrollH — WRAM scroll shadows cleared when BG4 is reconfigured (H then V).
STZ $003F  ; Bg4ScrollV
TYA
XBA
SEP #$20  ; StatusM
.a8
.i16
AND #$F0  ; HighNibbleMask
ORA $0016  ; Bg34NbaShadow
STA $0016  ; Bg34NbaShadow
STA $00210C  ; Bg34NbaReg — PPU: BG34NBA — BG3 char base in low nibble, BG4 in high (units of $1000).
PLP
RTL
