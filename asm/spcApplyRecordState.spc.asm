; Apply five-byte record payload, APU $1557..15D7 / file $261099..261119 (129B).
; CALL/shared entry: DP zero, $2A/$2B=state pointer, X=slot, even voice $04DF.
; Payload starts at low($2A+2), SAME high byte: no carry into $2B. Five bytes
; are instrument,gain,phase|pan,pitch-high,pitch-low. Save prior gain/phase,
; set noise mask from $04CC+slot, and run original instrument/stereo/pitch tails.
; $47 becomes zero, so these writes bypass the ordinary inhibit intersection.
; $0431 overrides pan with ten. DSP register base derives from even channel X;
; final JMP $06D4 bypasses compensation, then scales/writes pitch and RETs.
; Scratch/registers/flags follow the called output helpers; native frame balances.
    .org $1557
spcApplyRecordState:
    MOV A, $2A
    INC A
    INC A
    MOV Y, $2B
    MOVW $22, YA
    MOV Y, #$00
    MOV A, $04CC+X
    BEQ clearRecordNoise
    MOV A, $49
    OR A, !$04D7
    MOV $49, A
    BNE saveChannelState
clearRecordNoise:
    MOV A, $49
    AND A, !$04D6
    MOV $49, A
saveChannelState:
    MOV X, !$04DF
    MOV A, $0321+X
    MOV $04E0+X, A
    MOV A, $0351+X
    MOV $04F0+X, A
    MOV $47, #$00
    MOV A, [$22]+Y
    PUSH Y
    CALL $0962             ; Instrument interior; preserve stored channel instrument.
    POP Y
    INC Y
    MOV A, [$22]+Y
    INC Y
    MOV $0321+X, A
    MOV A, [$22]+Y
    AND A, #$C0
    MOV $0351+X, A
    MOV A, [$22]+Y
    INC Y
    AND A, #$3F
    MOV !$0433, A
    MOV A, !$0431
    CMP A, #$00
    BEQ useRecordPan
    MOV A, #$0A
    MOV !$0433, A
useRecordPan:
    MOV A, !$0433
    MOV $11, A
    MOV $10, #$00
    MOV A, $47
    AND A, !$04D6
    MOV $47, A
    PUSH Y
    CALL $0C95             ; Stereo writer consumes scratch position, not current pan.
    POP Y
    MOV A, [$22]+Y
    INC Y
    MOV $11, A
    MOV A, [$22]+Y
    MOV $10, A
    MOV A, $47
    AND A, !$04D6
    MOV $47, A
    JMP $06D4              ; Shared uncompensated conversion; final pitch-writer RET.
