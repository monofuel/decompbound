; FA remap-base setter, APU $0B72..$0B74 / file $2606B4..$2606B6 (3 bytes).
; Dispatcher or CALL/RET: DP zero, A=operand; stores the full byte in $5F.
; $095F uses this base in (instrumentByte-$CA+$5F) modulo 256 for high inputs.
; Preserves A/X/Y and every status bit; no extra fetch or DSP writes.
; FA dispatch consumes its one prefetched operand. See docs/audio.md.
    .org $0B72
spcSetInstrumentRemapBase:
    MOV $5F, A
    RET
