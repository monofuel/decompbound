## Initialization code generation for Earthbound.

import
  ./common

proc generateInitCode*(): seq[uint8] =
  ## Generate the initialization code starting at 0x010000.
  ## This is the reset handler entry point that sets up the SNES.
  ## TODO: Reverse engineer this entire initialization sequence into proper Nim functions.
  result = newSeq[uint8](InitCodeSize)
  
  # 0x010000-0x010003: Initial subroutine call
  result[0x00] = 0x20  # JSR $0A1D (Jump to Subroutine, absolute) - calls initialization routine
  result[0x01] = 0x1D  # Low byte of subroutine address
  result[0x02] = 0x0A  # High byte of subroutine address
  # TODO: Reverse engineer what the subroutine at $0A1D does
  result[0x03] = 0x6B  # RTS (Return from Subroutine)
  # TODO: Determine if this RTS is actually reached or if it's dead code
  
  # 0x010004-0x01000B: Direct page setup
  result[0x04] = 0xC2  # REP #$31 (Reset Processor status bits - clear carry, zero, negative flags)
  result[0x05] = 0x31  # Immediate value: clear C, Z, N flags
  # TODO: Understand why these specific flags are cleared
  result[0x06] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x07] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0x08] = 0x69  # ADC #$FFEE (Add with Carry, immediate mode)
  result[0x09] = 0xEE  # Low byte: 0xEE
  result[0x0A] = 0xFF  # High byte: 0xFF (value is 0xFFEE)
  # TODO: Reverse engineer why 0xFFEE is added to direct page register
  result[0x0B] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  # TODO: Understand the purpose of this direct page manipulation
  
  # 0x01000C-0x010013: Load and store from direct page
  result[0x0C] = 0xA5  # LDA $20 (Load Accumulator, direct page addressing)
  result[0x0D] = 0x20  # Direct page address $20
  # TODO: Determine what memory location $20 represents
  result[0x0E] = 0x85  # STA $06 (Store Accumulator, direct page addressing)
  result[0x0F] = 0x06  # Direct page address $06
  # TODO: Determine what memory location $06 represents
  result[0x10] = 0xA5  # LDA $22 (Load Accumulator, direct page addressing)
  result[0x11] = 0x22  # Direct page address $22
  # TODO: Determine what memory location $22 represents
  result[0x12] = 0x85  # STA $08 (Store Accumulator, direct page addressing)
  result[0x13] = 0x08  # Direct page address $08
  # TODO: Determine what memory location $08 represents
  
  # 0x010014-0x01001F: Long subroutine call and register preservation
  result[0x14] = 0x22  # JSL $C0943C (Jump to Subroutine Long, absolute long addressing)
  result[0x15] = 0x3C  # Low byte of address
  result[0x16] = 0x94  # Mid byte of address
  result[0x17] = 0xC0  # High byte of address (full address: $C0943C)
  # TODO: Reverse engineer what the subroutine at $C0943C does
  result[0x18] = 0xA5  # LDA $06 (Load Accumulator from preserved value)
  result[0x19] = 0x06  # Direct page address $06
  result[0x1A] = 0x85  # STA $0E (Store Accumulator)
  result[0x1B] = 0x0E  # Direct page address $0E
  # TODO: Understand why values are copied to $0E and $10
  result[0x1C] = 0xA5  # LDA $08 (Load Accumulator from preserved value)
  result[0x1D] = 0x08  # Direct page address $08
  result[0x1E] = 0x85  # STA $10 (Store Accumulator)
  result[0x1F] = 0x10  # Direct page address $10
  
  # 0x010020-0x010027: Additional long subroutine calls
  result[0x20] = 0x22  # JSL $C186B1 (Jump to Subroutine Long)
  result[0x21] = 0xB1  # Low byte
  result[0x22] = 0x86  # Mid byte
  result[0x23] = 0xC1  # High byte (full address: $C186B1)
  # TODO: Reverse engineer what the subroutine at $C186B1 does
  result[0x24] = 0x22  # JSL $C12DD5 (Jump to Subroutine Long)
  result[0x25] = 0xD5  # Low byte
  result[0x26] = 0x2D  # Mid byte
  result[0x27] = 0xC1  # High byte (full address: $C12DD5)
  # TODO: Reverse engineer what the subroutine at $C12DD5 does
  
  # 0x010028-0x01002F: Loop checking memory location
  result[0x28] = 0xAD  # LDA $B4A8 (Load Accumulator, absolute addressing)
  result[0x29] = 0xA8  # Low byte of address
  result[0x2A] = 0xB4  # High byte of address (full address: $B4A8)
  # TODO: Determine what memory location $B4A8 represents
  result[0x2B] = 0xC9  # CMP #$FFFF (Compare Accumulator, immediate mode)
  result[0x2C] = 0xFF  # Low byte: 0xFF
  result[0x2D] = 0xFF  # High byte: 0xFF (value is 0xFFFF)
  result[0x2E] = 0xD0  # BNE $010024 (Branch if Not Equal, relative addressing)
  result[0x2F] = 0xF4  # Relative offset: -12 bytes (branches back to $010024)
  # TODO: Reverse engineer the purpose of this polling loop
  
  # 0x010030-0x010035: Final subroutine call and cleanup
  result[0x30] = 0x22  # JSL $C09451 (Jump to Subroutine Long)
  result[0x31] = 0x51  # Low byte
  result[0x32] = 0x94  # Mid byte
  result[0x33] = 0xC0  # High byte (full address: $C09451)
  # TODO: Reverse engineer what the subroutine at $C09451 does
  result[0x34] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x35] = 0x6B  # RTS (Return from Subroutine)
  # TODO: Understand the complete initialization flow
  
  # 0x010036-0x01003B: Function that stores to $964D
  result[0x36] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x37] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x38] = 0x8D  # STA $964D (Store Accumulator, absolute addressing)
  result[0x39] = 0x4D  # Low byte of address
  result[0x3A] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents
  result[0x3B] = 0x60  # RTS (Return from Subroutine)
  
  # 0x01003C-0x010041: Function that clears $964D
  result[0x3C] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x3D] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x3E] = 0x9C  # STZ $964D (Store Zero, absolute addressing - clears memory)
  result[0x3F] = 0x4D  # Low byte of address
  result[0x40] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents and why it's cleared
  result[0x41] = 0x60  # RTS (Return from Subroutine)
  
  # 0x010042-0x010047: Function that reads from $964D
  result[0x42] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x43] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x44] = 0xAD  # LDA $964D (Load Accumulator, absolute addressing)
  result[0x45] = 0x4D  # Low byte of address
  result[0x46] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents
  result[0x47] = 0x60  # RTS (Return from Subroutine)
  
  # 0x010048-0x01004D: Function that stores to $964F
  result[0x48] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x49] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x4A] = 0x8D  # STA $964F (Store Accumulator, absolute addressing)
  result[0x4B] = 0x4F  # Low byte of address
  result[0x4C] = 0x96  # High byte of address (full address: $964F)
  # TODO: Determine what memory location $964F represents
  result[0x4D] = 0x60  # RTS (Return from Subroutine)
  
  # 0x01004E-0x01005B: Conditional subroutine call based on $89C9
  result[0x4E] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x4F] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x50] = 0xAD  # LDA $89C9 (Load Accumulator, absolute addressing)
  result[0x51] = 0xC9  # Low byte of address
  result[0x52] = 0x89  # High byte of address (full address: $89C9)
  # TODO: Determine what memory location $89C9 represents
  result[0x53] = 0x29  # AND #$00FF (Logical AND, immediate mode - mask to low byte)
  result[0x54] = 0xFF  # Low byte: 0xFF
  result[0x55] = 0x00  # High byte: 0x00 (value is 0x00FF, masks to 8-bit)
  result[0x56] = 0xF0  # BEQ $01005C (Branch if Equal to zero, relative addressing)
  result[0x57] = 0x04  # Relative offset: +4 bytes (skips next instruction if zero)
  result[0x58] = 0x22  # JSL $C3E450 (Jump to Subroutine Long)
  result[0x59] = 0x50  # Low byte
  result[0x5A] = 0xE4  # Mid byte
  result[0x5B] = 0xC3  # High byte (full address: $C3E450)
  # TODO: Reverse engineer what the subroutine at $C3E450 does and when it's called
  
  # 0x01005C-0x010067: Conditional subroutine call based on $9643
  result[0x5C] = 0xAD  # LDA $9643 (Load Accumulator, absolute addressing)
  result[0x5D] = 0x43  # Low byte of address
  result[0x5E] = 0x96  # High byte of address (full address: $9643)
  # TODO: Determine what memory location $9643 represents
  result[0x5F] = 0xF0  # BEQ $010067 (Branch if Equal to zero, relative addressing)
  result[0x60] = 0x06  # Relative offset: +6 bytes (skips next instruction if zero)
  result[0x61] = 0x22  # JSL $C43568 (Jump to Subroutine Long)
  result[0x62] = 0x68  # Low byte
  result[0x63] = 0x35  # Mid byte
  result[0x64] = 0xC4  # High byte (full address: $C43568)
  # TODO: Reverse engineer what the subroutine at $C43568 does
  result[0x65] = 0x80  # BRA $010077 (Branch Always, relative addressing)
  result[0x66] = 0x10  # Relative offset: +16 bytes (jumps to $010077)
  
  # 0x010067-0x010077: Multiple subroutine calls
  result[0x67] = 0x22  # JSL $C088B1 (Jump to Subroutine Long)
  result[0x68] = 0xB1  # Low byte
  result[0x69] = 0x88  # Mid byte
  result[0x6A] = 0xC0  # High byte (full address: $C088B1)
  # TODO: Reverse engineer what the subroutine at $C088B1 does
  result[0x6B] = 0x22  # JSL $C09466 (Jump to Subroutine Long)
  result[0x6C] = 0x66  # Low byte
  result[0x6D] = 0x94  # Mid byte
  result[0x6E] = 0xC0  # High byte (full address: $C09466)
  # TODO: Reverse engineer what the subroutine at $C09466 does
  result[0x6F] = 0x22  # JSL $C08B26 (Jump to Subroutine Long)
  result[0x70] = 0x26  # Low byte
  result[0x71] = 0x8B  # Mid byte
  result[0x72] = 0xC0  # High byte (full address: $C08B26)
  # TODO: Reverse engineer what the subroutine at $C08B26 does
  result[0x73] = 0x22  # JSL $C08756 (Jump to Subroutine Long)
  result[0x74] = 0x56  # Low byte
  result[0x75] = 0x87  # Mid byte
  result[0x76] = 0xC0  # High byte (full address: $C08756)
  # TODO: Reverse engineer what the subroutine at $C08756 does
  result[0x77] = 0x6B  # RTS (Return from Subroutine)
  
  # 0x010078-0x01007F: Final function reading from $8958
  result[0x78] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x79] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x7A] = 0xAD  # LDA $8958 (Load Accumulator, absolute addressing)
  result[0x7B] = 0x58  # Low byte of address
  result[0x7C] = 0x89  # High byte of address (full address: $8958)
  # TODO: Determine what memory location $8958 represents
  result[0x7D] = 0x60  # RTS (Return from Subroutine)
  result[0x7E] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x7F] = 0x31  # Immediate value: clear C, Z, N flags
  # TODO: This appears to be the start of another function - determine its purpose
  
  # 0x010080-0x0100FF: Continuation of initialization code
  result[0x80] = 0x8D  # STA $8958 (Store Accumulator, absolute addressing)
  result[0x81] = 0x58  # Low byte of address
  result[0x82] = 0x89  # High byte of address (full address: $8958)
  # TODO: Determine what memory location $8958 represents
  result[0x83] = 0x60  # RTS (Return from Subroutine)
  result[0x84] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x85] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x86] = 0xAD  # LDA $8958 (Load Accumulator, absolute addressing)
  result[0x87] = 0x58  # Low byte of address
  result[0x88] = 0x89  # High byte of address (full address: $8958)
  result[0x89] = 0x22  # JSL $C3E521 (Jump to Subroutine Long)
  result[0x8A] = 0x21  # Low byte
  result[0x8B] = 0xE5  # Mid byte
  result[0x8C] = 0xC3  # High byte (full address: $C3E521)
  # TODO: Reverse engineer what the subroutine at $C3E521 does
  result[0x8D] = 0x60  # RTS (Return from Subroutine)
  result[0x8E] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x8F] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x90] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x91] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x92] = 0xA9  # LDA #$01 (Load Accumulator, immediate mode)
  result[0x93] = 0x01  # Immediate value: 0x01
  result[0x94] = 0x8D  # STA $5E70 (Store Accumulator, absolute addressing)
  result[0x95] = 0x70  # Low byte of address
  result[0x96] = 0x5E  # High byte of address (full address: $5E70)
  # TODO: Determine what memory location $5E70 represents
  result[0x97] = 0x80  # BRA $0100AB (Branch Always, relative addressing)
  result[0x98] = 0x12  # Relative offset: +18 bytes (jumps to $0100AB)
  result[0x99] = 0xAD  # LDA $88E2 (Load Accumulator, absolute addressing)
  result[0x9A] = 0xE2  # Low byte of address
  result[0x9B] = 0x88  # High byte of address (full address: $88E2)
  # TODO: Determine what memory location $88E2 represents
  result[0x9C] = 0xA0  # LDY #$0052 (Load Y register, immediate mode)
  result[0x9D] = 0x52  # Low byte: 0x52
  result[0x9E] = 0x00  # High byte: 0x00 (value is 0x0052)
  result[0x9F] = 0x22  # JSL $C08FF7 (Jump to Subroutine Long)
  result[0xA0] = 0xF7  # Low byte
  result[0xA1] = 0x8F  # Mid byte
  result[0xA2] = 0xC0  # High byte (full address: $C08FF7)
  # TODO: Reverse engineer what the subroutine at $C08FF7 does
  result[0xA3] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0xA4] = 0xBD  # LDA $8654,X (Load Accumulator, absolute indexed X)
  result[0xA5] = 0x54  # Low byte of address
  result[0xA6] = 0x86  # High byte of address (full address: $8654)
  # TODO: Determine what memory location $8654 represents and the purpose of indexing
  result[0xA7] = 0x22  # JSL $C3E521 (Jump to Subroutine Long)
  result[0xA8] = 0x21  # Low byte
  result[0xA9] = 0xE5  # Mid byte
  result[0xAA] = 0xC3  # High byte (full address: $C3E521)
  result[0xAB] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0xAC] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0xAD] = 0xAD  # LDA $88E2 (Load Accumulator, absolute addressing)
  result[0xAE] = 0xE2  # Low byte of address
  result[0xAF] = 0x88  # High byte of address (full address: $88E2)
  result[0xB0] = 0xC9  # CMP #$FFFF (Compare Accumulator, immediate mode)
  result[0xB1] = 0xFF  # Low byte: 0xFF
  result[0xB2] = 0xFF  # High byte: 0xFF (value is 0xFFFF)
  result[0xB3] = 0xD0  # BNE $010099 (Branch if Not Equal, relative addressing)
  result[0xB4] = 0xE4  # Relative offset: -28 bytes (branches back to $010099)
  # TODO: Reverse engineer the purpose of this polling loop
  result[0xB5] = 0x22  # JSL $C3E4CA (Jump to Subroutine Long)
  result[0xB6] = 0xCA  # Low byte
  result[0xB7] = 0xE4  # Mid byte
  result[0xB8] = 0xC3  # High byte (full address: $C3E4CA)
  # TODO: Reverse engineer what the subroutine at $C3E4CA does
  result[0xB9] = 0x22  # JSL $C12DD5 (Jump to Subroutine Long)
  result[0xBA] = 0xD5  # Low byte
  result[0xBB] = 0x2D  # Mid byte
  result[0xBC] = 0xC1  # High byte (full address: $C12DD5)
  result[0xBD] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0xBE] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0xBF] = 0x9C  # STZ $5E70 (Store Zero, absolute addressing - clears memory)
  result[0xC0] = 0x70  # Low byte of address
  result[0xC1] = 0x5E  # High byte of address (full address: $5E70)
  result[0xC2] = 0x22  # JSL $C43F53 (Jump to Subroutine Long)
  result[0xC3] = 0x53  # Low byte
  result[0xC4] = 0x3F  # Mid byte
  result[0xC5] = 0xC4  # High byte (full address: $C43F53)
  # TODO: Reverse engineer what the subroutine at $C43F53 does
  result[0xC6] = 0x60  # RTS (Return from Subroutine)
  result[0xC7] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0xC8] = 0x31  # Immediate value: clear C, Z, N flags
  result[0xC9] = 0xA9  # LDA #$0001 (Load Accumulator, immediate mode)
  result[0xCA] = 0x01  # Low byte: 0x01
  result[0xCB] = 0x00  # High byte: 0x00 (value is 0x0001)
  result[0xCC] = 0x8D  # STA $9645 (Store Accumulator, absolute addressing)
  result[0xCD] = 0x45  # Low byte of address
  result[0xCE] = 0x96  # High byte of address (full address: $9645)
  # TODO: Determine what memory location $9645 represents
  result[0xCF] = 0x60  # RTS (Return from Subroutine)
  result[0xD0] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0xD1] = 0x31  # Immediate value: clear C, Z, N flags
  result[0xD2] = 0x9C  # STZ $9645 (Store Zero, absolute addressing - clears memory)
  result[0xD3] = 0x45  # Low byte of address
  result[0xD4] = 0x96  # High byte of address (full address: $9645)
  result[0xD5] = 0x60  # RTS (Return from Subroutine)
  result[0xD6] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0xD7] = 0x31  # Immediate value: clear C, Z, N flags
  result[0xD8] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0xD9] = 0x48  # PHA (Push Accumulator to stack)
  result[0xDA] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0xDB] = 0x69  # ADC #$FFF0 (Add with Carry, immediate mode)
  result[0xDC] = 0xF0  # Low byte: 0xF0
  result[0xDD] = 0xFF  # High byte: 0xFF (value is 0xFFF0)
  # TODO: Reverse engineer why 0xFFF0 is added to direct page register
  result[0xDE] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  result[0xDF] = 0x68  # PLA (Pull Accumulator from stack)
  result[0xE0] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0xE1] = 0x86  # STX $0E (Store X register, direct page addressing)
  result[0xE2] = 0x0E  # Direct page address $0E
  result[0xE3] = 0x22  # JSL $C3E4CA (Jump to Subroutine Long)
  result[0xE4] = 0xCA  # Low byte
  result[0xE5] = 0xE4  # Mid byte
  result[0xE6] = 0xC3  # High byte (full address: $C3E4CA)
  result[0xE7] = 0x22  # JSL $C12DD5 (Jump to Subroutine Long)
  result[0xE8] = 0xD5  # Low byte
  result[0xE9] = 0x2D  # Mid byte
  result[0xEA] = 0xC1  # High byte (full address: $C12DD5)
  result[0xEB] = 0x80  # BRA $0100F1 (Branch Always, relative addressing)
  result[0xEC] = 0x04  # Relative offset: +4 bytes (jumps to $0100F1)
  result[0xED] = 0x22  # JSL $C12E42 (Jump to Subroutine Long)
  result[0xEE] = 0x42  # Low byte
  result[0xEF] = 0x2E  # Mid byte
  result[0xF0] = 0xC1  # High byte (full address: $C12E42)
  # TODO: Reverse engineer what the subroutine at $C12E42 does
  result[0xF1] = 0xA6  # LDX $0E (Load X register, direct page addressing)
  result[0xF2] = 0x0E  # Direct page address $0E
  result[0xF3] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0xF4] = 0xCA  # DEX (Decrement X register)
  result[0xF5] = 0x86  # STX $0E (Store X register, direct page addressing)
  result[0xF6] = 0x0E  # Direct page address $0E
  result[0xF7] = 0xC9  # CMP #$0000 (Compare Accumulator, immediate mode)
  result[0xF8] = 0x00  # Low byte: 0x00
  result[0xF9] = 0x00  # High byte: 0x00 (value is 0x0000)
  result[0xFA] = 0xD0  # BNE $0100E3 (Branch if Not Equal, relative addressing)
  result[0xFB] = 0xF1  # Relative offset: -15 bytes (branches back to $0100E3)
  # TODO: Reverse engineer the purpose of this loop
  result[0xFC] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0xFD] = 0x60  # RTS (Return from Subroutine)
  result[0xFE] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0xFF] = 0x31  # Immediate value: clear C, Z, N flags
  # TODO: This appears to be the start of another function - determine its purpose

