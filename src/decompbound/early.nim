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
  # TODO: Understand the final bit manipulation operations

