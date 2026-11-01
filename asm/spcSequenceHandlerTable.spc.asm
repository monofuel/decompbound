; Native command targets, APU $0BE3..0C20 / file $260725..260762 (62 bytes).
; Structural code-pointer table, read by spcDispatchCommand at $0943.
; E0..FE occupy these 31 little-endian words. Indexing is raw/wrapped:
; target = word[$0B23 + ((command*2)&255)]; no domain check is added.
; Other commands may read adjacent code/data; FF reads operand metadata as
; its target word. The 31 prefetch metadata bytes at $0C21..0C3F stay copied.
    .org $0BE3
spcSequenceHandlerTable:
    .word $095F           ; E0: instrument selection.
    .word $09B8           ; E1: pan/control setter.
    .word $09D6           ; E2: pan transition.
    .word $09FD           ; E3: pitch-modulation setup.
    .word $0A09           ; E4: pitch-modulation depth.
    .word $0A24           ; E5: master volume.
    .word $0A29           ; E6: master-volume transition.
    .word $0A3B           ; E7: tempo.
    .word $0A40           ; E8: tempo transition.
    .word $0A52           ; E9: global pitch offset.
    .word $0A55           ; EA: channel pitch offset.
    .word $0A59           ; EB: volume-modulation setup.
    .word $0A65           ; EC: shared volume-modulation depth store.
    .word $0A86           ; ED: channel volume.
    .word $0A8F           ; EE: channel-volume transition.
    .word $0AAC           ; EF: single-slot sequence call.
    .word $0A14           ; F0: pitch-modulation ramp.
    .word $0A68           ; F1: pending pitch-transition mode-one entry.
    .word $0A6C           ; F2: pending pitch-transition mode-zero entry.
    .word $0A82           ; F3: pending pitch duration.
    .word $0AA8           ; F4: event pitch fraction.
    .word $0ACF           ; F5: echo mask/volume.
    .word $0B03           ; F6: disable echo writes.
    .word $0B0A           ; F7: echo configuration.
    .word $0AE2           ; F8: echo-volume transition.
    .word $0B94           ; F9: active pitch transition.
    .word $0B72           ; FA: instrument remap base.
    .word $0B75           ; FB: skip operand.
    .word $0B79           ; FC: event guard.
    .word $0B7E           ; FD: increment processing mode before shared store.
    .word $0B7F           ; FE: processing-mode store/shared cleanup.
