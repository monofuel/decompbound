; Service control/adapters, APU $1609..16A4 / file $26114B..2611E6 (156 bytes).
; CALL/RET entries, DP zero; even channel X=0..14 for channel adapters.
; $1609 advances global countdown $0491: zero does nothing, $FF clears it,
; other values decrement. Expiry writes CONTROL=$31 and calls reset helpers.
; Expiry clears $04B0..04B7 and $1A bits 5..7, sets $46/$47/$5E bits 5..7.
; X/Y preserved; A=0 on expiry/$FF, otherwise old counter minus one (zero stays
; zero). C=1 on all paths; N/Z from A, H/V/P/I/B preserved.
; No DSP writes; CONTROL clears inbound ports/enables timer zero/unmaps IPL.
; TODO: identify the countdown's complete host-level role. See docs/audio.md.
    .org $1609
spcAdvanceServiceCountdown:
    MOV A, !$0491
    CMP A, #$00
    BEQ returnService
    CMP A, #$FF
    BEQ clearCountdown
    DEC A
    MOV !$0491, A
    CMP A, #$00
    BNE returnService
    MOV A, #$31
    MOV !$00F1, A
    CALL $1438            ; Clear copied/pending host-port bytes $04B0..04B7.
    CALL $1453            ; Uninhibit upper voices and mark off/current/dirty bits.
returnService:
    RET
clearCountdown:
    MOV A, #$00
    MOV !$0491, A
    RET

; $162E: A=master volume; shared setter clears fraction, preserves pending fade.
; Returns A=0, Y=input, X preserved, N=0/Z=1; other flags preserved.
spcSetServiceMasterVolume:
    MOV Y, A
    JMP $0A24

; $1632: A=new tempo; saves previous integer at $0493, then sets tempo= A<<8.
; $163B restores a nonzero saved tempo, preserving pending fade. Saved zero
; instead sets duration=0,target=DP $20 and computes a disabled zero-divisor step.
; Zero-saved path needs $44=X and zero word $0E/$0F; uses $12/$14/$15.
; Immediate paths return A=0,Y=tempo,N=0/Z=1, other flags/X preserved;
; zero-saved returns YA=step,X=$44 and flags from the shared divider.
spcSaveAndSetServiceTempo:
    MOV Y, A
    MOV A, $53
    MOV !$0493, A
setTempo:
    JMP $0A3B
spcRestoreServiceTempo:
    MOV A, !$0493
    MOV Y, A
    BNE setTempo
    MOV $54, A
    MOV A, $20
    MOV $55, A
    JMP $0A47             ; Skip stream fetch; signed target-current subtraction.

; $164A: A=delay,$20=rate,$21=depth. Configures pitch modulation without
; consuming stream/resetting elapsed/phase/ramp counters. $165F disables depth
; through the shared depth tail, leaving delay/rate unchanged. Returns A=0,
; N=0/Z=1; X/Y and other flags preserved.
spcConfigureServicePitchModulation:
    MOV $02B0+X, A
    MOV A, $20
    MOV $02A1+X, A
    MOV A, $21
storeDepth:
    MOV $B1+X, A
    MOV $02C1+X, A
    MOV A, #$00
    MOV $02B1+X, A
    RET
spcDisableServicePitchModulation:
    MOV A, #$00
    BEQ storeDepth

; $1663/$1666: full-byte global/channel pitch offsets; all registers/flags
; preserved. Their wrapped carry/masking consumers are the event pitch path.
spcSetServiceGlobalPitchOffset:
    MOV $50, A
    RET
spcSetServiceChannelPitchOffset:
    MOV $02F0+X, A
    RET

; $166A: A=volume; adopted setter clears current fraction, preserves fade.
spcSetServiceChannelVolume:
    CALL $0A86
    RET

; $166E: A=duration,$20=target. Sets saved channel $44, skips stream fetch.
; Current volume unchanged; shared signed divider needs zero $0E/$0F and
; computes step ignoring current fraction. Balances PUSH with tail POP X.
spcSetServiceVolumeTransition:
    MOV $44, X
    MOV $90+X, A
    PUSH A
    MOV A, $20
    JMP $0A95

; $1678/$167D: A=delay,$20=duration,$21=raw interval; selects mode one/zero.
; Writes only pending pitch fields; returns A=interval,N/Z from interval,
; preserving X/Y and other flags. $1692 clears pending duration only.
spcConfigureServicePitchModeOne:
    PUSH A
    MOV A, #$01
    BRA storePitchParameters
spcConfigureServicePitchModeZero:
    PUSH A
    MOV A, #$00
storePitchParameters:
    MOV $0290+X, A
    POP A
    MOV $0281+X, A
    MOV A, $20
    MOV $0280+X, A
    MOV A, $21
    MOV $0291+X, A
    RET
spcClearServicePendingPitch:
    MOV A, #$00
    MOV $0280+X, A
    RET

; $1698: A=control, skips E1's scratch store/override test; sets full control,
; five-bit integer and zero fraction. A=0,N=0/Z=1; X/Y/other flags preserved.
spcSetServicePan:
    JMP $09C8

; $169B: A=duration,$20=target. Sets $44 and skips stream fetch, then uses
; E2's $0431 override and signed division (zero $0E/$0F required). Current
; position/control unchanged; returns A=Y=step high, X restored from $44.
; Override also replaces scratch $20 with decimal ten; uses $12/$14/$15.
spcSetServicePanTransition:
    MOV $44, X
    MOV $91+X, A
    PUSH A
    MOV A, $20
    JMP $09DC
