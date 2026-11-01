; Four structural near code pointers for byte/word action-script operations.
; File $009ABD..$009AC4 (8 bytes), SNES $C09ABD; operation byte times two.
; Byte operation stages bank $00; word operation retains its current PBR.
; Each handler uses caller-selected M8/M16 and returns RTS, not RTL.
; Indices beyond 3 are unguarded. See docs/scripts.md (bitop sub-operations).
actionScriptOperationTable:
    .word $9AC5            ; 0: target AND immediate.
    .word $9ACC            ; 1: target OR immediate.
    .word $9AD3            ; 2: target plus immediate, incoming carry ignored.
    .word $9ADB            ; 3: target XOR immediate.
