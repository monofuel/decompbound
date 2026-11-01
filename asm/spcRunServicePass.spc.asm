; Service pass, APU $0596..05C5 / file $2600D8..260107 (48 bytes).
; Resident entry with DP zero and writable native stack. Calls original helpers
; below, then falls into spcAdvanceEchoSettle $05C6 and phase $05CD, which
; requires the earlier pending timer byte. This source adds no native frame.
; Tick countdowns, dispatch ports 3/2/1 and sample each port AFTER its dispatch.
; New sampled input is consumed next pass; software port-two retargets follow
; this same call order. Callees/native records own clobbers and return behavior.
; For returning records SP is preserved; no register/flag blanket is inferred.
; $0635 reads/debounces/echoes port X; changed input or zero becomes $04B3/2/1.
    .org $0596
spcRunServicePass:
    CALL $1609            ; Advance host-service countdown $0491.
    CALL $2DAB            ; Tick temporary pitch/tempo override.
    CALL $2DF3            ; Tick master-factor $F0 countdown.
    CALL $2DD5            ; Tick master-factor $A0 countdown.
    CALL $11DC            ; Port-three record dispatch/continuation, before sampling.

    MOV X, #$03
    CALL $0635            ; Host input port three.
    MOV !$04B3, A
    CALL $2E1D            ; Filter the copied port-three change.
    CALL $11BA            ; Port-two record dispatch.

    MOV X, #$02
    CALL $0635            ; Host input port two.
    MOV !$04B2, A
    CALL $1198            ; Port-one record dispatch.

    MOV X, #$01
    CALL $0635            ; Host input port one; alternate $058C tests its copied byte.
    MOV !$04B1, A
    ; Fall through $05C6: spcAdvanceEchoSettle.
