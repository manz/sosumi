# sosumi

Audio decoders for the iPod Classic 6G's sm1 DSP, written in x17 assembly and loaded by chikuma.

The firmware image carries its own sm1 codec programs. They are an oracle for behaviour, not
source: their provenance is unknown, and nothing here is transcribed from them. Each decoder is
written from its format's public reference and checked against what the device measurably does.

    ref/         the reference model in Zig, at sm1's widths (zig build test)
    docs/        reading list
    third_party/ vendored Apache 2.0 sources the tables are derived from
    tools/       table generators
    specs/       one spec per codec: target scope, what the device is known to do, what is open
      aac.md     the priority: the library is all AAC
      mp3.md
      alac.md
      ac3.md

Related repositories:

    x17       the sm1 assembler and emulator, with the silicon-gated ISA
    ipod-re   the reverse engineering: RetailOS, the codec path, sm1 measurements (reports/)

Addresses in the specs are ipod-re's Ghidra project addresses unless marked `rt` (runtime).

Licensed under Apache 2.0 (`LICENSE`). sosumi is a clean-room implementation; `docs/cleanroom.md` sets
out which sources it may use.
