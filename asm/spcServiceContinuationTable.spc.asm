; Structural continuation dispatch, APU $132E..133F / file $260E70..260E81.
; Nine code pointers, indexed by unchecked cached BYTE offset (not word index).
; Route bodies carry their own contracts; unchecked targets are not validated.
    .org $132E
spcServiceContinuationTable:
    .word $1348           ; $00: forward to $148B; cleanup remains open.
    .word $1348           ; $02: alias of kind zero.
    .word $134B           ; $04: forward to the record stream parser at $0FB7.
    .word $134B           ; $06: alias of kind four.
    .word $1343           ; $08: saved native continuation pointer.
    .word $134B           ; $0A: external route to $0FB7.
    .word $134B           ; $0C: external route to $0FB7.
    .word $1340           ; $0E: tick and consume extended record bytes at $134E.
    .word $1340           ; $10: alias of kind fourteen.
