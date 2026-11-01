; Read current pitch, APU $0BBC..$0BC6 / file $2606FE..$260708 (11 bytes).
; CALL/RET: DP zero, even channel X; copies $0360/$0361+X to DP $10/$11.
; Returns A=current fraction; preserves X/Y and PSW except N/Z from that byte.
; Does not use saved X at $44 or change the persistent channel fields.
; See docs/audio.md for event initialization and conversion entry contracts.
    .org $0BBC
spcReadChannelPitch:
    MOV A, $0361+X
    MOV $11, A
    MOV A, $0360+X
    MOV $10, A
    RET
