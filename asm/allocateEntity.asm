; Take the first free entity whose offset lies in [$0A4C, $0A4E).
; File $009C02..$009C34 (51 bytes). JSR $C09C02: native M16/X16, DBR=$7E.
; Bounds are already doubled byte offsets, not raw IDs. A negative $0A54
; fails without walking the entity list. Success: X=offset, carry clear,
; $0A9E next left stale. Failure: carry set, no list writes. Lists must
; be valid and $FFFF-terminated. Preserves D, DBR and stack depth; A/X/Y scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

allocateEntity:
    ; A free script-state slot must exist before an entity is taken.
    LDA $0A54
    BMI allocateEntityFailed
    LDY #$FFFF             ; Predecessor of the free-list head.
    LDA $0A52
    BMI allocateEntityFailed
scanFreeEntity:
    TAX
    CPX $0A4C              ; Inclusive lower bound, already a byte offset.
    BCC skipOutOfRangeEntity
    CPX $0A4E              ; Exclusive upper bound.
    BCC takeFreeEntity
skipOutOfRangeEntity:
    TXY                    ; This node becomes the predecessor.
    LDA $0A9E,X
    BPL scanFreeEntity
allocateEntityFailed:
    SEC
    RTS
takeFreeEntity:
    TYA
    BPL unlinkFreeEntityMiddle
    LDA $0A9E,X
    STA $0A52              ; Unlink the head; its next pointer stays stale.
    CLC
    RTS
unlinkFreeEntityMiddle:
    LDA $0A9E,X
    STA $0A9E,Y            ; Splice predecessor to successor.
    CLC
    RTS
