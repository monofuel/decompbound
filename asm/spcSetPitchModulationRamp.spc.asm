; F0 ramp setup, APU $0A14..0A23 / file $260556..260565 (16 bytes).
; Dispatcher/RET or CALL/RET: DP zero, X=channel, A=duration, DP $44=channel.
; Writes duration $02B1+X and quotient $02C0+X=floor(current depth/duration).
; Zero divisor gives quotient 255 and remainder=current depth on SPC DIV.
; Preserves depth/target, phase and counters. Accepted events separately map
; duration bit 0 into phase bit 7. Returns X=DP $44, A=quotient, Y=remainder.
; C/P/I/B preserved; H/V from DIV, N/Z from restored X. See docs/audio.md.
    .org $0A14
spcSetPitchModulationRamp:
    MOV $02B1+X, A
    PUSH A
    MOV Y, #$00
    MOV A, $B1+X
    POP X                  ; Divisor replaces the channel until the explicit restore.
    DIV YA, X
    MOV X, $44
    MOV $02C0+X, A
    RET
