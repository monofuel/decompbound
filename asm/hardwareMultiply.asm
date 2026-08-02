; hardwareMultiply
; Ported from snes_src/hw_multiply.nim :: hardwareMultiply (evidence-preserving re-port).
;
; CPU hardware multiply — WRMPYA / WRMPYB / RDMPY
; (file 0x008FF7 / SNES $C08FF7 and sibling $C09032).
;
; Hot JSL helpers that multiply via the S-CPU unit at `$4202`/`$4203`/`$4216`.
; `$C08FF7` is 16×8; `$C09032` is 16×16. ADOPTED into the region registry
; (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- hardwareMultiply ---
; Multiply 16-bit A by 8-bit Y via WRMPYA/WRMPYB; return 16-bit product in A.
;
; Entry (JSL): A is the 16-bit multiplicand, Y the 8-bit multiplier (low
; byte used). Forces 16-bit X (`REP #$10`). Two paths:
;
; 1. **A high ≠ 0** (`XBA` then fall through): compute `Y * A.hi` into Y
; (partial), then `Y * A.lo` and add `(partial << 8)` — full 16×8.
; 2. **A high == 0** (branch to `mul8`): single `Y * A.lo` via WRMPY.
;
; Evidence (registers):
; - long `$4202` WRMPYA — written with the current 8-bit factor (via 16-bit
; STA of Y or the low product path).
; - long `$4203` WRMPYB — written with A.hi on the wide path only.
; - long `$4216` RDMPY — 16-bit product read after each multiply.
;
; Timing: two NOPs after WRMPYA before reading RDMPY on each path (hardware
; needs 8 machine cycles; the surrounding ops cover the rest).
;
; Call sites: ~600 JSL `$C08FF7` across banks `$C0`/`$C1` (geometry, battle,
; camera). Sibling `hardwareMultiply16` at `$C09032` covers full 16×16.
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
REP #$10  ; StatusX
.a16
.i16
XBA
BEQ mul8
SEP #$20  ; StatusM
.a8
.i16
XBA
PHA
TYA
REP #$20  ; StatusM
.a16
.i16
STA $004202  ; WrmpyaReg — CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
NOP
NOP
LDA $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
TAY
SEP #$20  ; StatusM
.a8
.i16
PLA
STA $004203  ; WrmpybReg — CPU MMIO: WRMPYB — 8-bit multiplier; writing starts the multiply.
REP #$20  ; StatusM
.a16
.i16
TYA
XBA
AND #$FF00  ; HighByteMask — Keep only the high byte of a 16-bit partial product when assembling the
CLC
ADC $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
RTL
mul8:
SEP #$20  ; StatusM
.a8
.i16
TYA
REP #$20  ; StatusM
.a16
.i16
STA $004202  ; WrmpyaReg — CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
NOP
NOP
LDA $004216  ; RdmpyReg — CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
RTL

