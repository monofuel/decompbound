; Native controlled-state setup, APU $2501..2509 / file $262043..26204B (9B).
; Original port-three input71 enters through native-kind dispatch with inherited
; $2A/$2B state destination,$2D command,$2E slot,$04D7 mask and caller frame.
; Select fixed source $250A and control $1F, then original $14EE copies seven
; parameter bytes and initializes state. Those seven bytes and the preceding
; three-byte header remain copied data. Header's saved continuation is $148B;
; this JMP/RET does not implicitly call it. Callee owns flags/scratch/return.
    .org $2501
spcConfigureRecordNativeAdapter:
    MOV A, #$0A
    MOV Y, #$25
    MOV X, #$1F
    JMP $14EE             ; Controlled initializer; combined control cannot be zero here.
