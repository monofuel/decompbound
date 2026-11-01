; Tail-transfer to the native target staged by the action VM.
; File $009D9E..$009DA0 (3 bytes), SNES $C09D9E; JML trampoline.
; [$0A5A] is an absolute-long-indirect pointer in BANK ZERO, independent of
; DBR/PBR/D: bytes $0A5A/$0A5B/$0A5C supply address low/high/bank.
; Thus staging stores must reach the matching $7E low-WRAM alias, not $7F.
; Passes registers/status unchanged. JSL callers need an RTL target; byte-op
; near JSR callers need RTS. RTS retains the target PBR, so return code must
; exist in that bank's mirror. No local stack frame or width change.
; Evidence: docs/scripts.md (script-driven removal/native-call sequence).
    .a16
    .i16

callEntityNativeTarget:
    JML [$0A5A]
