# Atari Zig Project

## Scope

The scope of this project is to setup a Zig build toolchain for Atari ST, which includes
- LLVM 21 with m68k support
- Zig 0.16 compiler using the above build of LLVM
- Some simple zig programs that compile to Atari ST .PRG format
- A zig native library that wraps GEM & VDI functions in idiomatic Zig wrappers

## Getting started

Get some basics installed first - will save much heartache down the track !

```
brew install m68k-elf-binutils
brew install frno7/toslibc/toslink
brew install hatari
```

## Why

Reasons for doing this :
- Get more familiar with building the Zig compiler itself
- Get familiar with using embedded asm in Zig
- Because the Atari ST is the future of computers

## Inspirations

This Youtube playlist that covers low level programming on the Atari ST

https://www.youtube.com/watch?v=mXTR_bBorsk&list=PLp_QNRIYljFrtuifgkvLpb88vvKQf2xUD


This project that demonstrates Rust / Zig / Swift toolchains  to build for the Atari

https://github.com/DominoTree/modern-m68k-toolchains

## What

Sub projects under this project:

### zig-m68k/

This directory contains a single shell script that when run will
- git clone LLVM and checkout the v21 branch
- git clone Zig sources from codeberg, and checkout the 0.16.0 branch
- build llvm-21 with m68k backend turned on
- build zig 0.16 with the modified llvm-21 backend
- install everything to ~/Atari/bin (and ~/Atari/lib, libexec, etc etc)

You should be able to 1 shot this script and end up with a complete m68k zig toolchain.

Its running in -j2 to restrict the amount of memory that the build needs ... so you can run this on a 16GB mac.

Whole build process takes a while - expect it to take around an hour ?

End result is that you will have a whole build toolchain setup in ~/Atari/bin, including Zig, LLVM, and the 'prgify' binary that is 
used to convert m68k ELF format compiler output to Atari ST .PRG format files.

This is basically just a header prepended to the ELF binary, with information about the correct address offset for the _start() function.

### hello/

This directory contains a minimal hello world app that uses the ~/Atari/bin/zig compiler to (hopefully) give you a ready-to-run HELLO.PRG file that you can drop onto your Atari ST and run !

if you have a look at 
- src/main.zig ... you will see its mostly setting up AES data, and doing some ASM to make calls into the Atari
- build.zig ... you will see it has a prg_step that adds the little headers to the output to make it a proper PRG file 
