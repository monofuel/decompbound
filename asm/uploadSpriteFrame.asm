; Select a resource graphics entry and transfer one normal sprite frame.
; File $00A4C4..$00A53E (123 bytes). Native JSL $C0A4C4.
; DBR=$7E, decimal clear, M16/X16. Y=entity byte offset. Caller D must
; supply $00-$08. Falls through into readSpriteGraphicsEntry, or early-RTL
; through that file's RTL when fill consumes every chunk. Preserves D,
; DBR and stack depth once transferSpriteChunk returns.
; Details: docs/graphics.md (Full normal frame uploads).
    .a16
    .i16
uploadSpriteFrame:
    STY $08                 ; entity byte offset
    LDA $2ABA,Y
    STA $00                 ; remaining chunk count
    LDA $2A7E,Y
    STA $0092               ; bytes per chunk
    LDA $298E,Y
    STA $0097               ; initial VRAM word
    LDA $2A06,Y
    STA $04
    LDA $29CA,Y
    STA $02                 ; inline entry-list far pointer
    LDA $2AF6,Y
    ASL A
    TAX                     ; direction selector * 2; no bounds check
    LDA $C0A60B,X
    BEQ applyPhase
    TAX
    LDA $02
    CLC
advanceDirection:
    ADC #$0004              ; 4 bytes per direction entry
    DEX
    BNE advanceDirection
    STA $02
applyPhase:
    LDA $2892               ; global animation phase
    BEQ checkFill
    INC $02
    INC $02                 ; phase != 0 selects the second word

checkFill:
    LDA [$02]
    AND #$0002              ; graphics-entry bit 1 skips leading fill
    BNE continueToEntry
    LDA $2BAA,Y
    STA $06
    AND #$0008
    BEQ continueToEntry
    ; TODO: $2BAA bit 3/2 enable leading fill chunks; game meaning is open.
    SEP #$20
    .a8
    LDA #$03
    STA $0091               ; DMA profile 3
    LDA #$C4
    STA $0096
    REP #$20
    .a16
    LDA #$0BE8
    STA $0094               ; zero byte at $C40BE8
    JSL $C0A56E             ; transferSpriteChunk; source is not advanced
    DEC $00
    BEQ +63                 ; count exhausted: RTL at $C0A56D in the next file
    LDA $06
    AND #$0004
    BEQ continueToEntry
    JSL $C0A56E
    DEC $00
    BEQ +48                 ; same RTL; prior $341A word survives
continueToEntry:
    LDY $08                 ; restore entity offset; fall through
