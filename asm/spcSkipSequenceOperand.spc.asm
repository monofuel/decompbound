; FB skip-only entry, APU $0B75..$0B78 / file $2606B7..$2606BA (4 bytes).
; Dispatcher or CALL/RET: DP zero, X=even channel offset, live cursor $30+X.
; Calls cursor-advance entry $0957, past the read: increments without loading.
; Preserves A/X and C/H/V/P/I/B; returns Y=A, N/Z from A, balanced native calls.
; FB dispatch already prefetched operand one; this skips operand two, for two
; consumed bytes total. Direct callers supply A independently. No port writes.
; Evidence: docs/audio.md (advancing sequence fetch and global commands).
    .org $0B75
spcSkipSequenceOperand:
    CALL $0957
    RET
