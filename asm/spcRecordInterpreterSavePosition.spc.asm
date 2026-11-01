; Save continuation position, APU $10FC..110C / file $260C3E..260C4E (17 bytes).
; CALL/RET, DP zero; YA=position,$2E=port,$2F=2*port normally. Writes the word
; at $0458+$2F, then byte 1 at $0454+$2E. These indices are independent and
; unchecked. Returns A=1,X=$2E,Y=entry Y,N=0/Z=0; other flags preserved.
; No stream fetch or hardware access. See docs/audio.md.
    .org $10FC
spcRecordInterpreterSavePosition:
    MOV X, $2F
    MOV $0458+X, A
    MOV A, Y
    MOV $0459+X, A
    MOV X, $2E
    MOV A, #$01
    MOV $0454+X, A
    RET
