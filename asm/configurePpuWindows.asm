; configurePpuWindows
; Ported from snes_src/ppu_windows.nim :: configurePpuWindows (evidence-preserving re-port).
;
; PPU window helpers — W*SEL / TMW / TSW / W*LOG / WH*
; (file 0x00B047 / SNES $C0B047 and $C0B0AA).
;
; JSL-callable writers that program the SNES window unit from packed fields
; in A/X, or force window edges to the disabled `$00FF` pattern. ADOPTED into
; the region registry (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- configurePpuWindows ---
; Program window selects, main/sub window masks, and window logic.
;
; Entry (JSL): 16-bit A/X. A packs three 2-bit window-select fields in the
; low 6 bits (BG1-2, BG3-4, OBJ) plus a 5-bit TMW/TSW enable mask in the
; low 5 bits of the original value (restored via the third PLA). X is a
; non-zero "window-2 only / invert" flag: `TXY` saves it, and when Y≠0 each
; expanded select byte is `AND #$AA` and WBGLOG/WOBJLOG are written as 0
; instead of `$5555`.
;
; Evidence (registers written):
; - long `$2123` W12SEL, `$2124` W34SEL, `$2125` WOBJSEL — each from the
; expand table at `$C0B0A6` indexed by a 2-bit field of A.
; - long `$212E` TMW and `$212F` TSW — same `AND #$1F` byte.
; - long `$212A` (16-bit) WBGLOG+WOBJLOG — `$5555` or `$0000` by Y.
;
; Forces 8-bit A for the select packing, restores 16-bit A for the logic
; word, then RTL (does not PLP — entry flag width is not preserved beyond M).
;
; Named constants (values inlined below; names preserved as comments):
;   ConfigurePpuWindowsOffset = $B047
;   ConfigurePpuWindowsSnes = $C0B047
;   ResetWindowPositionsOffset = $B0AA
;   ResetWindowPositionsSnes = $C0B0AA
;   W12SelReg = $2123
;     PPU: W12SEL / W34SEL / WOBJSEL — which windows affect BG1-2 / BG3-4 / OBJ.
;   W34SelReg = $2124
;   WobjSelReg = $2125
;   TmwReg = $212E
;     PPU: TMW / TSW — window mask enable for main / sub screens.
;   TswReg = $212F
;   WbgLogReg = $212A
;     PPU: WBGLOG — 16-bit STA also covers WOBJLOG at $212B.
;   Wh0Reg = $2126
;     PPU: WH0 — 16-bit STA also covers WH1 at $2127; WH2/WH3 via $2128.
;   Wh2Reg = $2128
;   WindowSelExpandTable = $C0B0A6
;     ROM nibble expand table: 2-bit field → W*SEL byte (00 / 0F / F0 / FF).
;     Data at $C0B0A6, not adopted — only referenced by address.
;   Window2OnlyMask = $AA
;     When X≠0 on entry, keep only the "window 2" bits of each expanded nibble.
;   WindowFieldMask = $03
;     Low 2 bits of each packed field in A.
;   WindowMaskEnableBits = $1F
;     Low 5 bits of the original A become the TMW/TSW layer mask.
;   WindowLogicOrAll = $5555
;     WBGLOG/WOBJLOG = OR for every pair when windows are not inverted (X=0).
;   WindowEdgesOpen = $FF
;     WH0=FF WH1=00 WH2=FF WH3=00 — full-range / effectively-open edges.
;   StatusM = $20
;
.a16
.i16
TXY
SEP #$20  ; StatusM
.a8
.i16
PHA
PHA
AND #$03  ; WindowFieldMask — Low 2 bits of each packed field in A.
TAX
LDA $C0B0A6,X  ; WindowSelExpandTable — ROM nibble expand table: 2-bit field → W*SEL byte (00 / 0F / F0 / FF).
CPY #$00
BEQ w12Store
AND #$AA  ; Window2OnlyMask — When X≠0 on entry, keep only the "window 2" bits of each expanded nibble.
w12Store:
STA $002123  ; W12SelReg — PPU: W12SEL / W34SEL / WOBJSEL — which windows affect BG1-2 / BG3-4 / OBJ.
PLA
LSR A
LSR A
PHA
AND #$03  ; WindowFieldMask — Low 2 bits of each packed field in A.
TAX
LDA $C0B0A6,X  ; WindowSelExpandTable — ROM nibble expand table: 2-bit field → W*SEL byte (00 / 0F / F0 / FF).
CPY #$00
BEQ w34Store
AND #$AA  ; Window2OnlyMask — When X≠0 on entry, keep only the "window 2" bits of each expanded nibble.
w34Store:
STA $002124  ; W34SelReg
PLA
LSR A
LSR A
AND #$03  ; WindowFieldMask — Low 2 bits of each packed field in A.
TAX
LDA $C0B0A6,X  ; WindowSelExpandTable — ROM nibble expand table: 2-bit field → W*SEL byte (00 / 0F / F0 / FF).
CPY #$00
BEQ wobjStore
AND #$AA  ; Window2OnlyMask — When X≠0 on entry, keep only the "window 2" bits of each expanded nibble.
wobjStore:
STA $002125  ; WobjSelReg
PLA
AND #$1F  ; WindowMaskEnableBits — Low 5 bits of the original A become the TMW/TSW layer mask.
STA $00212E  ; TmwReg — PPU: TMW / TSW — window mask enable for main / sub screens.
STA $00212F  ; TswReg
REP #$20  ; StatusM
.a16
.i16
LDA #$5555  ; WindowLogicOrAll — WBGLOG/WOBJLOG = OR for every pair when windows are not inverted (X=0).
CPY #$00
BEQ wlogStore
LDA #$00
wlogStore:
STA $00212A  ; WbgLogReg — PPU: WBGLOG — 16-bit STA also covers WOBJLOG at $212B.
RTL

