# sosumi

Audio decoders for the iPod Classic 6G's sm1 DSP, written in x17 assembly and loaded by
the host firmware.

The firmware image carries its own sm1 codec programs. They are an oracle for behaviour, not
source: their provenance is unknown, and nothing here is transcribed from them. Each decoder is
written from its format's public reference and checked against what the device measurably does.

    ref/         the reference model in Zig, at sm1's widths (zig build test)
    docs/        reading list
    third_party/ vendored permissive sources (Apache 2.0, CC0, public domain), see NOTICE
    tools/       table generators; compare/ checks the AAC and MP3 models against ffmpeg and
                 afconvert PCM (tools/compare/gen.sh, then zig build && zig-out/bin/compare
                 in.aac|in.mp3 ref.s16); alacdec/ decodes an .m4a to raw PCM for a byte-exact
                 cmp (tools/alacdec/gen.sh)
    specs/       one spec per codec: target scope, what the device is known to do, what is open
      aac.md     the priority: the library is all AAC
      mp3.md
      alac.md
      ac3.md
      dsp.md     the plan for porting the models to sm1

Related repositories:

    x17       the sm1 assembler and emulator, with the silicon-gated ISA

Addresses in the specs are sm1 X/Y word addresses.

Licensed under Apache 2.0 (`LICENSE`). sosumi is a clean-room implementation; `docs/cleanroom.md` sets
out which sources it may use.
