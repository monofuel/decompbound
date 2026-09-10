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
; Build source is registered in manifest.json and adopted.nim.
; integration_rng checks assembly identity and synthetic-seed CPU execution;
; e2e_rng_oracle checks calls observed while running the game.
;
; --- earthboundRandom ---
; Advance the RNG one step; returns a random byte 0..255 in A.
;
; Mixes the seed via the hardware multiplier: seed_hi.lo * seed_lo.lo, adds
; $6D to (seed_lo.lo << 8 | seed_hi.lo) to replace seed_hi, and rotates
; the product into seed_lo with a carry-driven high-bit set. Returns the
; rotated product byte. Reimplementation
; matched the live emulator 10/10 advances (seed + return byte).
;
; Entry: native mode, decimal clear, DBR mapping $0024/$0026 to WRAM.
; Saves flags via PHP and restores them with PLP; manages M itself.
; JSL callers include $C12DD7 in the menu service path.
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
;     Added to the reconstructed word (seed_lo.lo << 8 | seed_hi.lo).
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
ADC #$6D  ; RngStepConstant — add to the reconstructed word, not the old seed_hi.
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
