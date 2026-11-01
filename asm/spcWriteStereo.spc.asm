; Write stereo volume, APU $0C8C..$0CD2 / file $2607CE..$260814.
; CALL/RET: direct page zero; X is even channel offset 0..14; $47 is mask.
; Inputs: 8.8 position $0330/$0331+X, gain $0321+X, phase flags $0351+X.
; $47 & $1A suppresses DSP VOLL/VOLR writes; source fields remain unchanged.
; Preserves X; clobbers A/Y/PSW and DP $10..$12. Scratch position returns to
; its input, $12 ends at voice*$10+2. Curve semantics are verified for position
; 0..20*256 inclusive; no bounds check exists. See docs/audio.md for arithmetic.
    .org $0C8C
spcWriteStereo:
    MOV A, $0331+X
    MOV Y, A
    MOV A, $0330+X
    MOVW $10, YA

; CALL entry $0C95: same channel/gain/flags/mask contract, but coordinate is
; already in DP $10/$11. Both reflections restore it before RET.
spcWriteStereoScratch:
    MOV A, X
    XCN A
    LSR A
    MOV $12, A             ; DSP voice register base, starting with VOLL.
interpolateSide:
    ; Linearly interpolate the local-ROM curve at integer/fraction coordinate.
    MOV Y, $11
    MOV A, $0E74+Y
    SETC
    SBC A, $0E73+Y
    MOV Y, $10
    MUL YA
    MOV A, Y               ; Truncate the fractional slope product.
    MOV Y, $11
    CLRC
    ADC A, $0E73+Y
    MOV Y, A
    MOV A, $0321+X
    MUL YA                 ; High byte is floor(gain*coefficient/256).

    ; Left selects control bit 7; odd DSP index selects bit 6 for right.
    MOV A, $0351+X
    ASL A
    BBC $12.0, selectPhase
    ASL A
selectPhase:
    MOV A, Y
    BCC writeSide
    EOR A, #$FF
    INC A
writeSide:
    MOV Y, $12
    CALL $0741             ; Guarded DSP write preserves the register index.

    ; Reflect p to 20-p for the opposite side, then restore p on completion.
    MOV Y, #$14
    MOV A, #$00
    SUBW YA, $10
    MOVW $10, YA
    INC $12
    BBC $12.1, interpolateSide
    RET
