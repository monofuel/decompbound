## The snesAsm macro is sugar over assemble(): every grammar form must lower to
## the exact same bytes as the raw AsmNode API. That equivalence is the macro's
## whole correctness contract (docs/goal-1.5.md) — assert it per form.

import
  std/unittest,
  ../src/decompbound/[snes_asm, assembler, opcodes]

const Org = 0xC00000'u32

suite "snesAsm lowers to the raw assembler":
  test "each addressing form matches instr()/assemble() byte-for-byte":
    let viaMacro = snesAsm(Org, NativeFlags16):
      sep 0x20            # immediate-8 (SEP is always imm8)
      lda 0x30            # immediate-M, now 8-bit after the SEP
      sta long 0x307FF0   # absolute-long
      inc a               # accumulator
      beq "done"          # relative branch to a label
      ldx 0x1234          # immediate-X, still 16-bit (SEP #$20 left X wide)
      andOp 0x10          # AND aliased around the Nim keyword
      flagHint true, false
      label "done"        # label definition
      rtl                 # implied

    let viaRaw = assemble(@[
      instr("SEP", amImmediate8, 0x20),
      instr("LDA", amImmediateM, 0x30),
      instr("STA", amAbsoluteLong, 0x307FF0),
      instr("INC", amAccumulator),
      instrTo("BEQ", amRelative8, "done"),
      instr("LDX", amImmediateX, 0x1234),
      instr("AND", amImmediateM, 0x10),
      flagHint(m8 = true, x8 = false),
      label("done"),
      instr("RTL", amImplied),
    ], Org, NativeFlags16)

    check viaMacro == viaRaw
    check viaMacro.len > 0

  test "immediate width follows the entry flag state (16-bit)":
    # With M clear on entry, LDA # takes a 2-byte operand.
    let m = snesAsm(Org, NativeFlags16):
      lda 0x1234
    let r = assemble(@[instr("LDA", amImmediateM, 0x1234)], Org, NativeFlags16)
    check m == r
    check m.len == 3   # opcode + 2 operand bytes

  test "indirect / stack-relative / indexed markers match raw modes":
    let m = snesAsm(Org, NativeFlags16):
      lda dpily 0x0E      # [$0E],Y
      sta absx 0x0000     # $0000,X
      lda sr 0x01         # $01,S
      lda dpind 0x20      # ($20)
      jmp absind 0x1234   # ($1234)
    let r = assemble(@[
      instr("LDA", amDpIndirectLongY, 0x0E),
      instr("STA", amAbsoluteX, 0x0000),
      instr("LDA", amStackRelative, 0x01),
      instr("LDA", amDpIndirect, 0x20),
      instr("JMP", amAbsIndirect, 0x1234),
    ], Org, NativeFlags16)
    check m == r

  test "implied and accumulator forms":
    let m = snesAsm(Org, NativeFlags16):
      pla
      asl a
      nop
    let r = assemble(@[
      instr("PLA", amImplied),
      instr("ASL", amAccumulator),
      instr("NOP", amImplied),
    ], Org, NativeFlags16)
    check m == r
