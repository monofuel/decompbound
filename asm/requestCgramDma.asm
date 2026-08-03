; requestCgramDma
; Ported from snes_src/cgram_dma_request.nim :: requestCgramDma (evidence-preserving re-port).
;
; Set WRAM $0030 — CGRAM DMA table index request
; (file 0x00856B / SNES $C0856B).
;
; Goal 1.5 docs once guessed this was a "play music" entry. Disasm evidence
; says otherwise: the only absolute $0030 consumer in the NMI path indexes a
; CGRAM DMA descriptor table, not the APU. Named for what is proven. ADOPTED
; (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- requestCgramDma ---
; Store an 8-bit CGRAM DMA table index into WRAM $0030 and return.
;
; Entry (JSL): any M; forces 8-bit A for the store, restores 16-bit A.
; A (low byte) = index into the NMI CGRAM transfer table. Does not touch
; the APU.
;
; Evidence this is CGRAM, not music:
; - Writer: this routine is `SEP #$20 / STA $0030 / REP #$20 / RTL`.
; - Consumer $C081C8 (NMI path): `LDX $0030 / BEQ skip / LDA $8F94,X /
; STA $4302 / LDY $8F96,X / STY $2121` (CGADD) / `LDA #$2200 /
; STA $4300` (DMA mode write-twice to $2122 CGRAM) / `STY $0030` clears
; the latch after the transfer.
; - Callers load small constants (`#$08`, `#$18`) then JSL here — table
; indices, not song IDs. Song load/play goes through $C4FBBD → $C0AB06.
;
; Not named playMusic: that name would lie about the proven consumer.
;
; Named constants (values inlined below; names preserved as comments):
;   CgramDmaRequestOffset = $856B
;   CgramDmaRequestSnes = $C0856B
;   CgramDmaIndexLatch = $30
;     WRAM latch: non-zero = pending CGRAM DMA using this value as an index
;     into the descriptor table at $8F92/$8F94/$8F96 (see $C081C8).
;   StatusM = $20
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
STA $0030  ; CgramDmaIndexLatch — WRAM latch: non-zero = pending CGRAM DMA using this value as an index
REP #$20  ; StatusM
.a16
.i16
RTL
