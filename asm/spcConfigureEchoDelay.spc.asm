; Configure echo delay, APU $0B2C..$0B71 / file $26066E..$2606B3 (70 bytes).
; CALL/shared RET tail: DP zero, A=full delay request; stores target $4D.
; Reads DSP EDL $7D. A changed request updates settling byte $4C, clears four
; echo registers, writes FLG=$48|$20 and EDL=request; shadows stay buffered.
; Equal requests skip those actions but still write ESA=~(8*request mod 256).
; Preserves X/P/I/B; returns A=ESA, Y=$6D, C=1/H=1/V=0 and N=0/Z=0.
; Only $4C/$4D change in RAM; hardware writes are unconditional, with no delay
; range check. Shared $0749 RET consumes the caller frame. See docs/audio.md.
    .org $0B2C
spcConfigureEchoDelay:
    MOV $4D, A
    MOV Y, #$7D
    MOV !$00F2, Y
    MOV A, !$00F3
    CMP A, $4D
    BEQ writeStartAddress

    ; t=255-(old EDL & 15). Store t if old $4C<128, otherwise (t+$4C)&255.
    ; This can wrap to a nonnegative byte; settling is not a fixed wait count.
    AND A, #$0F
    EOR A, #$FF
    BBC $4C.7, storeSettling
    CLRC
    ADC A, $4C
storeSettling:
    MOV $4C, A
    MOV Y, #$04
clearEchoRegisters:
    MOV A, $0EA7+Y         ; Descriptor entries 4..1: EON/EFB/EVOLR/EVOLL.
    MOV !$00F2, A
    MOV A, #$00
    MOV !$00F3, A
    DBNZ Y, clearEchoRegisters
    MOV A, $48
    OR A, #$20             ; Disable hardware echo writes without changing shadow.
    MOV Y, #$6C
    CALL $0749
    MOV A, $4D
    MOV Y, #$7D
    CALL $0749

writeStartAddress:
    ASL A
    ASL A
    ASL A
    EOR A, #$FF
    SETC
    ADC A, #$FF            ; Leaves A unchanged; establishes C=1/H=1/V=0.
    MOV Y, #$6D            ; This final load sets N/Z after the ESA calculation.
    JMP $0749              ; Unconditional DSP write and shared hardware RET.
