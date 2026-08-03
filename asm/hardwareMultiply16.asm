; hardwareMultiply16
; Ported from snes_src/hw_multiply.nim :: hardwareMultiply16 (evidence-preserving re-port).
;
; CPU hardware multiply — WRMPYA / WRMPYB / RDMPY
; (file 0x008FF7 / SNES $C08FF7 and sibling $C09032).
;
; Hot JSL helpers that multiply via the S-CPU unit at `$4202`/`$4203`/`$4216`.
; `$C08FF7` is 16×8; `$C09032` is 16×16. ADOPTED into the region registry
; (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- hardwareMultiply16 ---
; Multiply 16-bit A by 16-bit Y via three WRMPY partial products.
;
; Entry (JSL): 16-bit A = multiplicand, 16-bit Y = multiplier. Saves Y at
; `$00B4` and A at `$00B6`, clears `$00B2`, bumps `$00C4`, then builds the
; product with three 8×8 hardware multiplies (16-bit `STA long $4202` writes
; WRMPYA+WRMPYB in one store; `LDA long $4216` reads RDMPY):
;
; 1. `Y.lo * Y.hi` path seeds `$00B0` from RDMPY (first partial).
; 2. `A.lo * Y.lo` folded into `$00B1` mid accumulator.
; 3. Final partial added into `$00B1`; returns `$00B0` in A.
;
; Evidence (registers / WRAM):
; - long `$4202` / `$4216` — WRMPY unit, three times.
; - abs `$00B4`/`$00B6` — saved factors; `$00B0`..`$00B2` product scratch.
; - abs `$00C4` — INC each call (counter only; not renamed further).
;
; Call sites: ~90 JSL `$C09032` (banks `$C0`/`$C2`/`$C3`/`$C4`/`$EF`); also
; re-entered from the adjacent `$C09086` DP-factor wrapper (not adopted).
;
; Named constants (values inlined below; names preserved as comments):
;   HardwareMultiplyOffset = $8FF7
;   HardwareMultiplySnes = $C08FF7
;   HardwareMultiply16Offset = $9032
;   HardwareMultiply16Snes = $C09032
;   WrmpyaReg = $4202
;     CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
;   WrmpybReg = $4203
;     CPU MMIO: WRMPYB — 8-bit multiplier; writing starts the multiply.
;   RdmpyReg = $4216
;     CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
;   HighByteMask = $FF00
;     Keep only the high byte of a 16-bit partial product when assembling the
;     16×8 result (XBA / AND #$FF00).
;   Mul16FactorY = $B4
;     16×16 scratch: multiplier word saved at `$00B4`, multiplicand at `$00B6`,
;     partial products / accumulators at `$00B0`..`$00B2`.
;   Mul16FactorA = $B6
;   Mul16ProductLo = $B0
;   Mul16ProductMid = $B1
;   Mul16ProductHi = $B2
;   Mul16FactorYHi = $B5
;     Multiplier high byte address (second byte of `Mul16FactorY`).
;   Mul16FactorALo = $B6
;     Multiplicand low / high split reads during the three WRMPY steps.
;   Mul16FactorAHiViaB4 = $B4
;   Mul16CallCounter = $C4
;     Call counter bumped on every 16×16 entry (observed INC; role beyond
;     counting is not yet pinned — do not invent a game-level name).
;     TODO: pin writer/readers of `$00C4` before promoting it in memory-map.md.
;   StatusM = $20
;   StatusX = $10
;
.a16
.i16
STY $00B4  ; Mul16FactorY — 16×16 scratch: multiplier word saved at `$00B4`, multiplicand at `$00B6`,
STA $00B6  ; Mul16FactorA
STZ $00B2  ; Mul16ProductHi
INC $00C4  ; Mul16CallCounter — Call counter bumped on every 16×16 entry (observed INC; role beyond
LDA $00B5  ; Mul16FactorYHi — Multiplier high byte address (second byte of `Mul16FactorY`).
SEP #$20  ; StatusM
.a8
.i16
TYA
REP #$20  ; StatusM
.a16
.i16
STA $004202  ; WrmpyaReg — CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
LDY $00B5  ; Mul16FactorYHi — Multiplier high byte address (second byte of `Mul16FactorY`).
REP #$20  ; StatusM
.a16
.i16
LDA $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
STA $00B0  ; Mul16ProductLo
TYA
STA $004202  ; WrmpyaReg — CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
LDA $00B6  ; Mul16FactorALo — Multiplicand low / high split reads during the three WRMPY steps.
SEP #$20  ; StatusM
.a8
.i16
LDA $00B4  ; Mul16FactorAHiViaB4
REP #$20  ; StatusM
.a16
.i16
TAY
LDA $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
CLC
ADC $00B1  ; Mul16ProductMid
STA $00B1  ; Mul16ProductMid
TYA
STA $004202  ; WrmpyaReg — CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
NOP
LDA $00B1  ; Mul16ProductMid
CLC
ADC $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
STA $00B1  ; Mul16ProductMid
LDA $00B0  ; Mul16ProductLo
RTL
