; Load channel block, APU $0841..$0870 / file $260383..$2603B2 (48 bytes).
; Global-control fall-through: DP zero, YA points to a sixteen-byte cursor block.
; Copies eight little-endian cursors to absolute $0030..$003F, then initializes
; all eight channels: $80/$90/$91+X=0 and $70+X=1 for even X in 0..14.
; Nonzero cursor high byte with $0211+X=0 calls instrument entry $095F with A=0;
; its $1A guard decides whether DSP/multiplier/state writes occur.
; Clobbers A/X/Y/PSW, DP $16/$17 and conditional instrument scratch $14/$15;
; ends A=1, X=$10, mask $47=0, C=1/N=0/Z=1. Internal calls balance SP.
; Preserves global $04 and cursor $40/$41; continues $0871. See docs/audio.md.
    .org $0841
spcLoadSequenceBlock:
    MOVW $16, YA
    MOV Y, #$0F
copyCursors:
    MOV A, [$16]+Y
    MOV !$0030+Y, A        ; Absolute store: destination is page zero.
    DEC Y
    BPL copyCursors

    MOV X, #$00
    MOV $47, #$01
initializeChannel:
    MOV A, $31+X
    BEQ resetCounters      ; High byte zero disables the channel, even if low!=0.
    MOV A, $0211+X
    BNE resetCounters
    MOV A, #$00
    CALL $095F             ; spcSelectInstrument: default instrument zero.
resetCounters:
    MOV A, #$00
    MOV $80+X, A           ; Discard any active software sequence repeat count.
    MOV $90+X, A           ; Disable pending volume transition.
    MOV $91+X, A           ; Disable pending pan transition.
    INC A
    MOV $70+X, A           ; Next channel pass decrements this to fetch immediately.
    INC X
    INC X
    ASL $47
    BNE initializeChannel
    ; Fall through to the channel-pass initialization at APU $0871.
