; Request VRAM DMA (file $008643..$0086DD / SNES $C08643..$C086DD).
; JSL entry: native mode, decimal clear; accepts either M/X width, any DP/DBR.
; Inputs: $0091 profile byte offset, $0092 byte count, $0094 source address,
; $0096 source bank, $0097 destination VRAM word address (all bank zero).
; Preserves P, DP, DBR and stack depth; Y returns zero, A/X are clobbered.
; Queues while display enabled; may spin until interrupt progress. Forced blank
; transfers immediately on channel 1. See docs/graphics.md for DMA evidence.
    .a16
    .i16
requestVramDma:
    PHP
    REP #$20
    SEP #$10
    PHD
    PEA $0000
    PLD
    PHB
    LDY #$00
    PHY
    PLB
    REP #$10
    JSR requestVramDmaInner
    .a16
    .i16
    PLB
    PLD
    PLP
    RTL

; JSL $C0865B: native M16/X16, decimal clear, DP/DBR zero.
; Same request fields; preserves P, Y, DP and DBR, clobbers A/X.
; Unlike the public wrapper, does not establish banks or truncate Y.
    .a16
    .i16
requestVramDmaFast:
    JSR requestVramDmaInner
    RTL

; JSR $865F in bank $C0: native M16/X16, decimal clear, DP/DBR zero.
; Same request fields and effects; returns RTS with P/Y preserved, A/X changed.
; $00/$01 are byte head/tail offsets into the 256-byte ring at $0400.
    .a16
    .i16
requestVramDmaInner:
    PHP
    PHY
    SEP #$10
    LDY $0D                ; INIDISP shadow: bit 7 means forced blank.
    BMI transferImmediately

    ; Account bytes before publishing. $1200 is allowed; $1201 must wait.
    ; Arithmetic wraps at 16 bits: callers must keep the sum representable.
    LDA $92
    CLC
    ADC $99
    CMP #$1201
    BCC reserveBudget
waitForBudget:
    LDA $99                ; NMI clears this word at $C08350, after draining.
    BNE waitForBudget
    LDA $92                ; An oversized single request proceeds after reset.
reserveBudget:
    STA $99
    LDY $01
    STY $A5                ; Snapshot tail for the first space test.
    LDY $00

    ; Copy eight contiguous input bytes: profile, size word, source word,
    ; source bank, VRAM word address. Four word stores overlap no fields.
    LDA $91
    STA $0400,Y
    LDA $93
    STA $0402,Y
    LDA $95
    STA $0404,Y
    LDA $97
    STA $0406,Y
    TYA
    CLC
    ADC #$0008
    TAY                    ; X8 truncates the new byte offset modulo 256.
    CPY $A5
    BNE publishHead
waitForRingSpace:
    ; The record is written but hidden from the consumer until head changes.
    ; Only reread the live tail if the cached comparison indicated full.
    CPY $01
    BEQ waitForRingSpace
publishHead:
    ; An interrupt during the full-ring wait can clear $99 after its store;
    ; publication does not restore that accounting for the pending record.
    STY $00
    BRA returnRequest

    .a16
    .i8
transferImmediately:
    ; Each profile is three bytes: DMAP, BBAD, VMAIN. The byte offset in
    ; $91 must select a valid descriptor; no alignment/range check is made.
    LDY $91
    LDA $8FB0,Y
    STA $4310              ; Channel 1 DMAP/BBAD pair.
    LDX $8FB2,Y
    STX $2115              ; VMAIN VRAM increment/address mapping.
    LDA $92
    STA $4315              ; DAS1 byte count (hardware zero means 65536).
    LDA $94
    STA $4312              ; A1T1 source address.
    LDX $96
    STX $4314              ; A1B1 source bank.
    LDA $97
    STA $2116              ; VMADD destination word address.
    LDX #$02
    STX $420B              ; MDMAEN: run channel 1 synchronously.

    ; Synchronize $A1 to $A3 and clear the word at $7E9E2B after transfer.
    ; TODO: Resolve their staging ownership protocol and $7E9E2B's role.
    LDA $00A3
    STA $00A1
    LDA #$0000
    STA $7E9E2B

    .a16
    .i8
returnRequest:
    REP #$10
    PLY
    PLP
    RTS
