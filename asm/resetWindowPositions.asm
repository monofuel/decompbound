; resetWindowPositions
; Ported from snes_src/ppu_windows.nim :: resetWindowPositions (evidence-preserving re-port).
;
; PPU window helpers — W*SEL / TMW / TSW / W*LOG / WH*
; (file 0x00B047 / SNES $C0B047 and $C0B0AA).
;
; JSL-callable writers that program the SNES window unit from packed fields
; in A/X, or force window edges to the disabled `$00FF` pattern. ADOPTED into
; the region registry (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- resetWindowPositions ---
; Force WH0-WH3 to the open-edge pattern `$FF,$00,$FF,$00`.
;
; Entry (JSL): any M; forces 16-bit A. Writes long `$2126` (WH0+WH1) and
; long `$2128` (WH2+WH3) with `#$00FF` so each window pair spans the full
; horizontal range. Does not touch W*SEL / TMW / logic — only the position
; registers. Callers use this after `configurePpuWindows` (or alone) to
; clear leftover window geometry.
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
REP #$20  ; StatusM
.a16
.i16
LDA #$FF  ; WindowEdgesOpen — WH0=FF WH1=00 WH2=FF WH3=00 — full-range / effectively-open edges.
STA $002126  ; Wh0Reg — PPU: WH0 — 16-bit STA also covers WH1 at $2127; WH2/WH3 via $2128.
STA $002128  ; Wh2Reg
RTL
