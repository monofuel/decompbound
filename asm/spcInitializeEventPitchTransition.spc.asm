; Initialize event transition, APU $0696..$06BD / file $2601D8..$2601FF (40 bytes).
; Accepted-event fall-through: DP zero, even channel X in 0..14; current word
; $0360/$0361+X is already prepared. Copies pending duration $0280+X to $A0+X.
; Active duration also copies delay $0281+X to $A1+X and initializes target/step;
; it requires DP $44=X and word $0E/$0F=0 for the shared signed divider.
; Active helper uses DP $12 and negative-path $14/$15; no port accesses here.
; Zero duration preserves delay/current/target/step. Always copies current word
; to DP $10/$11; A=fraction, N/Z reflect it. Active path returns X=$44 and
; Y=step high, C/H/V from divider; disabled path preserves entry X/Y/C/H/V.
; Preserves P/I/B, balances internal calls, then falls into $06BE. See docs/audio.md.
    .org $0696
spcInitializeEventPitchTransition:
    MOV A, $0280+X
    MOV $A0+X, A
    BEQ readCurrentPitch
    MOV A, $0281+X
    MOV $A1+X, A
    MOV A, $0290+X
    BNE addInterval        ; Any nonzero mode preserves the prepared integer.

    ; Mode zero moves the integer origin backward; the fractional byte stays.
    MOV A, $0361+X
    SETC
    SBC A, $0291+X
    MOV $0361+X, A
addInterval:
    MOV A, $0291+X
    CLRC
    ADC A, $0361+X         ; Byte wrap precedes the target helper's seven-bit mask.
    CALL $0BA4             ; spcSetPitchTransitionTarget; restores X from DP $44.
readCurrentPitch:
    CALL $0BBC             ; spcReadChannelPitch: copy the selected current word.
    ; Fall through to spcConvertEventPitch at APU $06BE.
