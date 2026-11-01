; Parse token/prefix, APU $089E..$08E5 / file $2603E0..$260427 (72 bytes).
; Branch entry from $0882: DP zero, even X, A=Y=prefetched token and N reflects it.
; Normal $0882 entry already filters initial zero. Uses live cursor $30/$31+X;
; callbacks require saved $44=X, zero word $0E/$0F and valid finite driver state.
; Optional prefix writes $0200/$0201/$0210+X; events set counters $70/$71+X.
; Commands invoke $0943 then fetch again; metadata alone is not total width.
; Event guard $0400+X|$1B skips $0654, but counter setup and $08ED still run.
; Event/counter paths preserve X/SP/P/I/B with valid callbacks; command-handler
; effects are inherited. No local RET; see docs/audio.md for callback state/ports.
    .org $089E
spcParseSequencePrefix:
    BMI classifyToken      ; Inherits the prefetched byte's N flag.
    MOV $0200+X, A         ; First nonnegative byte becomes duration.
    CALL $0955             ; spcSequenceFetch: candidate packed prefix or token.
    BMI classifyToken

    ; Every nonnegative second byte, including zero, selects both tables.
    PUSH A
    XCN A
    AND A, #$07
    MOV Y, A
    MOV A, $6F80+Y         ; Eight-byte table: packed bits 4..6.
    MOV $0201+X, A         ; Factor used in the secondary countdown product.
    POP A
    AND A, #$0F
    MOV Y, A
    MOV A, $6F88+Y         ; Sixteen-byte table: packed bits 0..3.
    MOV $0210+X, A         ; Channel factor later consumed by gain calculation.
    CALL $0955             ; Third byte goes straight to classification, even zero.

classifyToken:
    CMP A, #$E0
    BCC prepareEvent
    CALL $0943             ; spcDispatchCommand: actual handler may fetch more bytes.
    BRA $0882              ; spcFetchSequenceEvent resumes after the command.
prepareEvent:
    MOV A, $0400+X
    OR A, $1B
    BNE initializeCounters
    MOV A, Y
    CALL $0654             ; spcPrepareChannelEvent may accept, reject or select instrument.

; Shared counter setup $08D4: reads duration $0200+X and factor $0201+X.
; Sets $70=duration, $71=max(1,high(duration*factor)); preserves X/C/H/V.
; A=clamped count, Y=unclamped high product; then enters shared service $08ED.
initializeCounters:
    MOV A, $0200+X
    MOV $70+X, A
    MOV Y, A
    MOV A, $0201+X
    MUL YA
    MOV A, Y
    BNE storeSecondaryCount
    INC A                  ; Only the secondary countdown is clamped to one.
storeSecondaryCount:
    MOV $71+X, A
    BRA $08ED              ; Shared event service runs even when $1B skipped setup.
