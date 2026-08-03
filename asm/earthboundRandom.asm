; earthboundRandom
; Ported from snes_src/rng.nim :: earthboundRandom (evidence-preserving re-port).
;
; EarthBound's pseudo-random number generator (file 0x008E9A / SNES $C08E9A).
;
; The SNES has no hardware entropy, so "randomness" is this deterministic PRNG
; over a 32-bit seed in WRAM. Same seed + same call count => same sequence, which
; is why a fixed save-state replays byte-identically (verified: seed at $0024
; reproduced across runs). RE'd 2026-07-21 (dynamic trace + round-trip).
;
; Documentation of the understood routine, expressed through `snesAsm` so it
; reads as annotated assembly. ADOPTED into the region registry (adopted.nim):
; convert_all carves these 56 bytes out of the enclosing traced region
; (0x008C6D-0x008F97), so this curated source — not generated scaffold —
; produces $C08E9A in the build. Gold-gated two ways: tests/test_regions.nim
; (byte-exact vs gold, un-fakeable) and tests/test_rng.nim (routine fully
; covered by one region). This is the first mid-region Goal 1.5 adoption.
;
;
; --- earthboundRandom ---
; Advance the RNG one step; returns a random byte 0..255 in A.
;
; Mixes the seed via the hardware multiplier: seed_hi.lo * seed_lo.lo, folds
; +$6D into seed_hi, rotates the product into seed_lo (with a carry-driven
; high-bit set), and returns the rotated product byte. Reimplementation
; matched the live emulator 10/10 advances (seed + return byte).
;
; Entry: any flags (saves via PHP, manages M itself). Called via JSL only
; (59 sites); e.g. $C2008C gates a battle roll, $C02686 branches ~1/16.
;
; Named constants (values inlined below; names preserved as comments):
;   RngAdvanceOffset = $8E9A
;   RngAdvanceSnes = $C08E9A
;   RngSeedLo = $24
;     32-bit RNG seed in WRAM, little-endian: lo word $0024, hi word $0026.
;     Cold-initialised to $5678_1234 at $C08121 (LDA #$1234;STA $0024;
;     LDA #$5678;STA $0026) — the fixed seed that makes cold boot deterministic.
;   RngSeedHi = $26
;   MultiplyInput = $4202
;     $4202 = WRMPYA/WRMPYB (an unsigned 8x8 multiply input pair); a 16-bit STA
;     loads both. Product reads back at $4216 (RDMPYL/H) a few cycles later.
;   MultiplyResult = $4216
;   RngStepConstant = $6D
;     Odd additive constant folded into the high word each step (LCG-like stir).
;   RngLowMix = $03
;     Low two bits of the rotated product mix into the low word; if the final
;     ROR sets carry, the high bit is forced (keeps the low word from decaying).
;   RngHighBit = $8000
;   ReturnByteMask = $FF
;   StatusM = $20
;
.a16
.i16
PHP
REP #$20  ; StatusM
.a16
.i16
LDA $0024  ; RngSeedLo — seed_lo -> A (16-bit)
SEP #$20  ; StatusM
.a8
.i16
XBA  ; stash seed_lo.lo in B
LDA $0026  ; RngSeedHi — seed_hi.lo -> A (8-bit)
REP #$20  ; StatusM
.a16
.i16
STA $004202  ; MultiplyInput — WRMPYA = seed_hi.lo, WRMPYB = seed_lo.lo
CLC
ADC #$6D  ; RngStepConstant — seed_hi += $6D
STA $0026  ; RngSeedHi
LDA $004216  ; MultiplyResult — 16-bit product
ROR A
ROR A
PHA
AND #$03  ; RngLowMix — product bits 1..0
CLC
ADC $0024  ; RngSeedLo — 32-bit RNG seed in WRAM, little-endian: lo word $0024, hi word $0026.
ROR A
BCC seedLoStore
ORA #$8000  ; RngHighBit — carry set -> force high bit
seedLoStore:
STA $0024  ; RngSeedLo — new seed_lo
PLA
ROR A
ROR A
AND #$FF  ; ReturnByteMask — return byte in A
PLP
RTL
