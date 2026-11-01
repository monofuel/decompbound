; Service-record return, APU $148A / file $260FCC (one byte).
; Original port-one input 6 dispatches here through $1317's indexed JMP;
; record continuations also select it through $1345. Requires a native frame.
; RET preserves A/X/Y/all PSW bits and consumes exactly that two-byte return.
; Preceding $1487..1489 remain runtime record metadata. See docs/audio.md.
    .org $148A
spcReturnServiceRecord:
    RET
