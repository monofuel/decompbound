; Route updates/previews, APU $05D8..05FB / file $26011A..26013D (36 bytes).
; Resident-loop entry, DP zero: $05D8 calls sequence update and port exchange.
; $05E0 preview entry tests activity $04; active previews visit all eight
; even channel offsets, calling $0DD0 only when cursor high byte $31+X != 0.
; Preview preserves persistent phase/counters through its callees, but may
; update derived gain/scratch and DSP ports. Active exit X=16, $47=0, C=1/N=0/Z=1;
; inactive exit A=0, X/Y preserved. H/V and A/Y otherwise depend on callees.
; Native calls balance SP; neither entry RETs. Both join $0546's DSP flush.
; Full-update callee effects and mode routing are detailed in docs/audio.md.
    .org $05D8
spcRouteSequenceUpdate:
    CALL $07F9             ; Normal sequence/channel update, gated inside its callee.
    CALL $0625             ; Publish activity on port zero and obtain a stable input.
    BRA finishUpdate

; No-carry phase entry $05E0: preview without advancing saved channel phases.
spcRouteSequencePreview:
    MOV A, $04
    BEQ finishPreview
    MOV X, #$00
    MOV $47, #$01
nextPreviewChannel:
    MOV A, $31+X           ; A high-byte-zero cursor is inactive, even if low != 0.
    BEQ advancePreview
    CALL $0DD0             ; Volume, pan and pitch preview chain; preserves X.
advancePreview:
    INC X
    INC X
    ASL $47
    BNE nextPreviewChannel
finishPreview:
    JMP $0546

finishUpdate:
    JMP $0546              ; Original distinct jump site; do not fold it into the other.
