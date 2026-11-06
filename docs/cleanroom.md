# Clean room

sosumi is the clean side of a clean-room implementation. The decoders here are written from
public standards and from interface facts handed over in `specs/`, never from the firmware
image's own codec programs or from another decoder's source.

## Allowed sources

- The format standards: ISO/IEC 14496-3 and 13818-7 (AAC), 11172-3 and 13818-3 (MP3), ATSC A/52
  (AC-3), and Apple's ALAC package (Apache 2.0) for ALAC.
- `specs/` in this repository.
- x17's ISA, assembler and emulator, except `src/isa.toml`'s `[tables.*]` sections, which name
  the image's internal table layout.
- Books, papers, vendor DSP application notes, patents, and the ISO conformance bitstreams.
- Permissively licensed decoders, readable and copyable: the OpenCORE AAC decoder (Apache 2.0),
  minimp3 (CC0), dr_mp3 (public domain / MIT-0). Copied code keeps its licence header and gets a
  `NOTICE` entry.
- Copyleft and restricted decoders as **binaries only**: run `ffmpeg` for reference PCM, never read
  its source, nor FAAD2's, libmad's, liba52's, Rockbox's codecs, Helix's or FDK-AAC's. sosumi is
  Apache 2.0, and their licences are not compatible with that.

## Forbidden

- ipod-re: the RetailOS reverse, the image, the sm1 program dumps, and the notes and transcripts
  of the work done there;
- firmware images and codec program dumps;
- FFmpeg, FAAD, FDK-AAC, libmad, liba52, Helix and Rockbox codec source.

If a fact is missing, write the question into `specs/questions.md`; the dirty side answers with an
interface fact or a verdict, never with code or algorithm detail.

## What may cross the wall

From the dirty side, only:

- **interface facts**: ISA semantics, the memory map, the host's input and output contracts,
  configure order, the parameters the host passes;
- **verdicts**: a fixture passes or fails against the device, and which stage diverges first.

Never: table formats, fixed-point widths, stage order, constants or code taken from the image's
program.

## Provenance

Every non-trivial piece of code names its source in its commit message: an ISO clause, a `specs/`
section, or an x17 ISA entry.
