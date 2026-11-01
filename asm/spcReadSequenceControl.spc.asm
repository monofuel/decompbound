; Read global stream controls, APU $081A..$0840 / file $26035C..$260382 (39 bytes).
; Branch/fall-through entry: DP zero, word-stream cursor at $40/$41.
; Nonzero high byte continues at $0841 with fetched word in YA; word zero
; branches to $07EA. $0080/$0081 set $1B to $80/zero and read again.
; Other low-only words update counter $42 and consume a following jump word:
; decrement counter modulo 256, reset it to control byte if bit 7 is set,
; then jump through that word iff counter is nonzero. No implicit hardware RET.
; Clobbers A/Y/C/N/Z and may set X=$42; preserves SP and P/I/B/H/V.
; TODO: Resolve $1B's later meaning and broader stream lifecycle. See docs/audio.md.
    .org $081A
spcReadSequenceControl:
    CALL $0750             ; spcFetchSequenceWord: N/Z reflect returned high byte.
    BNE $0841              ; Nonzero high byte is the next enclosing parse case.
    MOV Y, A
    BEQ $07EA              ; Zero-word exit; its broader handling is outside here.
    CMP A, #$80
    BEQ storeMarker
    CMP A, #$81
    BNE countJump
    MOV A, #$00
storeMarker:
    MOV $1B, A
    BRA spcReadSequenceControl

countJump:
    DEC $42
    BPL readJump           ; Signed-byte test, not an unsigned borrow test.
    MOV $42, A
readJump:
    CALL $0750             ; Consume jump word even when count becomes zero.
    MOV X, $42
    BEQ spcReadSequenceControl
    MOVW $40, YA
    BRA spcReadSequenceControl
