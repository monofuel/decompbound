; Service event tails, APU $08E6..$08EF / file $260428..$260431 (10 bytes).
; Held-event branch entry: DP zero, even X, saved $44=X, zero word $0E/$0F.
; Nonzero $1B skips both callbacks; otherwise $0CF7 services held pitch state
; and $0B84 can consume a pending F9 when the active transition has ended.
; Valid finite callbacks preserve X/SP/P/I/B but may change A/Y/flags, scratch,
; pitch state/cursor and DSP output under $47/$1A. No local RET; continues $08F0.
; See docs/audio.md for callback prerequisites and lookahead termination limits.
    .org $08E6
spcServiceSequenceEvent:
    MOV A, $1B
    BNE $08F0              ; spcNextSequenceChannel: bypass both held callbacks.
    CALL $0CF7             ; Held lookahead, transition and modulation services.

; Shared event entry $08ED skips the mode test and the $0CF7 held callback.
; Calls $0B84 even if $1B is nonzero; event counter setup branches here.
spcServiceSequenceTransition:
    CALL $0B84             ; Transition lookahead; may consume F9's full operand set.
    ; Fall through to spcNextSequenceChannel at APU $08F0.
