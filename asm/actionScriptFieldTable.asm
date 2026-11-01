; Eight base WRAM byte addresses for entity-template word arrays.
; File $009AF9..$009B08 (16 bytes), SNES $C09AF9; field byte times two.
; Consumers add DP+$88 (entity ID times two) to the selected base address.
; Each array has 30 words (60 bytes): these entries are not values or IDs.
; Constructor copies template words $0A38..$0A46 into the matching arrays.
; TODO: Identify broader meanings of template fields 0..7 independently.
; Indices beyond 7 are unguarded. See docs/scripts.md (entity constructor).
actionScriptFieldTable:
    .word $0E5E            ; Field 0, initialized from template word $0A38.
    .word $0E9A            ; Field 1, initialized from template word $0A3A.
    .word $0ED6            ; Field 2, initialized from template word $0A3C.
    .word $0F12            ; Field 3, initialized from template word $0A3E.
    .word $0F4E            ; Field 4, initialized from template word $0A40.
    .word $0F8A            ; Field 5, initialized from template word $0A42.
    .word $0FC6            ; Field 6, initialized from template word $0A44.
    .word $1002            ; Field 7, initialized from template word $0A46.
