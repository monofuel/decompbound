; Continuation jumps, APU $1340..1347 / file $260E82..260E89 (8 bytes).
; $1340 forwards to external $134E (contract unresolved). $1343 is the kind-eight
; route: DP zero,$2F=2*port; loads X=$2F then jumps through $0440+X.
; Preserves A/Y and all flags except N/Z from X; original caller frame remains
; untouched for continuation RET. Neither pointer nor port is range checked.
    .org $1340
spcRouteExternalServiceContinuation:
    JMP $134E
spcJumpNativeServiceContinuation:
    MOV X, $2F
    JMP [$0440+X]
