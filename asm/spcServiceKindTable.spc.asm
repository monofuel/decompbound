; Structural native-code dispatch, APU $125B..126C / file $260D9D..260DAE.
; Nine word pointers; raw record kind is a BYTE offset, normally even 0..16.
; Odd/out-of-range kinds are unchecked and can read unaligned/adjacent words.
; External handler meanings/callees are not established by this table alone.
    .org $125B
spcServiceKindTable:
    .word $1280           ; $00: external record route.
    .word $1280           ; $02: alias of kind zero.
    .word $1270           ; $04: external record route.
    .word $1278           ; $06: external record route.
    .word $12C7           ; $08: native code with preceding continuation word.
    .word $1176           ; $0A: external prelude plus kind-four route.
    .word $1170           ; $0C: external prelude plus kind-six route.
    .word $1288           ; $0E: extended external record route.
    .word $1288           ; $10: alias of kind fourteen.
