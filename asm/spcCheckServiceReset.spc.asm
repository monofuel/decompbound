; Alternate service entry, APU $058C..0595 / file $2600CE..2600D7 (10 bytes).
; Reads $04B1; A and N/Z/C follow CMP #$AA, other flags/registers preserved
; on the ordinary path, which falls into $0596 with SP unchanged.
; Match CALLs $05FC: that external routine writes DSP/CONTROL and jumps to IPL
; $FFC0 rather than returning here; execution inside IPL is outside this source.
; An upstream caller of $058C remains unproven; timer carry skips this entry.
; Unlike timer carry routing, this entry requires no count for its own code;
; continuing through $05CD still requires the caller's pending timer frame.
    .org $058C
spcCheckServiceReset:
    MOV A, !$04B1
    CMP A, #$AA
    BNE $0596             ; spcRunServicePass.
    CALL $05FC            ; Reset/transfer to IPL; native CALL frame remains.
    ; Ordinary branch falls into $0596.
