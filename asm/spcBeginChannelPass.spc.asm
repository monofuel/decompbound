; Begin channel pass, APU $0871..$0881 / file $2603B3..$2603C3 (17 bytes).
; Fall-through after block load: DP zero; no stack or DSP access, no RET here.
; Sets X=0, dirty mask $5E=0, channel mask $47=1, then records channel X at $44.
; High cursor byte $31+X=0 skips to $08F0; otherwise decrements $70+X modulo 256.
; Nonzero countdown branches $08E6; zero falls into token fetch $0882.
; Preserves Y and PSW P/I/B/C/H/V; clobbers X/A/N/Z. See docs/audio.md.
    .org $0871
spcBeginChannelPass:
    MOV X, #$00
    MOV $5E, X
    MOV $47, #$01

; Loop entry $0878: caller supplies even X and current mask $47. Unlike the
; first-channel entry, preserves accumulated dirty bits and existing mask.
spcVisitChannel:
    MOV $44, X
    MOV A, $31+X
    BEQ $08F0              ; Skip inactive channel without changing its countdown.
    DEC $70+X
    BNE $08E6              ; Continue existing event rather than fetching a token.
    ; Fall through to spcFetchSequenceEvent at APU $0882.
