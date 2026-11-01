; Service pass, APU $0596..05C5 / file $2600D8..260107 (48 bytes).
; Resident entry with DP zero and writable native stack. Calls original helpers
; below, then falls into spcAdvanceEchoSettle $05C6 and phase $05CD, which
; requires the earlier pending timer byte. This source adds no native frame.
; Callees may modify registers, flags, RAM and ports; no blanket preservation
; contract is inferred. $0635 reads/debounces host port X, echoes it and returns
; changed input or zero; each result is copied into $04B3/$04B2/$04B1.
    .org $0596
spcRunServicePass:
    CALL $1609            ; External service helper; broader effects remain open.
    CALL $2DAB
    CALL $2DF3
    CALL $2DD5
    CALL $11DC

    MOV X, #$03
    CALL $0635            ; Host input port three.
    MOV !$04B3, A
    CALL $2E1D
    CALL $11BA

    MOV X, #$02
    CALL $0635            ; Host input port two.
    MOV !$04B2, A
    CALL $1198

    MOV X, #$01
    CALL $0635            ; Host input port one; alternate $058C tests its copied byte.
    MOV !$04B1, A
    ; Fall through $05C6: spcAdvanceEchoSettle.
