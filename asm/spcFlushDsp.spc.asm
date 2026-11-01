; Buffered DSP flush, APU $0543..0578 / file $260085..2600BA (54 bytes).
; Resident-loop entries below: DP zero, trusted descriptor tables; no CALL/RET
; or stack access. $1B nonzero bypasses writes, buffer clears and feedback.
; Normal path writes descriptors Y=10..1, clears $45/$46, advances $18/$19,
; then joins timer polling $0579. DSP values come from bytes, not whole words.
; Final Y=0; X=last written descriptor's DP source; A=(old18 XOR old19)>>2.
; C=old19 bit0, N/Z from new19; H/V/P/I/B preserved. See docs/audio.md.
    .org $0543
spcBypassDspFlush:
    JMP $05D8              ; Update/service path, bypassing timer poll and phase math.

; Entry $0546: A/X/Y scratch. A nonzero mode returns to $0543 with A=mode,
; X/Y unchanged, N/Z from mode and other PSW bits preserved.
spcFlushDsp:
    MOV A, $1B
    BNE spcBypassDspFlush
    MOV Y, #$0A
nextDescriptor:
    CMP Y, #$05
    BEQ testHighBit
    BCS writeDescriptor    ; Y=10..6 always flush, including queued KOFF/KON.
    CMP $4C, $4D
    BNE finishDescriptor   ; Y=4..1 additionally require equality.
testHighBit:
    ; This is driver state $4C, not the DSP KON register.
    BBS $4C.7, finishDescriptor
writeDescriptor:
    MOV A, $0EA7+Y         ; Register selectors remain in the uploaded driver data.
    MOV !$00F2, A
    MOV A, $0EB1+Y         ; Descriptor holds a direct-page source byte address.
    MOV X, A
    MOV A, (X)
    MOV !$00F3, A
finishDescriptor:
    DBNZ Y, nextDescriptor ; Last processed index is one; index zero is never read.

    MOV $45, Y             ; Both pending key masks are consumed even if echo is gated.
    MOV $46, Y

    ; Advance feedback bytes; TODO: identify their downstream game-level consumers.
    MOV A, $18
    EOR A, $19
    LSR A
    LSR A
    NOTC                   ; New high bit is NOT(bit1(old18) XOR bit1(old19)).
    ROR $18
    ROR $19
    ; Fall through $0579: poll timer zero; no polling occurred inside this fragment.
