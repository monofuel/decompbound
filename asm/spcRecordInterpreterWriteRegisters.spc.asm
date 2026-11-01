; Record DSP adapters, APU $110D..1151 / file $260C4F..260C93 (69 bytes).
; CALL/RET entries, DP zero. $04D5=raw DSP register base (normally voice*16).
; Writes use unconditional $0749, bypassing $1A/$1B guards; register arithmetic
; wraps at 256 without masking to DSP's register range. Native frames balance.
; $110D writes A to base+5 then original Y to base+6; returns A=oldY,Y=base+6,
; X preserved,$20=base+5; C/H/V from base+5 addition,N/Z from final Y.
; See docs/audio.md for consumer roles and unverified record grammar.
    .org $110D
spcRecordInterpreterWriteEnvelope:
    PUSH Y
    PUSH A
    MOV A, !$04D5
    CLRC
    ADC A, #$05
    MOV Y, A
    MOV $20, A
    POP A
    CALL $0749
    POP Y
    MOV A, Y
    MOV Y, $20
    INC Y
    JMP $0749

; $1124 writes A to base+7; A/X preserved,Y=register, C/H/V/N/Z from addition.
spcRecordInterpreterWriteGain:
    PUSH A
    MOV A, !$04D5
    CLRC
    ADC A, #$07
    MOV Y, A
    POP A
    JMP $0749

; $1130: A=instrument byte,$04DF=even voice offset,$04D6=mask excluding voice.
; Clears excluded noise bits via $49&mask, sets X=voice,$47=0, then calls
; instrument interior $0962: skips $0211 operand store and bypasses inhibition.
; Returns X=voice,A=record byte5,Y=5; multiplier/noise-clock/DSP side effects
; and flags follow the instrument helper. Uses $14/$15 and native stack.
spcRecordInterpreterSelectInstrument:
    PUSH A
    MOV A, $49
    AND A, !$04D6
    MOV $49, A
    MOV A, !$04DF
    MOV X, A
    POP A
    MOV $47, #$00
    CALL $0962
    RET

; $1144 writes A to base then base+1; A/X and C/H/V/P/I/B preserved,
; Y=base+1 modulo256,N/Z from Y. No selected channel fields are changed.
spcRecordInterpreterWriteVolume:
    PUSH A
    MOV A, !$04D5
    MOV Y, A
    POP A
    CALL $0749
    INC Y
    CALL $0749
    RET
