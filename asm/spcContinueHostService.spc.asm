; Continue service record, APU $131A..132D / file $260E5C..260E6F (20 bytes).
; CALL/shared entry: DP zero, X=port. Zero $04B4+port or a value >= exclusive
; capacity $04D0+port returns directly using the original caller frame.
; Otherwise cached raw kind $048C+port indexes unchecked table $132E in bytes.
; $20 receives the tested byte; accepted path X=kind. No hardware I/O.
; Cached kind eight selects the saved native continuation; other routes remain
; external contracts. Native/other callees determine final state/return behavior.
    .org $131A
spcContinueHostService:
    MOV A, $04B4+X
    MOV $20, A
    BEQ returnService
    CMP A, $04D0+X
    BCS returnService
    MOV A, $048C+X
    MOV X, A
    JMP [$132E+X]
returnService:
    RET
