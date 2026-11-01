; Record install, APU $0F4B..0F8E / file $260A8D..260AD0 (68 bytes).
; CALL/RET, DP zero,YA=record P,$2E=port0..3,$2F=2*port,$2A/$2B=state pointer;
; caller supplies $2D command and $04D7 mask. Reads P+0..5, installs stream
; pointer at $0480+2*port, selects timing, then tails into original $14FC to
; copy seven config bytes into state, initialize counters and queue/inhibit mask.
; $0F4B adds the $049C+port=1 marker after ordinary $0F56 initialization.
; No alias/bounds/record-length checks; native frames balance. With disjoint
; record/scratch/state buffers, config fields are
; [timing pair,P0,P1,P2,P5,P3]; initial marker P+5=C9 sets $04C8+port=C9,
; otherwise0. The later cursor-zero scan starts at P+6, not this marker byte.
; $0F56 returns X=port,Y=7,A=$2D; $0F4B returns A=1. Flags follow setup/setter.
; Runtime records remain user-ROM data. See docs/audio.md.
    .org $0F4B
spcRecordInterpreterInstallMarked:
    CALL spcRecordInterpreterInstall
    MOV X, $2E
    MOV A, #$01
    CALL $1394            ; Mark this port's special mode without changing timing.
    RET
spcRecordInterpreterInstall:
    CALL $0F3C
    MOV A, [$20]+Y        ; Y=3 after copying P0/P1/P2 to config DA/DB/DC.
    MOV !$04DE, A         ; Raw pitch fraction for subsequent negative tokens.
    MOV X, $2F
    MOV A, $20
    MOV $0480+X, A
    MOV A, $21
    INC X
    MOV $0480+X, A
    MOV X, $2E
    MOV A, #$00
    MOV $04C8+X, A
    MOV Y, #$04
    MOV A, [$20]+Y
    MOV $22, A
    INC Y
    MOV A, [$20]+Y
    MOV !$04DD, A         ; Initial stream marker/config byte, preceding P+6.
    CMP A, #$C9
    BNE selectTiming
    MOV $04C8+X, A
selectTiming:
    CALL $0FA1
    MOV A, #$D8
    MOV Y, #$04
    JMP $14FC             ; Actual state initializer; consumes original caller frame.
