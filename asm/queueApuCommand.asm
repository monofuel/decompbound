; queueApuCommand
; Ported from snes_src/queue_apu_cmd.nim :: queueApuCommand (evidence-preserving re-port).
;
; Queue an APU command byte into the 8-slot ring buffer
; (file 0x00ABE0 / SNES $C0ABE0).
;
; docs/audio.md lists $C0ABE0 among the SFX / fire-and-forget helpers next to
; the port pokes at $C0ABBD / $C0AC01 / $C0AC0C. This one does not touch
; $2140-$2143 itself: it enqueues `(A | $1ACA)` into WRAM `$1AC2,X` with
; write index `$00CA` (mod 8) and toggles phase bit 7 of `$1ACA`. Named for
; the verified queue, not a higher-level SFX id. ADOPTED mid-region after
; wait-idle ($C0ABC6); gold-gated by tests/test_regions.nim.
;
;
; --- queueApuCommand ---
; Enqueue A into the APU command ring buffer, or issue port-3 $57 if A is 0.
;
; Entry (JSL): any flags; forces 8-bit A/X. If A == 0, BEQ +$1B into the
; already-adopted writeApuPort3Cmd57 at $C0AC01 (poke $57 → $2143). If A is
; non-zero: X = `$00CA`, store `(A | $1ACA)` at `$1AC2,X`, advance the index
; mod 8, toggle bit 7 of `$1ACA`, restore 16-bit A/X, RTL.
;
; Evidence: disasm byte stream; docs/audio.md helper list; many call sites
; pass a non-zero command then JSL $C0ABE0. Does not claim the bytes are a
; particular SFX id — only the queue + phase behavior is proven.
;
; Named constants (values inlined below; names preserved as comments):
;   QueueApuCmdOffset = $ABE0
;   QueueApuCmdSnes = $C0ABE0
;   ApuCmdQueueIndex = $CA
;     Circular write index into the command queue (mod 8).
;   ApuCmdPhaseLatch = $1ACA
;     Phase / handshake latch OR'd into each queued byte; bit 7 toggled after
;     each non-zero enqueue (same pattern as $1ACB on writeApuPort1Toggled).
;   ApuCmdQueueBase = $1AC2
;     Eight-byte command queue base; STA abs,X with X = $00CA.
;   QueueIndexMask = $07
;   PhaseToggleBit = $80
;   BranchToPort3Cmd57 = $1B
;     Relative offset of BEQ when A == 0: lands on writeApuPort3Cmd57 ($C0AC01).
;     Zero argument means "issue port-3 $57" instead of enqueueing.
;   StatusMX = $30
;
.a16
.i16
SEP #$30  ; StatusMX
.a8
.i8
CMP #$00
BEQ +27  ; BranchToPort3Cmd57 — Relative offset of BEQ when A == 0: lands on writeApuPort3Cmd57 ($C0AC01).
LDX $00CA  ; ApuCmdQueueIndex — Circular write index into the command queue (mod 8).
ORA $1ACA  ; ApuCmdPhaseLatch — Phase / handshake latch OR'd into each queued byte; bit 7 toggled after
STA $1AC2,X  ; ApuCmdQueueBase — Eight-byte command queue base; STA abs,X with X = $00CA.
TXA
INC A
AND #$07  ; QueueIndexMask
STA $00CA  ; ApuCmdQueueIndex — Circular write index into the command queue (mod 8).
LDA #$80  ; PhaseToggleBit
EOR $1ACA  ; ApuCmdPhaseLatch — Phase / handshake latch OR'd into each queued byte; bit 7 toggled after
STA $1ACA  ; ApuCmdPhaseLatch — Phase / handshake latch OR'd into each queued byte; bit 7 toggled after
REP #$30  ; StatusMX
.a16
.i16
RTL
