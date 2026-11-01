; Arm pitch/tempo override, APU $2DC6..2DD4 / file $262908..262916 (15B).
; CALL/shared RET: DP zero. Original port-one route reaches this for input 5.
; Sets $0438=$70, global pitch offset $50=$0E, saves old tempo $53 in $0493,
; then sets current tempo word $52/$53=$C800. Preserves pending tempo fade.
; Returns A=0,Y=$C8,N=0/Z=1; preserves X/C/H/V/P/I/B and balances native stack.
; Re-arming saves the current tempo again. The three preceding bytes are record
; metadata, not instructions. TODO: broader trigger identity. See docs/audio.md.
    .org $2DC6
spcArmPitchTempoOverride:
    MOV A, #$70
    MOV !$0438, A
    MOV A, #$0E
    CALL $1663             ; Global pitch-offset adapter.
    MOV A, #$C8
    JMP $1632              ; Save current tempo, then shared immediate setter/RET.
