; Native finish bridge, APU $1810..1812 / file $261352..261354 (3 bytes).
; Original port-two input1 enters with its native caller frame. Forward to
; spcFinishRecordState $1491; it reloads channel X and owns cleanup/output.
; No local register/flag/frame changes. Header $180D..180F remains data and
; also overlaps the default port-zero pointer-table base; do not emit it as code.
    .org $1810
spcFinishRecordNativeAdapter:
    JMP $1491
