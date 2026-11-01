; Structural native-code dispatch, APU $125B..126C / file $260D9D..260DAE.
; Nine word pointers; raw record kind is a BYTE offset, normally even 0..16.
; Odd/out-of-range kinds are unchecked and can read unaligned/adjacent words.
; Route contracts live beside their code and in docs/audio.md.
    .org $125B
spcServiceKindTable:
    .word $1280           ; $00: copy seven-byte record into slot state.
    .word $1280           ; $02: alias of kind zero.
    .word $1270           ; $04: install timing and record parameters.
    .word $1278           ; $06: install parameters, then set slot mode one.
    .word $12C7           ; $08: native code with preceding continuation word.
    .word $1176           ; $0A: retarget port two, then kind-four setup.
    .word $1170           ; $0C: retarget port two, then kind-six setup.
    .word $1288           ; $0E: initialize extended record pointers/control.
    .word $1288           ; $10: alias of kind fourteen.
