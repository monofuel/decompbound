; Record stereo adapter, APU $10B6..10E6 / file $260BF8..260C28 (49 bytes).
; CALL/RET through $0C95, DP zero,X=even voice offset0..14,$22=gain,$23=control.
; Sets gain $0321+X, phase bits $0351+X=$23&C0, scratch position low6($23)<<8;
; nonzero $0431 overrides scratch integer to ten. Stores effective integer at
; $0433; persistent $0330/$0331 position remains untouched. Masks $47 by
; $04D6 before guarded stereo output; caller must supply meaningful mask.
; Uses $10..$12, clobbers A/Y/flags; X preserved by stereo helper. Curve domain
; 0..20 is verified by that helper; this adapter does not clamp low-six-bit input.
; See docs/audio.md; no asset curve is emitted here.
    .org $10B6
spcRecordInterpreterWritePan:
    MOV A, $22
    MOV $0321+X, A
    MOV A, $23
    AND A, #$C0
    MOV $0351+X, A
    MOV A, $23
    AND A, #$3F
    MOV !$0433, A
    MOV A, !$0431
    CMP A, #$00
    BEQ usePosition
    MOV A, #$0A
    MOV !$0433, A
usePosition:
    MOV A, !$0433
    MOV $11, A
    MOV $10, #$00
    MOV A, $47
    AND A, !$04D6
    MOV $47, A
    JMP $0C95
