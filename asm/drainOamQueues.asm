; Drain the four sprite queues into the current OAM build buffer.
; File $008B8E..$008C53, SNES $C08B8E. JSR from publishOamBuild.
; Native X16, decimal-clear callers; PHP/PLP restore caller status.
; Queues 0..3 emit in that order, insertion order within each queue.
; Counts at $2504/$2606/$2708/$280A are end indexes and are not cleared.
; Empty counts skip the emitter. Preserves DBR, direct page, and stack
; depth; A/X/Y and arithmetic flags are scratch.
; Evidence: docs/graphics.md (queue-to-buffer publication).
    .a16
    .i16

drainOamQueues:
    PHP
    REP #$20
    .a16

    ; TODO: purpose of $2402. A match with the upcoming queue index JSRs
    ; queueIndexStub, a lone RTS at $C08C53. That call does not skip,
    ; flush, or reorder the queue.
    LDA $2402
    CMP #$0000
    BNE drainQueue0
    JSR queueIndexStub
drainQueue0:
    LDX #$0000
    BRA checkQueue0
emitQueue0:
    LDA $24C4,X
    STA $000B               ; Bank word; emitter uses the low byte.
    PHX
    LDA $2404,X             ; Definition pointer.
    PHA
    LDA $2484,X
    TAY                     ; Origin Y.
    LDA $2444,X
    TAX                     ; Origin X.
    PLA
    JSL $C08CD5             ; emitSpriteElements.
    PLX
    INX
    INX                     ; Next record; counts are byte indexes.
checkQueue0:
    CPX $2504               ; Queue 0 end index; empty skips emit.
    BCC emitQueue0

    LDA $2402
    CMP #$0001
    BNE drainQueue1
    JSR queueIndexStub      ; Same no-op as queue 0.
drainQueue1:
    LDX #$0000
    BRA checkQueue1
emitQueue1:
    LDA $25C6,X
    STA $000B
    PHX
    LDA $2506,X
    PHA
    LDA $2586,X
    TAY
    LDA $2546,X
    TAX
    PLA
    JSL $C08CD5
    PLX
    INX
    INX
checkQueue1:
    CPX $2606               ; Queue 1 end index, retained.
    BCC emitQueue1

    LDA $2402
    CMP #$0002
    BNE drainQueue2
    JSR queueIndexStub      ; Same no-op as queue 0.
drainQueue2:
    LDX #$0000
    BRA checkQueue2
emitQueue2:
    LDA $26C8,X
    STA $000B
    PHX
    LDA $2608,X
    PHA
    LDA $2688,X
    TAY
    LDA $2648,X
    TAX
    PLA
    JSL $C08CD5
    PLX
    INX
    INX
checkQueue2:
    CPX $2708               ; Queue 2 end index, retained.
    BCC emitQueue2

    LDA $2402
    CMP #$0003
    BNE drainQueue3
    JSR queueIndexStub      ; Same no-op as queue 0.
drainQueue3:
    LDX #$0000
    BRA checkQueue3
emitQueue3:
    LDA $27CA,X
    STA $000B
    PHX
    LDA $270A,X
    PHA
    LDA $278A,X
    TAY
    LDA $274A,X
    TAX
    PLA
    JSL $C08CD5
    PLX
    INX
    INX
checkQueue3:
    CPX $280A               ; Queue 3 end index, retained.
    BCC emitQueue3
    PLP
    RTS

queueIndexStub:
    ; Trailing RTS in this adopted span, after the real PLP/RTS return.
    RTS
