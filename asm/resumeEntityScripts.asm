; Clear both scheduler pause bits on every active entity.
; File $009451..$009465 (21 bytes). JSL $C09451: native M16/X16, DBR=$7E.
; Walks $0A50 via $0A9E,X. Empty (negative) head returns immediately.
; Unpaused entities must already have a valid script-state chain.
; Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

resumeEntityScripts:
    LDX $0A50              ; Active-entity head.
    BMI resumeScriptsDone
resumeActiveEntity:
    LDA $10B6,X
    AND #$3FFF             ; Clear bits 14 and 15; bank byte preserved.
    STA $10B6,X            ; Scheduler does not check for a negative $0ADA.
    LDA $0A9E,X
    TAX
    BPL resumeActiveEntity
resumeScriptsDone:
    RTL
