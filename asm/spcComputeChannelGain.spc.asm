; Compute channel gain, APU $0E61..$0E72 / file $2609A3..$2609B4 (18 bytes).
; CALL/RET or modulation-tail entry: DP zero, even X in 0..14, A=input factor.
; Combines unsigned bytes A, global $59, channel factor $0210+X and volume
; integer $0301+X, retaining only the high byte after each multiplication.
; Squares that final byte and writes its high byte to gain $0321+X.
; Returns A=Y=gain; preserves X and PSW except N/Z. No DSP writes or scratch
; writes; volume fraction is unused here. See docs/audio.md for stereo output.
    .org $0E61
spcComputeChannelGain:
    MOV Y, $59
    MUL YA
    MOV A, $0210+X
    MUL YA
    MOV A, $0301+X
    MUL YA

    ; Square the truncated combined factor before the stereo curve is applied.
    MOV A, Y
    MUL YA
    MOV A, Y
    MOV $0321+X, A
    RET
