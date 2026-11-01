; Convert pitch position, APU $06BE..$070D / file $260200..$26024F (80 bytes).
; Shared-tail entry: DP zero, unsigned position in $10/$11 (fraction/integer).
; Compensates that scratch position in place, interpolates the local ROM word
; table and writes pre-multiplier word $14/$15. No channel fields are changed.
; Preserves the actual entry X and P/I/B; clobbers A/Y, with A=result low and
; Y=interpolated high before doubling/shifts. C=1/N=0/Z=1; H/V from interpolation.
; Uses two internal stack bytes, balanced before fall-through $070E to
; spcPitchScale, whose tail expects even channel X and returns. No local RET.
; No frequency units or input clamp are claimed. See docs/audio.md for evidence.
    .org $06BE
spcConvertEventPitch:
    ; Apply the piecewise integer-dependent correction to the fractional word.
    MOV Y, #$00
    MOV A, $11
    SETC
    SBC A, #$34
    BCS compensatePosition ; Integer >=52: add integer-52 to the position word.
    MOV A, $11
    SETC
    SBC A, #$13
    BCS lookupInterval     ; Integers 19..51 need no correction.
    DEC Y
    ASL A                  ; Integer <19: YA represents -2*(19-integer).
compensatePosition:
    ADDW YA, $10
    MOVW $10, YA

; Shared CALL/JMP entry $06D4 skips compensation and uses $10/$11 unchanged.
; The remaining outputs/flags/stack contract is the same; X is saved as supplied,
; independently of DP $44.
lookupInterval:
    PUSH X                 ; Preserve the caller's X, independently of saved $44.
    MOV A, $11
    ASL A                  ; Byte wrap discards integer bit 7 before division.
    MOV Y, #$00
    MOV X, #$18
    DIV YA, X              ; Quotient in A; even remainder indexes word bytes.
    MOV X, A
    MOV A, $0EBD+Y
    MOV $15, A
    MOV A, $0EBC+Y
    MOV $14, A
    MOV A, $0EBF+Y
    PUSH A
    MOV A, $0EBE+Y
    POP Y

    ; Interpolate adjacent words using only the LOW byte of their difference.
    SUBW YA, $14
    MOV Y, $10
    MUL YA
    MOV A, Y
    MOV Y, #$00
    ADDW YA, $14
    MOV $15, Y
    ASL A
    ROL $15                ; Double modulo 65536 before any right shifts.
    MOV $14, A
    BRA testScale
shiftWord:
    LSR $15
    ROR A
    INC X
testScale:
    CMP X, #$06
    BNE shiftWord          ; Quotients >6 wrap X: 252..255 shifts produce zero.
    MOV $14, A
    POP X                  ; POP preserves the final comparison's C/N/Z flags.
    ; Fall through to spcPitchScale at APU $070E.
