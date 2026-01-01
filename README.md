# decompbound

Earthbound (SNES) decompilation project in Nim.

The goal of this project is to build a Nim program that can eventually reproduce the Earthbound English US ROM exactly.
This will be a very long and complex project. we just need to push the needle forward one byte at a time.

store the comparison rom at `./bin/Earthbound (U) [!].smc`
- sha256sum: `a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e  bin/Earthbound (U) [!].smc`

## testing

- `nim r src/decompbound.nim --compare`
  - this will generate a decomp rom at `./bin/Decompbound.smc` and compare it to the gold master rom.
- `nim r src/decompbound.nim` simply generates a decomp rom.


## bug fixes

- we can control compilation with compile time `consts` and flags.
- the default decompbound.nim should eventually get to reproducing the rom exactly.
- however we can add compiler flags for fixing bugs.

## Best Practices

- probably use bitmaps for all the graphics?
  - try to keep as close to source material as possible. eg: the entire world is a singular bitmap.
  - we should use pixie for graphics in Nim.

- as much code as possible should be written in nim.
  - we can use practices like `shady` as a reference for converting nim code into snes asm.
  - we want to be able to write tests for the nim version of code.

- we can use `shady` for custom shaders like the whacky battle backgrounds.

- we should avoid magic bytes as much as possible and instead figure out what they are representing properly.
  - but it's ok to hard code some magic bytes to get the ball rolling.
  - incremental process.

## Docs

- decompbound/docs/snes-asm.md
- decompbound/docs/graphics.md
- decompbound/docs/snes-asm.md

- extensive docs on rom format: https://en.wikibooks.org/wiki/Super_NES_Programming/SNES_memory_map
- extensive general docs on snes stuff https://wiki.superfamicom.org/
- https://www.sneslab.net/wiki/Official_Documentation_Quick_Links

- TODO get docs and stuff
- https://grok.com/c/e857e9c5-f9bd-413e-a6b9-7ce3a909749e?rid=8c2d60f9-672b-4b2e-993e-67433caaa066
