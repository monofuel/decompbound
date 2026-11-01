; Rejected/empty lookup route, APU $126D..126F / file $260DAF..260DB1 (3B).
; Shared entry before the accepted lookup's PUSH: DP zero, X=port and the
; original caller frame live. Preserve local registers/flags/stack and forward
; to $131A, which checks existing slot state and may dispatch its continuation.
    .org $126D
spcContinueRecordRoute:
    JMP $131A             ; spcContinueHostService; no saved table-offset byte to pop.
