; Set both scheduler pause bits on every active entity.
; File $00943C..$009450 (21 bytes). JSL $C0943C: native M16/X16, DBR=$7E.
; Walks $0A50 via $0A9E,X. Empty (negative) head returns immediately.
; Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Inactive entities are not visited. Evidence: docs/scripts.md.

    .a16
    .i16

pauseEntityScripts:
    LDX $0A50              ; Active-entity head.
    BMI pauseScriptsDone
pauseActiveEntity:
    LDA $10B6,X
    ORA #$C000             ; Bit 14: skip scripts/$121E; bit 15: skip $107A.
    STA $10B6,X            ; Low bank byte preserved; $11A6 still runs.
    LDA $0A9E,X
    TAX
    BPL pauseActiveEntity
pauseScriptsDone:
    RTL
