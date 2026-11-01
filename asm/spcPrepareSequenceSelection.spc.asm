; Selection prelude, APU $075E..0771 / file $2602A0..2602B3 (20 bytes).
; Shared entry with caller's native frame; DP zero for the following selector.
; Writes hardware KOFF=$FF through $0749, resets auxiliary host state, releases
; voice bits 5..7, then receives host upload blocks. No $1A/$1B inhibit applies.
; The receiver can wait indefinitely and has no destination bounds checks;
; resident code and native frames must survive the host's writes to return.
; After receive, A=0 is stored in $08; $0772 selects zero through the same frame.
; Register/flag effects compose the documented callees below. See docs/audio.md.
    .org $075E
spcPrepareSequenceSelection:
    MOV A, #$FF
    MOV Y, #$5C
    CALL $0749             ; Unconditional DSP writer, independent of $1A/$1B.
    CALL $141A             ; Clear copied host state and auxiliary countdowns.
    CALL $1453             ; Release upper voices and queue their KOFF bits.
    CALL $0EE1             ; Receive blocks; returns after CONTROL=$31 clears inputs.
    MOV A, #$00
    MOV $08, A
    ; Fall through $0772: spcSelectSequence with A=0.
