; Action-script dispatch: 77 little-endian near code pointers in bank $C0.
; File $009558..$0095F1; SNES $C09558. Low path indexes by opcode*2.
; Packed opcodes also use the last eight words at $C095E2 (selector 0..7).
; Opcode meanings, contracts and evidence: docs/scripts.md.
; TODO: Explain the remaining handler semantics in that reference.
    .word $95F2            ; Opcode $00. Remove current entity.
    .word $9603            ; Opcode $01.
    .word $9627            ; Opcode $02.
    .word $964D            ; Opcode $03.
    .word $9685            ; Opcode $04.
    .word $96AA            ; Opcode $05.
    .word $96C3            ; Opcode $06. Wait for the unsigned operand's tick count.
    .word $99DD            ; Opcode $07.
    .word $9A1A            ; Opcode $08.
    .word $9A2E            ; Opcode $09.
    .word $995D            ; Opcode $0A.
    .word $996B            ; Opcode $0B.
    .word $99C3            ; Opcode $0C.
    .word $9A9F            ; Opcode $0D.
    .word $9AE2            ; Opcode $0E.
    .word $9B09            ; Opcode $0F.
    .word $9979            ; Opcode $10.
    .word $999E            ; Opcode $11.
    .word $9B0F            ; Opcode $12.
    .word $9A0E            ; Opcode $13.
    .word $9A87            ; Opcode $14.
    .word $9B1F            ; Opcode $15.
    .word $9B2C            ; Opcode $16.
    .word $9B44            ; Opcode $17.
    .word $9A5C            ; Opcode $18.
    .word $9649            ; Opcode $19.
    .word $9658            ; Opcode $1A.
    .word $966F            ; Opcode $1B.
    .word $9B4D            ; Opcode $1C. Install graphics pointer and bank.
    .word $9B61            ; Opcode $1D.
    .word $9B6B            ; Opcode $1E.
    .word $9B79            ; Opcode $1F.
    .word $9B91            ; Opcode $20.
    .word $9BB4            ; Opcode $21.
    .word $9BE4            ; Opcode $22. Install rendering callback.
    .word $9BEE            ; Opcode $23.
    .word $9620            ; Opcode $24.
    .word $9BF8            ; Opcode $25.
    .word $9BCC            ; Opcode $26.
    .word $9A97            ; Opcode $27.
    .word $96E3            ; Opcode $28.
    .word $96F3            ; Opcode $29.
    .word $9703            ; Opcode $2A.
    .word $98A0            ; Opcode $2B.
    .word $98AE            ; Opcode $2C.
    .word $98BC            ; Opcode $2D.
    .word $976D            ; Opcode $2E.
    .word $9792            ; Opcode $2F.
    .word $97B7            ; Opcode $30.
    .word $97DC            ; Opcode $31.
    .word $97EF            ; Opcode $32.
    .word $9802            ; Opcode $33.
    .word $9826            ; Opcode $34.
    .word $984A            ; Opcode $35.
    .word $9875            ; Opcode $36.
    .word $98CA            ; Opcode $37.
    .word $98DE            ; Opcode $38.
    .word $98F2            ; Opcode $39.
    .word $991C            ; Opcode $3A.
    .word $96CF            ; Opcode $3B. Select frame; operand $FF disables it.
    .word $9A38            ; Opcode $3C.
    .word $9A3E            ; Opcode $3D.
    .word $9A44            ; Opcode $3E.
    .word $9713            ; Opcode $3F.
    .word $9731            ; Opcode $40.
    .word $974F            ; Opcode $41.
    .word $993D            ; Opcode $42. Call a three-byte native target.
    .word $9931            ; Opcode $43.
    .word $9BA9            ; Opcode $44.

packedActionHandlers:
    ; Each word also serves packed selector (opcode bits 4-6).
    .word $96CF            ; Opcode $45 / packed 0: frame ($FF disables).
    .word $9A38            ; Opcode $46. Packed selector 1.
    .word $9A3E            ; Opcode $47. Packed selector 2.
    .word $9A44            ; Opcode $48. Packed selector 3.
    .word $9713            ; Opcode $49. Packed selector 4.
    .word $9731            ; Opcode $4A. Packed selector 5.
    .word $974F            ; Opcode $4B. Packed selector 6.
    .word $993D            ; Opcode $4C. Packed selector 7.
