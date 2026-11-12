# sosumi

Audio decoders for the iPod Classic 6G's sm1 DSP, written in x17 assembly and loaded by
the host firmware.

The firmware image carries its own sm1 codec programs. They are an oracle for behaviour, not
source: their provenance is unknown, and nothing here is transcribed from them. Each decoder is
written from its format's public reference and checked against what the device measurably does.

## Status

AAC-LC, MP3 (MPEG-1/2/2.5 Layer III) and ALAC decode on sm1 and play on the device in real time.
Each sm1 program is bit-exact against its Zig twin in `ref/dsp`, and the twins stay within one or
two LSB of ffmpeg and afconvert on the test fixtures.

| codec | sm1 mode | real-time budget at 48 kHz          |
|-------|----------|-------------------------------------|
| AAC   | 0        | ~621K bundles per 1024-sample frame |
| MP3   | 1        | ~642K bundles per 1152-sample frame |
| ALAC  | 3        | ~2.28M bundles per 4096-sample packet |

`dspplay --profile=N` prints a stream's worst case against these.

## Layout

    ref/         the reference models in Zig: ref/{aac,mp3,alac} at sm1's widths, and
                 ref/dsp the twins the sm1 programs match word for word
    dsp/         the sm1 programs: dsp/lib/*.sm (x17 assembly), the host-model players and
                 their tests, the image sources
    docs/        reading list, clean-room rules, x17 import notes
    third_party/ vendored permissive sources (Apache 2.0, CC0, public domain), see NOTICE
    tools/       sm1image builds the .x17i images; dspplay runs a stream through the sm1
                 program in x17's emulator (--check, --profile=N); compare/ checks the models
                 against ffmpeg and afconvert PCM (tools/compare/gen.sh, then
                 zig-out/bin/compare in.aac|in.mp3 ref.s16); alacdec/ decodes an .m4a to raw
                 PCM for a byte-exact cmp (tools/alacdec/gen.sh); provenance/ checks tracked
                 files against the clean-room rules
    specs/       one spec per codec: target scope, what the device is known to do, what is open
      aac.md
      mp3.md
      alac.md
      ac3.md     not started
      dsp.md     the port to sm1

## Build

    zig build test    reference models, twins, and the sm1 programs in x17's emulator
    zig build sm1     zig-out/sm1/{aac,mp3,alac}.x17i, each with a .json source map

Test fixtures live in `testdata/` (generated, not tracked; see `tools/compare/gen.sh` and
`tools/alacdec/gen.sh`).

Related repositories:

    x17       the sm1 assembler and emulator, with the silicon-gated ISA (pinned in build.zig.zon)

Addresses in the specs are sm1 X/Y word addresses.

Licensed under Apache 2.0 (`LICENSE`). sosumi is a clean-room implementation; `docs/cleanroom.md` sets
out which sources it may use.
