; Set processing mode, APU $0B7F..$0B83 / file $2606C1..$2606C5 (5 bytes).
; CALL/tail entry: DP zero, A=mode. FE dispatch supplies A=Y=0 with no operand;
; direct callers can store any byte. Nonzero $1B gates several processing paths.
; Shares $0787 cleanup: clears $0491/$04B1/$04B5 and queues ~$1A in KOFF $46.
; Preserves $04, word cursor $40/$41, $0C and X/Y; returns A=~$1A, N/Z from
; TSET1, other PSW bits preserved. Existing caller frame is consumed by tail RET.
; No immediate DSP write or selection-table lookup. See docs/audio.md.
    .org $0B7F
spcSetSequenceProcessingMode:
    MOV $1B, A
    JMP $0787              ; spcQueueSequenceKeyOff; bypass selection/index setup.
