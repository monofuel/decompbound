; Channel output pass, APU $0930..0942 / file $260472..260484 (19 bytes).
; Fall-through from master tick $091E, using the enclosing $07F9 caller frame;
; direct CALL entry also works. DP zero, writable native stack. Visits eight
; even offsets with one-hot $47, calling $0C40 iff cursor HIGH byte $31+X!=0.
; Each call advances volume/pan state, recomputes gain and may emit guarded
; stereo writes. This loop neither checks $04/$1B nor refreshes saved X at $44.
; Returns X=$10,$47=0,C=1,N=0/Z=1; P/I/B preserved,H/V and A/Y from callees.
; If voice seven is inactive A=0; if all inactive Y/H/V are preserved.
; Calls/RET balance the original frame. See docs/audio.md for consumer math.
    .org $0930
spcRunChannelService:
    MOV X, #$00
    MOV $47, #$01
nextChannel:
    MOV A, $31+X
    BEQ advanceChannel
    CALL $0C40            ; Volume/modulation, pan transition and stereo RET tail.
advanceChannel:
    INC X
    INC X
    ASL $47
    BNE nextChannel
    RET
