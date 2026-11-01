; Increment mode value, APU $0B7E / file $2606C0 (1 byte).
; Dispatcher/fall-through entry: DP zero, increments A modulo 256. FD dispatch
; supplies A=Y=0 with no operand, so it selects mode 1; direct A=$FF selects 0.
; Continues through spcSetSequenceProcessingMode at $0B7F and shared $0787
; cleanup/RET: stores $1B, clears three global bytes and queues pending KOFF.
; The shared tail preserves X/Y and PSW except N/Z, returning A=~$1A.
; Cursor/selection fields remain unchanged. See docs/audio.md for mode gates.
    .org $0B7E
spcIncrementSequenceMode:
    INC A
    ; Fall through to spcSetSequenceProcessingMode at APU $0B7F.
