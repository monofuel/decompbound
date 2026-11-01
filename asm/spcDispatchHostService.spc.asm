; Host-service lookup, APU $1198..125A / file $260CDA..260D9C (195 bytes).
; CALL/shared entries below: DP zero, resident lookup/record tables loaded.
; Port adapters mask copied input to seven bits, select state/table pointers,
; mask and channel parameters. Common lookup accepts nonzero input strictly
; below $04D0+port; rejected/zero input joins continuation $131A via $126D.
; Accepted input indexes a record pointer, caches its preceding raw kind byte,
; then jumps through $125B+kind. Kind is an UNCHECKED byte offset, not an enum
; validated here. Uses DP $20..$25/$2A..$2F, globals $04D5..$04D7/$04DF,
; cached kind $048C+port and native stack (PUSH X). No hardware I/O.
; Record content and external-kind contracts remain open. See docs/audio.md.
    .org $1198
spcDispatchHostPortOne:
    MOV A, !$04B1
    AND A, #$7F
    MOV !$04B1, A
    MOV $24, #$D5
    MOV $25, #$17         ; Port-one record-pointer table $17D5.
    MOV $2A, #$68
    MOV $2B, #$04         ; Selected per-port state at $0468.
    MOV X, #$01
    MOV A, #$DF           ; Exclude voice five from the mask.
    MOV Y, #$20
    MOV $20, #$0A         ; Even voice offset.
    MOV $21, #$50         ; Raw DSP register base for voice five; published at $04D5.
    BNE dispatchService

; $11BA: port two, voice six; same calling/lookup contract.
spcDispatchHostPortTwo:
    MOV A, !$04B2
    AND A, #$7F
    MOV !$04B2, A
    MOV $24, #$C5
    MOV $25, #$17
    MOV $2A, #$70
    MOV $2B, #$04
    MOV X, #$02
    MOV A, #$BF
    MOV Y, #$40
    MOV $20, #$0C
    MOV $21, #$60
    BNE dispatchService

; $11DC: port three, voice seven. Also refreshes three runtime record bytes
; from feedback byte $19, even when no command is accepted. Those are data,
; not literal operands adopted into this code source.
spcDispatchHostPortThree:
    MOV A, !$04B3
    AND A, #$7F
    MOV !$04B3, A
    MOV $24, #$C7
    MOV $25, #$16
    MOV A, $19
    MOV !$18EF, A
    MOV !$18F7, A
    MOV !$18FF, A
    MOV $2A, #$78
    MOV $2B, #$04
    MOV X, #$03
    MOV A, #$7F
    MOV Y, #$80
    MOV $20, #$0E
    MOV $21, #$70

; $1207 common entry: X=port, A=mask, Y=voice bit; $20/$21=parameters,
; $24/$25=record table, $2A/$2B=per-port state pointer. Port zero is also
; supplied by external entry $1184. This entry does not mask the input byte.
; Accepted handoff: $20/$21=P,$24/$25=oldTable+1,Y=table byte offset,
; X=kind, stack top=saved offset; N/Z from kind, C from the group-offset ASL.
dispatchService:
    MOV !$04D6, A
    MOV !$04D7, Y
    MOV A, $20
    MOV !$04DF, A
    MOV A, $21
    MOV !$04D5, A
    MOV A, X
    MOV $2E, A
    ASL A
    MOV $2F, A
    MOV A, $04B0+X
    MOV $20, A
    MOV $2D, A
    BEQ $126D
    CMP A, $04D0+X
    BCS $126D             ; Capacity is exclusive, with an unsigned comparison.

    ; The rotated eight-byte class lookup and group calculation together
    ; give byte offset 2*(command-1) modulo 256. No table-length check follows.
    AND A, #$07
    MOV Y, A
    MOV A, $117C+Y
    DEC $20
    AND $20, #$F8
    ASL $20
    OR A, $20
    MOV X, A
    MOV A, $2E            ; Overwritten by MOV A,X: does not select the pointer.
    MOV A, X
    MOV Y, A
    MOV A, [$24]+Y
    MOV $20, A
    INCW $24
    MOV A, [$24]+Y
    MOV $21, A
    PUSH X                ; Kind-specific tails consume this saved table offset.
    DECW $20
    MOV X, #$00
    MOV A, [$20+X]        ; Raw byte immediately before the selected record.
    MOV X, $2E
    MOV $048C+X, A
    INCW $20              ; Restore pointer to the record entry itself.
    MOV X, A
    JMP [$125B+X]
