; Preview phase helper, APU $0E49..$0E55 / file $26098B..$260997 (13 bytes).
; CALL/shared entry: DP zero, X=even channel offset; $51 is a phase fraction.
; Sets $13.7, computes A=(phase[$02D0+X]+floor(rate[$02D1+X]*$51/256)) mod 256.
; Falls into $0E56's unsigned triangle/depth scaling, then $0E61 gain calculation.
; There is no normal updater's depth-255/negative-phase hold and no delay gate.
; Preserves X, P/I/B, current phase/counter/depth and $5E; clobbers A/Y/flags,
; $13, and derived gain $0321+X. Shared gain tail RET consumes the caller frame.
; No local port writes. See docs/audio.md (volume modulation and gain).
    .org $0E49
spcPreviewVolumePhase:
    SET1 $13.7
    MOV Y, $51
    MOV A, $02D1+X
    MUL YA
    MOV A, Y               ; Unsigned high product byte, without changing saved phase.
    CLRC
    ADC A, $02D0+X
    ; Fall through to the common triangle factor at $0E56, not the normal C40 hold.
