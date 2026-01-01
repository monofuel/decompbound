# decompbound

Earthbound (SNES) decompilation project in Nim.

The goal of this project is to build a Nim program that can eventually reproduce the Earthbound English US ROM exactly.


store the comparison rom at `./bin/Earthbound (U) [!].smc`
- sha256sum: `a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e  bin/Earthbound (U) [!].smc`


## bug fixes

- we can control compilation with compile time `consts` and flags.
- the default decompbound.nim should eventually get to reproducing the rom exactly.
- however we can add compiler flags for fixing bugs.
