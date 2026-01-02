## Early-ROM subroutines for Earthbound.
## These are subroutines called during initialization.

import
  ./common

proc generateEarlySubroutine*(): seq[uint8] =
  ## Generate the early-ROM subroutine at 0x0A1D.
  ## This subroutine is called from the initialization code at 0x010000.
  ## TODO: Reverse engineer this subroutine into proper Nim functions.
  result = newSeq[uint8](EarlySubroutineSize)
  
  # 0x0A1D-0x0A2C: Initial conditional calls
  result[0x00] = 0xF0  # BEQ $0A25 (Branch if Equal to zero, relative addressing)
  result[0x01] = 0x06  # Relative offset: +6 bytes (branches to $0A25 if zero)
  result[0x02] = 0x22  # JSL $EFD9F3 (Jump to Subroutine Long)
  result[0x03] = 0xF3  # Low byte
  result[0x04] = 0xD9  # Mid byte
  result[0x05] = 0xEF  # High byte (full address: $EFD9F3)
  # TODO: Reverse engineer what the subroutine at $EFD9F3 does
  result[0x06] = 0x80  # BRA $0A23 (Branch Always, relative addressing)
  result[0x07] = 0x04  # Relative offset: +4 bytes (jumps to $0A23)
  result[0x08] = 0x22  # JSL $C47F87 (Jump to Subroutine Long)
  result[0x09] = 0x87  # Low byte
  result[0x0A] = 0x7F  # Mid byte
  result[0x0B] = 0xC4  # High byte (full address: $C47F87)
  # TODO: Reverse engineer what the subroutine at $C47F87 does
  result[0x0C] = 0xA9  # LDA #$0000 (Load Accumulator, immediate mode)
  result[0x0D] = 0x00  # Low byte: 0x00
  result[0x0E] = 0x00  # High byte: 0x00 (value is 0x0000)
  result[0x0F] = 0x22  # JSL $C0856B (Jump to Subroutine Long)
  result[0x10] = 0x6B  # Low byte
  result[0x11] = 0x85  # Mid byte
  result[0x12] = 0xC0  # High byte (full address: $C0856B)
  # TODO: Reverse engineer what the subroutine at $C0856B does
  
  # 0x0A2D-0x0A3C: Register and memory setup
  result[0x13] = 0xA9  # LDA #$0002 (Load Accumulator, immediate mode)
  result[0x14] = 0x00  # Low byte: 0x00 (little-endian: low byte first)
  result[0x15] = 0x02  # High byte: 0x02 (value is 0x0002)
  result[0x16] = 0x85  # STA $06 (Store Accumulator, direct page addressing)
  result[0x17] = 0x06  # Direct page address $06
  # TODO: Determine what memory location $06 represents
  result[0x18] = 0x8B  # PHB (Push Data Bank register to stack)
  result[0x19] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x1A] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x1B] = 0x68  # PLA (Pull Accumulator from stack)
  result[0x1C] = 0x85  # STA $08 (Store Accumulator, direct page addressing)
  result[0x1D] = 0x08  # Direct page address $08
  # TODO: Determine what memory location $08 represents
  result[0x1E] = 0x64  # STZ $09 (Store Zero, direct page addressing - clears memory)
  result[0x1F] = 0x09  # Direct page address $09
  # TODO: Determine what memory location $09 represents
  
  # 0x0A3D-0x0A4C: Memory calculations and setup
  result[0x20] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x21] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x22] = 0xA9  # LDA #$0040 (Load Accumulator, immediate mode)
  result[0x23] = 0x40  # Low byte: 0x40
  result[0x24] = 0x00  # High byte: 0x00 (value is 0x0040)
  result[0x25] = 0x18  # CLC (Clear Carry flag)
  result[0x26] = 0x65  # ADC $06 (Add with Carry, direct page addressing)
  result[0x27] = 0x06  # Direct page address $06
  result[0x28] = 0x85  # STA $06 (Store Accumulator, direct page addressing)
  result[0x29] = 0x06  # Direct page address $06
  result[0x2A] = 0x85  # STA $0E (Store Accumulator, direct page addressing)
  result[0x2B] = 0x0E  # Direct page address $0E
  # TODO: Determine what memory location $0E represents
  result[0x2C] = 0xA5  # LDA $08 (Load Accumulator, direct page addressing)
  result[0x2D] = 0x08  # Direct page address $08
  result[0x2E] = 0x85  # STA $10 (Store Accumulator, direct page addressing)
  result[0x2F] = 0x10  # Direct page address $10
  # TODO: Determine what memory location $10 represents
  
  # 0x0A4D-0x0A5C: Subroutine calls and conditional logic
  result[0x30] = 0xA2  # LDX #$01C0 (Load X register, immediate mode)
  result[0x31] = 0xC0  # Low byte: 0xC0
  result[0x32] = 0x01  # High byte: 0x01 (value is 0x01C0)
  result[0x33] = 0xA9  # LDA #$4476 (Load Accumulator, immediate mode)
  result[0x34] = 0x76  # Low byte: 0x76
  result[0x35] = 0x44  # High byte: 0x44 (value is 0x4476)
  # TODO: Understand why 0x4476 is loaded
  result[0x36] = 0x22  # JSL $C08ED2 (Jump to Subroutine Long)
  result[0x37] = 0xD2  # Low byte
  result[0x38] = 0x8E  # Mid byte
  result[0x39] = 0xC0  # High byte (full address: $C08ED2)
  # TODO: Reverse engineer what the subroutine at $C08ED2 does
  result[0x3A] = 0xAD  # LDA $4676 (Load Accumulator, absolute addressing)
  result[0x3B] = 0x76  # Low byte of address
  result[0x3C] = 0x46  # High byte of address (full address: $4676)
  # TODO: Determine what memory location $4676 represents
  result[0x3D] = 0xF0  # BEQ $0A78 (Branch if Equal to zero, relative addressing)
  result[0x3E] = 0x19  # Relative offset: +25 bytes (branches to $0A78 if zero)
  
  # 0x0A5D-0x0A6C: Conditional subroutine calls
  result[0x3F] = 0x22  # JSL $C496F9 (Jump to Subroutine Long)
  result[0x40] = 0xF9  # Low byte
  result[0x41] = 0x96  # Mid byte
  result[0x42] = 0xC4  # High byte (full address: $C496F9)
  # TODO: Reverse engineer what the subroutine at $C496F9 does
  result[0x43] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x44] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x45] = 0xA9  # LDA #$FF (Load Accumulator, immediate mode)
  result[0x46] = 0xFF  # Immediate value: 0xFF
  result[0x47] = 0x85  # STA $0E (Store Accumulator, direct page addressing)
  result[0x48] = 0x0E  # Direct page address $0E
  result[0x49] = 0xA2  # LDX #$0200 (Load X register, immediate mode)
  result[0x4A] = 0x00  # Low byte: 0x00
  result[0x4B] = 0x02  # High byte: 0x02 (value is 0x0200)
  result[0x4C] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x4D] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x4E] = 0xA9  # LDA #$0002 (Load Accumulator, immediate mode)
  result[0x4F] = 0x00  # Low byte: 0x00 (little-endian: low byte first)
  result[0x50] = 0x02  # High byte: 0x02 (value is 0x0002)
  result[0x51] = 0x22  # JSL $C08EFC (Jump to Subroutine Long)
  result[0x52] = 0xFC  # Low byte
  result[0x53] = 0x8E  # Mid byte
  result[0x54] = 0xC0  # High byte (full address: $C08EFC)
  # TODO: Reverse engineer what the subroutine at $C08EFC does
  
  # 0x0A6D-0x0A7C: Memory clearing and additional calls
  result[0x55] = 0x9C  # STZ $4676 (Store Zero, absolute addressing - clears memory)
  result[0x56] = 0x76  # Low byte of address
  result[0x57] = 0x46  # High byte of address (full address: $4676)
  result[0x58] = 0xAD  # LDA $B4EF (Load Accumulator, absolute addressing)
  result[0x59] = 0xEF  # Low byte of address
  result[0x5A] = 0xB4  # High byte of address (full address: $B4EF)
  # TODO: Determine what memory location $B4EF represents
  result[0x5B] = 0xF0  # BEQ $0A91 (Branch if Equal to zero, relative addressing)
  result[0x5C] = 0x14  # Relative offset: +20 bytes (branches to $0A91 if zero)
  result[0x5D] = 0x22  # JSL $C496F9 (Jump to Subroutine Long)
  result[0x5E] = 0xF9  # Low byte
  result[0x5F] = 0x96  # Mid byte
  result[0x60] = 0xC4  # High byte (full address: $C496F9)
  result[0x61] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x62] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x63] = 0x64  # STZ $0E (Store Zero, direct page addressing - clears memory)
  result[0x64] = 0x0E  # Direct page address $0E
  result[0x65] = 0xA2  # LDX #$01E0 (Load X register, immediate mode)
  result[0x66] = 0xE0  # Low byte: 0xE0
  result[0x67] = 0x01  # High byte: 0x01 (value is 0x01E0)
  result[0x68] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x69] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x6A] = 0xA9  # LDA #$0220 (Load Accumulator, immediate mode)
  result[0x6B] = 0x20  # Low byte: 0x20 (little-endian: low byte first)
  result[0x6C] = 0x02  # High byte: 0x02 (value is 0x0220)
  result[0x6D] = 0x22  # JSL $C08EFC (Jump to Subroutine Long)
  result[0x6E] = 0xFC  # Low byte
  result[0x6F] = 0x8E  # Mid byte
  result[0x70] = 0xC0  # High byte (full address: $C08EFC)
  
  # 0x0A7D-0x0A8C: Final subroutine call and memory operations
  result[0x71] = 0xA9  # LDA #$0018 (Load Accumulator, immediate mode)
  result[0x72] = 0x18  # Low byte: 0x18
  result[0x73] = 0x00  # High byte: 0x00 (value is 0x0018)
  result[0x74] = 0x22  # JSL $C0856B (Jump to Subroutine Long)
  result[0x75] = 0x6B  # Low byte
  result[0x76] = 0x85  # Mid byte
  result[0x77] = 0xC0  # High byte (full address: $C0856B)
  result[0x78] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0x79] = 0x04  # Direct page address $04
  # TODO: Determine what memory location $04 represents
  result[0x7A] = 0x8D  # STA $436E (Store Accumulator, absolute addressing)
  result[0x7B] = 0x6E  # Low byte of address
  result[0x7C] = 0x43  # High byte of address (full address: $436E)
  # TODO: Determine what memory location $436E represents
  result[0x7D] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0x7E] = 0x18  # Direct page address $18
  # TODO: Determine what memory location $18 represents
  result[0x7F] = 0x8D  # STA $4370 (Store Accumulator, absolute addressing)
  
  # 0x0A9D-0x0AAC: Memory operations and register manipulation
  result[0x80] = 0x70  # Low byte of address for STA $4370
  result[0x81] = 0x43  # High byte of address (full address: $4370)
  # TODO: Determine what memory location $4370 represents
  result[0x82] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x83] = 0x60  # RTS (Return from Subroutine)
  result[0x84] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x85] = 0x31  # Immediate value: clear C, Z, N, M flags
  result[0x86] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x87] = 0x48  # PHA (Push Accumulator to stack)
  result[0x88] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0x89] = 0x69  # ADC #$FFF2 (Add with Carry, immediate mode)
  result[0x8A] = 0xF2  # Low byte: 0xF2
  result[0x8B] = 0xFF  # High byte: 0xFF (value is 0xFFF2, which is -14 in two's complement)
  # TODO: Understand why -14 is added to direct page register
  result[0x8C] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  result[0x8D] = 0x68  # PLA (Pull Accumulator from stack)
  result[0x8E] = 0xEB  # XBA (Exchange B and A accumulator bytes)
  result[0x8F] = 0x29  # AND #$00FF (Logical AND, immediate mode)
  result[0x90] = 0xFF  # Low byte: 0xFF
  result[0x91] = 0x00  # High byte: 0x00 (masks to low byte)
  result[0x92] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0x93] = 0x02  # Direct page address $02
  # TODO: Determine what memory location $02 represents
  result[0x94] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0x95] = 0x29  # AND #$FF80 (Logical AND, immediate mode)
  result[0x96] = 0x80  # Low byte: 0x80
  result[0x97] = 0xFF  # High byte: 0xFF (masks to high 7 bits)
  # TODO: Understand the bit masking operation
  
  # 0x0AAD-0x0ABC: Bit shifting and memory lookup
  result[0x98] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x99] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x9A] = 0x18  # CLC (Clear Carry flag)
  result[0x9B] = 0x65  # ADC $02 (Add with Carry, direct page addressing)
  result[0x9C] = 0x02  # Direct page address $02
  result[0x9D] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x9E] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0x9F] = 0xBF  # LDA $D7B200,X (Load Accumulator, absolute long indexed X)
  result[0xA0] = 0x00  # Low byte of address
  result[0xA1] = 0xB2  # Mid byte of address
  result[0xA2] = 0xD7  # High byte of address (full address: $D7B200)
  # TODO: Determine what memory location $D7B200 represents
  result[0xA3] = 0x8D  # STA $438E (Store Accumulator, absolute addressing)
  result[0xA4] = 0x8E  # Low byte of address
  result[0xA5] = 0x43  # High byte of address (full address: $438E)
  # TODO: Determine what memory location $438E represents
  result[0xA6] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0xA7] = 0x6B  # RTL (Return from Subroutine Long)
  result[0xA8] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0xA9] = 0x31  # Immediate value: clear C, Z, N, M flags
  result[0xAA] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0xAB] = 0x48  # PHA (Push Accumulator to stack)
  result[0xAC] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0xAD] = 0x69  # ADC #$FFE6 (Add with Carry, immediate mode)
  result[0xAE] = 0xE6  # Low byte: 0xE6
  result[0xAF] = 0xFF  # High byte: 0xFF (value is 0xFFE6, which is -26 in two's complement)
  # TODO: Understand why -26 is added to direct page register
  
  # 0x0ACD-0x0ADC: Register operations and conditional logic
  result[0xB0] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  result[0xB1] = 0x68  # PLA (Pull Accumulator from stack)
  result[0xB2] = 0x85  # STA $18 (Store Accumulator, direct page addressing)
  result[0xB3] = 0x18  # Direct page address $18
  result[0xB4] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0xB5] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0xB6] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0xB7] = 0x85  # STA $04 (Store Accumulator, direct page addressing)
  result[0xB8] = 0x04  # Direct page address $04
  result[0xB9] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0xBA] = 0x18  # Direct page address $18
  result[0xBB] = 0x29  # AND #$8000 (Logical AND, immediate mode)
  result[0xBC] = 0x00  # Low byte: 0x00
  result[0xBD] = 0x80  # High byte: 0x80 (masks to sign bit)
  result[0xBE] = 0xF0  # BEQ $0AE9 (Branch if Equal to zero, relative addressing)
  result[0xBF] = 0x0C  # Relative offset: +12 bytes (branches to $0AE9 if zero)
  
  # 0x0ADD-0x0AEC: Conditional value assignment
  result[0xC0] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0xC1] = 0x18  # Direct page address $18
  result[0xC2] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0xC3] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0xC4] = 0x09  # ORA #$E000 (Logical OR, immediate mode)
  result[0xC5] = 0x00  # Low byte: 0x00
  result[0xC6] = 0xE0  # High byte: 0xE0 (value is 0xE000)
  # TODO: Understand why 0xE000 is ORed
  result[0xC7] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0xC8] = 0x84  # STY $16 (Store Y register, direct page addressing)
  result[0xC9] = 0x16  # Direct page address $16
  # TODO: Determine what memory location $16 represents
  result[0xCA] = 0x80  # BRA $0AF0 (Branch Always, relative addressing)
  result[0xCB] = 0x07  # Relative offset: +7 bytes (jumps to $0AF0)
  result[0xCC] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0xCD] = 0x18  # Direct page address $18
  result[0xCE] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0xCF] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0xD0] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0xD1] = 0x84  # STY $16 (Store Y register, direct page addressing)
  result[0xD2] = 0x16  # Direct page address $16
  
  # 0x0AED-0x0AFC: Bit masking and memory operations
  result[0xD3] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0xD4] = 0x29  # AND #$000F (Logical AND, immediate mode)
  result[0xD5] = 0x0F  # Low byte: 0x0F
  result[0xD6] = 0x00  # High byte: 0x00 (masks to low 4 bits)
  result[0xD7] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0xD8] = 0x86  # STX $18 (Store X register, direct page addressing)
  result[0xD9] = 0x18  # Direct page address $18
  result[0xDA] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0xDB] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0xDC] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0xDD] = 0x9D  # STA $4390,X (Store Accumulator, absolute indexed X)
  result[0xDE] = 0x90  # Low byte of address
  result[0xDF] = 0x43  # High byte of address (full address: $4390)
  # TODO: Determine what memory location $4390 represents
  result[0xE0] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0xE1] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0xE2] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0xE3] = 0x04  # Direct page address $04
  result[0xE4] = 0x29  # AND #$000F (Logical AND, immediate mode)
  result[0xE5] = 0x0F  # Low byte: 0x0F
  result[0xE6] = 0x00  # High byte: 0x00 (masks to low 4 bits)
  result[0xE7] = 0x85  # STA $14 (Store Accumulator, direct page addressing)
  result[0xE8] = 0x14  # Direct page address $14
  # TODO: Determine what memory location $14 represents
  result[0xE9] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0xEA] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0xEB] = 0x04  # Direct page address $04
  result[0xEC] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0xED] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0xEE] = 0x9D  # STA $43A0,X (Store Accumulator, absolute indexed X)
  result[0xEF] = 0xA0  # Low byte of address
  result[0xF0] = 0x43  # High byte of address (full address: $43A0)
  # TODO: Determine what memory location $43A0 represents
  
  # 0x0B0D-0x0B1C: Final bit operations
  result[0xF1] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0xF2] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0xF3] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0xF4] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0xF5] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0xF6] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0xF7] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0xF8] = 0x02  # Direct page address $02
  result[0xF9] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0xFA] = 0x04  # Direct page address $04
  result[0xFB] = 0x29  # AND #$FFFC (Logical AND, immediate mode)
  result[0xFC] = 0xFC  # Low byte: 0xFC
  result[0xFD] = 0xFF  # High byte: 0xFF (masks to clear low 2 bits)
  result[0xFE] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0xFF] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  
  # 0x0B1D-0x0B2C: Arithmetic operations and memory lookup
  result[0x100] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x101] = 0x18  # CLC (Clear Carry flag)
  result[0x102] = 0x65  # ADC $02 (Add with Carry, direct page addressing)
  result[0x103] = 0x02  # Direct page address $02
  result[0x104] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0x105] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x106] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x107] = 0xBF  # LDA $D7A800,X (Load Accumulator, absolute long indexed X)
  result[0x108] = 0x00  # Low byte of address
  result[0x109] = 0xA8  # Mid byte of address
  result[0x10A] = 0xD7  # High byte of address (full address: $D7A800)
  # TODO: Determine what memory location $D7A800 represents
  result[0x10B] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x10C] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x10D] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x10E] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x10F] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x110] = 0x29  # AND #$00FF (Logical AND, immediate mode)
  result[0x111] = 0xFF  # Low byte: 0xFF
  result[0x112] = 0x00  # High byte: 0x00 (masks to low byte)
  result[0x113] = 0x85  # STA $12 (Store Accumulator, direct page addressing)
  result[0x114] = 0x12  # Direct page address $12
  result[0x115] = 0xA5  # LDA $14 (Load Accumulator, direct page addressing)
  result[0x116] = 0x14  # Direct page address $14
  result[0x117] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x118] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  result[0x119] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  result[0x11A] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  result[0x11B] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  # TODO: Understand why accumulator is shifted left 5 times (multiply by 32)
  
  # 0x0B2D-0x0B3C: Addition and comparison
  result[0x11C] = 0x18  # CLC (Clear Carry flag)
  result[0x11D] = 0x69  # ADC #$F000 (Add with Carry, immediate mode)
  result[0x11E] = 0x00  # Low byte: 0x00
  result[0x11F] = 0xF0  # High byte: 0xF0 (value is 0xF000)
  # TODO: Understand why 0xF000 is added
  result[0x120] = 0x85  # STA $14 (Store Accumulator, direct page addressing)
  result[0x121] = 0x14  # Direct page address $14
  result[0x122] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0x123] = 0x04  # Direct page address $04
  result[0x124] = 0xC9  # CMP #$0140 (Compare Accumulator, immediate mode)
  result[0x125] = 0x40  # Low byte: 0x40
  result[0x126] = 0x01  # High byte: 0x01 (value is 0x0140)
  # TODO: Understand the comparison operation
  result[0x127] = 0x90  # BCC $0B3C (Branch if Carry Clear, relative addressing)
  result[0x128] = 0x03  # Relative offset: +3 bytes (branches to $0B3C if carry clear)
  result[0x129] = 0x4C  # JMP $0BC2 (Jump, absolute addressing)
  result[0x12A] = 0xC2  # Low byte of address
  result[0x12B] = 0x0B  # High byte of address (full address: $0BC2)
  # TODO: Reverse engineer what the code at $0BC2 does
  result[0x12C] = 0xA6  # LDX $18 (Load X register, direct page addressing)
  result[0x12D] = 0x18  # Direct page address $18
  result[0x12E] = 0x86  # STX $02 (Store X register, direct page addressing)
  result[0x12F] = 0x02  # Direct page address $02
  
  # 0x0B3D-0x0B4C: Memory operations and conditional logic
  result[0x130] = 0xA5  # LDA $02 (Load Accumulator, direct page addressing)
  result[0x131] = 0x02  # Direct page address $02
  result[0x132] = 0x85  # STA $10 (Store Accumulator, direct page addressing)
  result[0x133] = 0x10  # Direct page address $10
  # TODO: Determine what memory location $10 represents
  result[0x134] = 0x64  # STZ $0E (Store Zero, direct page addressing - clears memory)
  result[0x135] = 0x0E  # Direct page address $0E
  result[0x136] = 0x80  # BRA $0B4C (Branch Always, relative addressing)
  result[0x137] = 0x64  # Relative offset: +100 bytes (jumps to $0B4C)
  result[0x138] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0x139] = 0x29  # AND #$0007 (Logical AND, immediate mode)
  result[0x13A] = 0x07  # Low byte: 0x07
  result[0x13B] = 0x00  # High byte: 0x00 (masks to low 3 bits)
  result[0x13C] = 0xD0  # BNE $0B60 (Branch if Not Equal, relative addressing)
  result[0x13D] = 0x22  # Relative offset: +34 bytes (branches to $0B60 if not equal)
  result[0x13E] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0x13F] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x140] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x141] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x142] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0x143] = 0x02  # Direct page address $02
  result[0x144] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0x145] = 0x04  # Direct page address $04
  result[0x146] = 0x29  # AND #$FFFC (Logical AND, immediate mode)
  result[0x147] = 0xFC  # Low byte: 0xFC
  result[0x148] = 0xFF  # High byte: 0xFF (masks to clear low 2 bits)
  result[0x149] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x14A] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  result[0x14B] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator again)
  result[0x14C] = 0x18  # CLC (Clear Carry flag)
  result[0x14D] = 0x65  # ADC $02 (Add with Carry, direct page addressing)
  result[0x14E] = 0x02  # Direct page address $02
  result[0x14F] = 0xAA  # TAX (Transfer Accumulator to X register)
  
  # 0x0B4D-0x0B5C: Memory lookup and bit operations
  result[0x150] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x151] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x152] = 0xBF  # LDA $D7A800,X (Load Accumulator, absolute long indexed X)
  result[0x153] = 0x00  # Low byte of address
  result[0x154] = 0xA8  # Mid byte of address
  result[0x155] = 0xD7  # High byte of address (full address: $D7A800)
  result[0x156] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x157] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x158] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x159] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x15A] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x15B] = 0x29  # AND #$00FF (Logical AND, immediate mode)
  result[0x15C] = 0xFF  # Low byte: 0xFF
  result[0x15D] = 0x00  # High byte: 0x00 (masks to low byte)
  result[0x15E] = 0x85  # STA $12 (Store Accumulator, direct page addressing)
  result[0x15F] = 0x12  # Direct page address $12
  result[0x160] = 0xC0  # CPY #$0100 (Compare Y register, immediate mode)
  result[0x161] = 0x00  # Low byte: 0x00
  result[0x162] = 0x01  # High byte: 0x01 (value is 0x0100)
  result[0x163] = 0xB0  # BCS $0B7A (Branch if Carry Set, relative addressing)
  result[0x164] = 0x1B  # Relative offset: +27 bytes (branches to $0B7A if carry set)
  result[0x165] = 0xAD  # LDA $436E (Load Accumulator, absolute addressing)
  result[0x166] = 0x6E  # Low byte of address
  result[0x167] = 0x43  # High byte of address (full address: $436E)
  # TODO: Determine what memory location $436E represents
  result[0x168] = 0xC5  # CMP $12 (Compare Accumulator, direct page addressing)
  result[0x169] = 0x12  # Direct page address $12
  result[0x16A] = 0xD0  # BNE $0B7A (Branch if Not Equal, relative addressing)
  result[0x16B] = 0x14  # Relative offset: +20 bytes (branches to $0B7A if not equal)
  
  # 0x0B5D-0x0B6C: Subroutine call and memory operations
  result[0x16C] = 0xA6  # LDX $04 (Load X register, direct page addressing)
  result[0x16D] = 0x04  # Direct page address $04
  result[0x16E] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0x16F] = 0x20  # JSR $A156 (Jump to Subroutine, absolute)
  result[0x170] = 0x56  # Low byte of address
  result[0x171] = 0xA1  # High byte of address (full address: $A156)
  # TODO: Reverse engineer what the subroutine at $A156 does
  result[0x172] = 0x85  # STA $18 (Store Accumulator, direct page addressing)
  result[0x173] = 0x18  # Direct page address $18
  result[0x174] = 0xA5  # LDA $10 (Load Accumulator, direct page addressing)
  result[0x175] = 0x10  # Direct page address $10
  result[0x176] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0x177] = 0x02  # Direct page address $02
  result[0x178] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x179] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0x17A] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0x17B] = 0x18  # Direct page address $18
  result[0x17C] = 0x91  # STA ($14),Y (Store Accumulator, indirect indexed Y addressing)
  result[0x17D] = 0x14  # Direct page address $14
  result[0x17E] = 0x80  # BRA $0B8B (Branch Always, relative addressing)
  result[0x17F] = 0x0B  # Relative offset: +11 bytes (jumps to $0B8B)
  
  # 0x0B6D-0x0B7C: Alternative memory operations
  result[0x180] = 0xA5  # LDA $10 (Load Accumulator, direct page addressing)
  result[0x181] = 0x10  # Direct page address $10
  result[0x182] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0x183] = 0x02  # Direct page address $02
  result[0x184] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x185] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0x186] = 0xA9  # LDA #$0000 (Load Accumulator, immediate mode)
  result[0x187] = 0x00  # Low byte: 0x00
  result[0x188] = 0x00  # High byte: 0x00 (value is 0x0000)
  result[0x189] = 0x91  # STA ($14),Y (Store Accumulator, indirect indexed Y addressing)
  result[0x18A] = 0x14  # Direct page address $14
  result[0x18B] = 0xA5  # LDA $02 (Load Accumulator, direct page addressing)
  result[0x18C] = 0x02  # Direct page address $02
  result[0x18D] = 0x1A  # INC A (Increment Accumulator)
  result[0x18E] = 0x29  # AND #$000F (Logical AND, immediate mode)
  result[0x18F] = 0x0F  # Low byte: 0x0F
  result[0x190] = 0x00  # High byte: 0x00 (masks to low 4 bits)
  result[0x191] = 0x85  # STA $02 (Store Accumulator, direct page addressing)
  result[0x192] = 0x02  # Direct page address $02
  result[0x193] = 0x85  # STA $10 (Store Accumulator, direct page addressing)
  result[0x194] = 0x10  # Direct page address $10
  result[0x195] = 0xA4  # LDY $16 (Load Y register, direct page addressing)
  result[0x196] = 0x16  # Direct page address $16
  result[0x197] = 0xC8  # INY (Increment Y register)
  result[0x198] = 0x84  # STY $16 (Store Y register, direct page addressing)
  result[0x199] = 0x16  # Direct page address $16
  result[0x19A] = 0xE6  # INC $0E (Increment, direct page addressing)
  result[0x19B] = 0x0E  # Direct page address $0E
  result[0x19C] = 0xA5  # LDA $0E (Load Accumulator, direct page addressing)
  result[0x19D] = 0x0E  # Direct page address $0E
  result[0x19E] = 0xC9  # CMP #$0010 (Compare Accumulator, immediate mode)
  result[0x19F] = 0x10  # Low byte: 0x10
  result[0x1A0] = 0x00  # High byte: 0x00 (value is 0x0010)
  result[0x1A1] = 0x90  # BCC $0B38 (Branch if Carry Clear, relative addressing)
  result[0x1A2] = 0x95  # Relative offset: -107 bytes (branches to $0B38 if carry clear)
  result[0x1A3] = 0x80  # BRA $0BBD (Branch Always, relative addressing)
  result[0x1A4] = 0x18  # Relative offset: +24 bytes (jumps to $0BBD)
  
  # 0x0B7D-0x0B8C: Loop initialization
  result[0x1A5] = 0xA9  # LDA #$0000 (Load Accumulator, immediate mode)
  result[0x1A6] = 0x00  # Low byte: 0x00
  result[0x1A7] = 0x00  # High byte: 0x00 (value is 0x0000)
  result[0x1A8] = 0x85  # STA $18 (Store Accumulator, direct page addressing)
  result[0x1A9] = 0x18  # Direct page address $18
  result[0x1AA] = 0x80  # BRA $0BC8 (Branch Always, relative addressing)
  result[0x1AB] = 0x0C  # Relative offset: +12 bytes (jumps to $0BC8)
  result[0x1AC] = 0x0A  # ASL A (Arithmetic Shift Left Accumulator)
  result[0x1AD] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0x1AE] = 0xA9  # LDA #$0000 (Load Accumulator, immediate mode)
  result[0x1AF] = 0x00  # Low byte: 0x00
  result[0x1B0] = 0x00  # High byte: 0x00 (value is 0x0000)
  result[0x1B1] = 0x91  # STA ($14),Y (Store Accumulator, indirect indexed Y addressing)
  result[0x1B2] = 0x14  # Direct page address $14
  result[0x1B3] = 0xA5  # LDA $18 (Load Accumulator, direct page addressing)
  result[0x1B4] = 0x18  # Direct page address $18
  result[0x1B5] = 0x1A  # INC A (Increment Accumulator)
  result[0x1B6] = 0x85  # STA $18 (Store Accumulator, direct page addressing)
  result[0x1B7] = 0x18  # Direct page address $18
  result[0x1B8] = 0xC9  # CMP #$0010 (Compare Accumulator, immediate mode)
  result[0x1B9] = 0x10  # Low byte: 0x10
  result[0x1BA] = 0x00  # High byte: 0x00 (value is 0x0010)
  result[0x1BB] = 0x90  # BCC $0BB0 (Branch if Carry Clear, relative addressing)
  result[0x1BC] = 0xEF  # Relative offset: -17 bytes (branches to $0BB0 if carry clear)
  result[0x1BD] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x1BE] = 0x60  # RTS (Return from Subroutine)
  
  # 0x0B8D-0x0B9C: Register setup and bit operations
  result[0x1BF] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x1C0] = 0x31  # Immediate value: clear C, Z, N, M flags
  result[0x1C1] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x1C2] = 0x48  # PHA (Push Accumulator to stack)
  result[0x1C3] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0x1C4] = 0x69  # ADC #$FFE4 (Add with Carry, immediate mode)
  result[0x1C5] = 0xE4  # Low byte: 0xE4
  result[0x1C6] = 0xFF  # High byte: 0xFF (value is 0xFFE4, which is -28 in two's complement)
  # TODO: Understand why -28 is added to direct page register
  result[0x1C7] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  result[0x1C8] = 0x68  # PLA (Pull Accumulator from stack)
  result[0x1C9] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x1CA] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x1CB] = 0x85  # STA $04 (Store Accumulator, direct page addressing)
  result[0x1CC] = 0x04  # Direct page address $04
  result[0x1CD] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0x1CE] = 0x29  # AND #$8000 (Logical AND, immediate mode)
  result[0x1CF] = 0x00  # Low byte: 0x00
  result[0x1D0] = 0x80  # High byte: 0x80 (masks to sign bit)
  result[0x1D1] = 0xF0  # BEQ $0BEA (Branch if Equal to zero, relative addressing)
  result[0x1D2] = 0x0B  # Relative offset: +11 bytes (branches to $0BEA if zero)
  
  # 0x0B9D-0x0BAC: Conditional value assignment
  result[0x1D3] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0x1D4] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x1D5] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x1D6] = 0x09  # ORA #$E000 (Logical OR, immediate mode)
  result[0x1D7] = 0x00  # Low byte: 0x00
  result[0x1D8] = 0xE0  # High byte: 0xE0 (value is 0xE000)
  result[0x1D9] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0x1DA] = 0x84  # STY $1A (Store Y register, direct page addressing)
  result[0x1DB] = 0x1A  # Direct page address $1A
  # TODO: Determine what memory location $1A represents
  result[0x1DC] = 0x80  # BRA $0BF0 (Branch Always, relative addressing)
  result[0x1DD] = 0x06  # Relative offset: +6 bytes (jumps to $0BF0)
  result[0x1DE] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0x1DF] = 0x4A  # LSR A (Logical Shift Right Accumulator)
  result[0x1E0] = 0x4A  # LSR A (Logical Shift Right Accumulator again)
  result[0x1E1] = 0xA8  # TAY (Transfer Accumulator to Y register)
  result[0x1E2] = 0x84  # STY $1A (Store Y register, direct page addressing)
  result[0x1E3] = 0x1A  # Direct page address $1A
  result[0x1E4] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0x1E5] = 0x04  # Direct page address $04
  result[0x1E6] = 0x29  # AND #$000F (Logical AND, immediate mode)
  result[0x1E7] = 0x0F  # Low byte: 0x0F
  result[0x1E8] = 0x00  # High byte: 0x00 (masks to low 4 bits)
  result[0x1E9] = 0x85  # STA $18 (Store Accumulator, direct page addressing)
  result[0x1EA] = 0x18  # Direct page address $18
  result[0x1EB] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0x1EC] = 0xA5  # LDA $04 (Load Accumulator, direct page addressing)
  result[0x1ED] = 0x04  # Direct page address $04
  result[0x1EE] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x1EF] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x1F0] = 0x9D  # STA $43B0,X (Store Accumulator, absolute indexed X)
  result[0x1F1] = 0xB0  # Low byte of address
  result[0x1F2] = 0x43  # High byte of address (full address: $43B0)
  # TODO: Determine what memory location $43B0 represents
  
  # 0x0B9D-0x0BAC: Final operations
  result[0x1F3] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x1F4] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x1F5] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0x1F6] = 0x29  # AND #$000F (Logical AND, immediate mode)
  result[0x1F7] = 0x0F  # Low byte: 0x0F
  result[0x1F8] = 0x00  # High byte: 0x00 (masks to low 4 bits)
  result[0x1F9] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0x1FA] = 0x86  # STX $16 (Store X register, direct page addressing)
  result[0x1FB] = 0x16  # Direct page address $16
  result[0x1FC] = 0x98  # TYA (Transfer Y register to Accumulator)
  result[0x1FD] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x1FE] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x1FF] = 0x9D  # STA $43C0,X (Store Accumulator, absolute indexed X)
  # TODO: Determine what memory location $43C0 represents
  # Note: Early subroutine continues beyond 512 bytes if needed
  # TODO: Verify if subroutine extends beyond 512 bytes

