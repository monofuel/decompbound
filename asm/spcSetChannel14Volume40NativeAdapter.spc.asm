; Native channel-volume setter, APU $2D98..2D9F (8 bytes).
; Original port-one native dispatch; channel offset14/voice7 gets integer
; volume 40 and fraction zero. Pending fade/target/step, dirty state and
; inherited scratch remain intact; no $44 equality requirement or DSP write.
; Returns X=14,A=0,Y preserved,N=0/Z=1,C/H/V/P/I/B preserved; DP zero.
; Original CALL/RET frames balance; preceding three header bytes stay copied.
    .org $2D98
spcSetChannel14Volume40NativeAdapter:
    MOV X, #$0E
    MOV A, #$28
    CALL $166A             ; Stream-free adapter calls the existing volume setter.
    RET
