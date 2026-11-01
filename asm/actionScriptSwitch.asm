; Select a same-stream target from a counted word table, optionally calling it.
; File $009979..$0099C2 (74 bytes), SNES $C09979; JSR/RTS handler $10.
; Native M16/X16, decimal clear, WRAM DBR; DP+$8A is the state byte offset.
; [$80],Y starts at an unsigned byte count; $1516,X is an unsigned word index.
; DP+$90 saves index; $94 saves the cursor T just after count. For index<count,
; Y becomes the word at [$80]+((T+2*index) mod 65536); otherwise Y=T+2*count.
; Preserves D/DBR/widths, stream base/bank and CPU stack depth; clobbers
; A/X/Y/flags, DP+$90/$94. No table/index validation beyond unsigned count.
; Evidence: docs/scripts.md (action VM dispatch and script-state fields).
    .a16
    .i16

actionScriptSwitch:
    LDX $8A
    LDA $1516,X
    STA $90                ; Full unsigned state value, not an 8-bit selector.
    LDA [$80],Y
    AND #$00FF             ; Count byte; the word read also touches table byte 0.
    INY
    STY $94                ; T, with 16-bit wrap and no stream-bank update.
    CMP $90                ; Compare count against index, not the reverse.
    BCC skipTable          ; count < index.
    BNE selectTarget       ; count > index; equality also skips the table.

skipTable:
    ; A=count (0..255). ASL sets C=0, discarding CMP's carry even on equality.
    ; ADC therefore yields T+2*count with NO extra one; sum wraps at 16 bits.
    ASL A
    ADC $94
    TAY
    RTS

selectTarget:
    LDA $90
    ASL A
    CLC                    ; Do not add the shifted index's bit 15 as carry.
    ADC $94
    TAY
    LDA [$80],Y            ; Target word read may itself cross a bank boundary.
    TAY                    ; Only cursor changes; DP+$80/$82 stay unchanged.
    RTS

; $00999E: call variant, JSR/RTS handler $11, same inputs/clobbers as $9979.
; Additionally requires DP+$84 to address this state's software stack in DBR,
; and $12E6,X to be a valid byte offset with room for a word. No bounds check.
; In-range only: push T+2*count at ($84)+oldDepth, increment depth by two,
; then select the target through the shared tail. Out-of-range pushes nothing.
actionScriptSwitchCall:
    LDX $8A
    LDA $1516,X
    STA $90
    LDA [$80],Y
    AND #$00FF
    INY
    STY $94
    CMP $90                ; Both branches share the non-call skip tail.
    BCC skipTable
    BEQ skipTable

    ; A is still count. LDY preserves C, but ASL replaces it with zero:
    ; the saved return cursor is exactly T+2*count, not that value plus one.
    LDY $12E6,X            ; Software stack depth in bytes, not CPU stack S.
    ASL A
    ADC $94
    STA ($84),Y            ; 16-bit DP pointer; stack data uses DBR, not $82.
    INY
    INY
    TYA
    STA $12E6,X            ; Depth arithmetic also wraps without a guard.
    BRA selectTarget
