; Structural continuation dispatch, APU $132E..133F / file $260E70..260E81.
; Nine code pointers, indexed by unchecked cached BYTE offset (not word index).
; Only the kind-eight saved-native-pointer route is established here.
    .org $132E
spcServiceContinuationTable:
    .word $1348           ; $00: external route to $148B.
    .word $1348           ; $02: alias of kind zero.
    .word $134B           ; $04: external route to $0FB7.
    .word $134B           ; $06: alias of kind four.
    .word $1343           ; $08: saved native continuation pointer.
    .word $134B           ; $0A: external route to $0FB7.
    .word $134B           ; $0C: external route to $0FB7.
    .word $1340           ; $0E: external route to $134E.
    .word $1340           ; $10: alias of kind fourteen.
