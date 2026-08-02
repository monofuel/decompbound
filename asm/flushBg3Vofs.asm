; flushBg3Vofs
; Ported from snes_src/ppu_scroll.nim :: flushBg3Vofs (evidence-preserving re-port).
;
; PPU scroll-offset flusher — BG3VOFS ($2112)
; (file 0x00AD9F / SNES $C0AD9F).
;
; Small RTS-bounded helper that push-writes the BG3 vertical scroll register
; from its WRAM shadow pair. ADOPTED into the region registry (adopted.nim);
; gold-gated by tests/test_regions.nim.
;
;
; --- flushBg3Vofs ---
; Flush BG3 vertical scroll shadow `$003B`/`$003C` to BG3VOFS (`$2112`).
;
; Entry (JSR): any M; forces 8-bit A for the write-twice sequence, then
; restores 16-bit A before RTS. Each BG scroll register is write-twice on
; the SNES (low byte then high byte into the same MMIO address).
;
; Evidence: `LDA $003B / STA long $2112 / LDA $003C / STA long $2112`.
; Sole traced caller: `$C0F8BD` (`JSR $AD9F`) after `STA $003B` of a new
; vertical offset. Sibling of the NMI path that flushes all four layers
; from `$41..$60`, but this is the only standalone RTS-bounded BG3VOFS
; flusher in bank `$C0`.
;
; Named constants (values inlined below; names preserved as comments):
;   FlushBg3VofsOffset = $AD9F
;   FlushBg3VofsSnes = $C0AD9F
;   Bg3VofsReg = $2112
;     PPU: BG3VOFS — background 3 vertical offset (write-twice, low then high).
;   Bg3ScrollVLo = $3B
;     WRAM shadow of BG3 vertical scroll (low byte at $003B, high at $003C).
;     Same word the BG layer setup family clears via Bg3ScrollV ($003B).
;   Bg3ScrollVHi = $3C
;   StatusM = $20
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
LDA $003B  ; Bg3ScrollVLo — WRAM shadow of BG3 vertical scroll (low byte at $003B, high at $003C).
STA $002112  ; Bg3VofsReg — PPU: BG3VOFS — background 3 vertical offset (write-twice, low then high).
LDA $003C  ; Bg3ScrollVHi
STA $002112  ; Bg3VofsReg — PPU: BG3VOFS — background 3 vertical offset (write-twice, low then high).
REP #$20  ; StatusM
.a16
.i16
RTS
