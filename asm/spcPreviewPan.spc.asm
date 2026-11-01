; Preview pan transition, APU $0DDF..$0DFB / file $260921..$26093D.
; Channel-preview fall-through: DP zero, even X in 0..14, phase byte DP $51;
; word $0E/$0F must be zero for the signed helper's spcNegateStep calls.
; Copies current $0330/$0331+X to scratch $10/$11; an active $91+X counter
; adds the phase-scaled signed step $0340/$0341+X and sets DP $13 bit 7.
; Bit 7 requests stereo output through $0C95; existing bit 7 also requests it
; with no active transition. Uses gain/phase fields and $47/$1A DSP guard.
; Preserves X and persistent channel fields; clobbers A/Y/PSW, DP $10..$15.
; Continues at $0DFC without RET. See docs/audio.md for preview arithmetic.
    .org $0DDF
spcPreviewPan:
    MOV A, $0331+X
    MOV Y, A
    MOV A, $0330+X
    MOVW $10, YA
    MOV A, $91+X
    BEQ testPreviewDirty

    MOV A, $0341+X
    MOV Y, A
    MOV A, $0340+X
    CALL $0E2B             ; spcScaleSignedStep: update scratch and mark dirty.
testPreviewDirty:
    BBC $13.7, $0DFC       ; Continue the enclosing preview when no write is due.
    CALL $0C95             ; spcWriteStereoScratch consumes scratch coordinate.
    ; Fall through to the enclosing channel-preview continuation at $0DFC.
