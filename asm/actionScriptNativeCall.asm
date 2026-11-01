; Call a three-byte native target with the current script-state value.
; File $00993D..$00995C (32 bytes), SNES $C0993D; JSR/RTS handler.
; Aliases: low opcodes $42/$4C and packed $70..$7F/$F0..$FF (selector 7).
; Native M16/X16, DBR=$7E (or equivalent low-WRAM mirror), valid D scratch.
; DP+$8A is the state byte offset; [$80],Y starts the low-word/bank operand.
; Passes $1516,X in A and stores returned A there; Y advances by three.
; Callee uses RTL, preserves D/DBR/M16/X16 and DP+$8A/$94, plus live VM
; pointers/locals needed by the enclosing fetch loop. X/Y may be clobbered.
; Returns X=state offset; preserves D/DBR/CPU stack depth with that callee.
; Clobbers A/flags, DP+$94 and shared target staging $0A5A..$0A5D.
; Evidence: docs/scripts.md (script-driven removal/native-call sequence).
    .a16
    .i16

actionScriptNativeCall:
    ; Long indexed word reads can cross banks. Y itself wraps at 16 bits;
    ; incrementing it never updates the bank byte at DP+$82.
    LDA [$80],Y
    STA $0A5A              ; Target low word, visible through bank-zero WRAM.
    INY
    INY
    LDA [$80],Y
    INY
    STA $0A5C              ; Bank byte AND the following stream byte, unmasked.
    STY $94                ; Resume cursor after the three-byte operand.

    ; $C09D9E JMLs through bank-zero [$0A5A]; target RTL returns here.
    LDX $8A
    LDA $1516,X            ; VM state argument/result word.
    JSL $C09D9E
    LDX $8A
    STA $1516,X
    LDY $94
    RTS
