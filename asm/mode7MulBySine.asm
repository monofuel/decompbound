; mode7MulBySine
; Ported from snes_src/mode7_mul.nim :: mode7MulBySine (evidence-preserving re-port).
;
; Mode-7 hardware multiply — M7A / M7B / MPYM
; (file 0x00B400 / SNES $C0B400).
;
; JSL-callable signed multiply that programs the PPU mode-7 multiply unit
; (M7A × M7B → 24-bit product at MPYL/MPYM/MPYH) using a ROM angle table for
; the second factor. ADOPTED into the region registry (adopted.nim);
; gold-gated by tests/test_regions.nim.
;
;
; --- mode7MulBySine ---
; Multiply A by sin-table[X − $40] via the mode-7 hardware multiplier.
;
; Entry (JSL): 16-bit A holds the signed multiplicand written to M7A
; (write-twice: low then high via XBA). X is an angle index; the routine
; computes `(X − $40) & $FF`, loads an 8-bit factor from the table at
; `$C0B425,X`, and writes it to M7B. Returns the high 16 bits of the
; 24-bit product (`LDA long $2135` → MPYM+MPYH) in A with 16-bit M.
;
; Evidence (registers):
; - long `$211B` M7A — written twice (lo/hi of entry A).
; - long `$211C` M7B — one byte from `Mode7AngleTable`.
; - long `$2135` MPYM — 16-bit read of product mid/high.
;
; Callers: JSL `$C0B400` from bank `$C4` (e.g. `$C42662`, `$C4B084`).
; Does not touch M7C/M7D or mode-7 scroll — multiply unit only.
;
; Named constants (values inlined below; names preserved as comments):
;   Mode7MulBySineOffset = $B400
;   Mode7MulBySineSnes = $C0B400
;   M7aReg = $211B
;     PPU: M7A — mode-7 matrix A / hardware multiply multiplicand (write-twice).
;   M7bReg = $211C
;     PPU: M7B — mode-7 matrix B / hardware multiply multiplier (write-once 8-bit).
;   MpymReg = $2135
;     PPU: MPYM — middle byte of the 24-bit product; 16-bit LDA also takes MPYH
;     at `$2136`, yielding the high 16 bits of M7A×M7B.
;   Mode7AngleTable = $C0B425
;     ROM sine/angle table indexed by (X − $40) & $FF. Data at `$C0B425`, not
;     adopted — only referenced by address.
;   Mode7AngleOrigin = $40
;     Angle-table origin: subtract before indexing so X=0 → table entry $C0.
;   ByteMask = $FF
;     Keep the adjusted angle in 0..255.
;   StatusM = $20
;
.a16
.i16
PHA
TXA
SEC
SBC #$40  ; Mode7AngleOrigin — Angle-table origin: subtract before indexing so X=0 → table entry $C0.
AND #$FF  ; ByteMask — Keep the adjusted angle in 0..255.
TAX
PLA
SEP #$20  ; StatusM
.a8
.i16
STA $00211B  ; M7aReg — PPU: M7A — mode-7 matrix A / hardware multiply multiplicand (write-twice).
XBA
STA $00211B  ; M7aReg — PPU: M7A — mode-7 matrix A / hardware multiply multiplicand (write-twice).
LDA $C0B425,X  ; Mode7AngleTable — ROM sine/angle table indexed by (X − $40) & $FF. Data at `$C0B425`, not
STA $00211C  ; M7bReg — PPU: M7B — mode-7 matrix B / hardware multiply multiplier (write-once 8-bit).
REP #$20  ; StatusM
.a16
.i16
LDA $002135  ; MpymReg — PPU: MPYM — middle byte of the 24-bit product; 16-bit LDA also takes MPYH
RTL
