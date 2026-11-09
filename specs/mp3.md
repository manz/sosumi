# MP3 decoder

Status: working draft. The reader side is known as host interface facts. The reference model (`ref/mp3/`) decodes MPEG-1, 2 and 2.5 Layer III; its numeric half has an sm1-shaped twin (`ref/dsp/mp3/`); the sm1 program is not started.

## Goal and boundary

Decode MPEG audio Layer III frames into PCM on sm1, from whole frames handed over by the host's
reader. MP3 is lossy: correctness means conformance to the MPEG decoding rules, plus matching
the device's output wherever that is measured.

The boundary is fixed by the device, not chosen:

- The reader cuts the file into frames. It skips the ID3v2 tag, finds the sync word, parses
  the header and passes **one whole frame per packet**, padding byte included (**MEASURED**:
  417 and 418 bytes for a 128 kbps / 44.1 kHz stream, through the same feeder AAC goes
  through).
- The decoder therefore owns everything from side information onward, including the bit
  reservoir (`main_data_begin`). The ARM reader never touches main data (**INFERRED**; nothing
  in the reader reads past the header).

## Evidence labels

- **MPEG**: ISO/IEC 11172-3 or 13818-3.
- **FIRMWARE**: host behaviour, handed over as an interface fact.
- **MEASURED**: observed in a trace, an emulator run or on the device.
- **FFMPEG**: PCM from the `ffmpeg` binary; a reference output, never proof of device behaviour. Its source is not read.
- **INFERRED**: the best explanation of the above.
- **OPEN**: not established.

## What the device accepts

The host's header parse and frame-length rule (**FIRMWARE**):

| Property | Device rule | Evidence |
|---|---|---|
| Layer | III only; any other layer is rejected | FIRMWARE |
| Version | MPEG-1, MPEG-2 and MPEG-2.5 all parse (version field 3, 2, 0) | FIRMWARE |
| Sample rate | {44100, 48000, 32000}, halved for MPEG-2, quartered for 2.5 | FIRMWARE |
| Channels | mode 3 (single channel) gives 1, every other mode gives 2 | FIRMWARE |
| Samples per frame | 1152 (MPEG-1), 576 (MPEG-2/2.5) | FIRMWARE |
| Free format (bitrate index 0) | played as 128 kbps, not refused | FIRMWARE |
| Bitrate index 15 | rejected | FIRMWARE |
| Sync | the 11-bit sync alone: `(halfword >> 4) >= 0xFFE` | FIRMWARE |
| Sync search | one 0x1000-byte block, gives up at offset 0xFFF | FIRMWARE |
| Output | 16-bit PCM declared by the reader | FIRMWARE |
| CRC-protected frames | whether sm1 checks or skips the CRC | OPEN |
| Seek | Xing TOC, else VBRI, else bytes × ms / duration, then resync | FIRMWARE |

The decoder must handle MPEG-1, MPEG-2 and MPEG-2.5 Layer III: the device admits all three, so
a file in any of them reaches sm1.

## The sm1 side

- Codec mode 1 is MP3 (**MEASURED**: playing the MP3 podcast selects mode 1 and no
  other). The mode byte is ctx+0x58.
- The output ring contract is AAC's (`specs/aac.md`, the same host output path,
  **FIRMWARE**). MP3's init pass writes the header Y:0..4 = 0, 2, 0x900, 0, 0x10: two slots of
  0x900 words, 1152 stereo frames (**MEASURED**, fact 788). The length word of a slot: **OPEN**.
- The host contract is AAC's (**MEASURED**, every packet of one track): the same handshake and
  arm, +0x98C on every packet including the first, no +0x420 block; only the per-mode patch
  words at +0x940, +0x960 and +0x964 differ, written by the driver from its table. No
  parameters beyond FD80 |= 1.
- Input: each descriptor carries exactly one whole MPEG frame, its 4-byte header included
  (all 1470 packets of a 192 kbps track start on sync, 626 or 627 bytes with padding). The
  program reads the header itself from the stream (`specs/aac.md` input contract).
- The bit reservoir is the program's: main_data_begin reaches back into earlier frames'
  bytes, which the stream has already delivered, so the program keeps them in its own
  buffer (**INFERRED** from the input contract).
- Entry point, reservoir storage and synthesis history are ours to lay out.

## Decoding stages

ISO/IEC 11172-3 is normative; the `ffmpeg` binary's PCM is the first reference output.

1. Side information (layout differs for MPEG-1 and MPEG-2/2.5; CRC skip if present).
2. Bit reservoir: assemble main data from `main_data_begin`; define the reset on start, seek and
   a corrupt frame.
3. Scale factors and Huffman decoding of spectral values (escapes, sign bits, count1 region).
4. Requantisation; mid/side and intensity stereo when signalled.
5. Short-block reordering and alias reduction.
6. IMDCT, windowing and overlap-add with the saved subband state (block switching, mixed blocks).
7. Polyphase synthesis into PCM, filter-bank state kept across frames.

Stages may be fused or reordered on sm1 as MPEG allows, provided the output is unchanged.

## Corpus

The measured corpus is one MP3 podcast: MPEG-1 Layer III, 128 kbps, 44.1 kHz, with an ID3v2
tag of 0x1A0 bytes. Fixtures for MPEG-2, MPEG-2.5, free format, mono, intensity stereo and CRC
frames have to be made; all of them can reach the decoder, per the table above.

## Validation

1. Reference PCM per fixture from at least two independent decoders (FFmpeg plus one
   standards-oriented decoder), versions recorded.
2. Device output where it can be captured: on QEMU (DAC capture) and on silicon.
3. Compare per frame, then over stateful sequences: start, steady state, seek, corrupt frame,
   end of stream. Investigate any persistent mismatch rather than widening the tolerance.

## Reference model state

`ref/mp3/` against the `ffmpeg` binary and `afconvert` (Apple's decoder), `tools/compare`:

| Input | Result |
|---|---|
| LAME fixtures: MPEG-1 CBR and VBR, mono, MPEG-2 22.05 / 24 kHz, MPEG-2.5 11.025 / 8 kHz | max diff 1 LSB against both |
| 7 library files, 60 s each (44.1 and 48 kHz, 128 to 320 kbps) | max diff 1 LSB against both |

Exercised: long and short blocks, M/S, scfsi, preflag, scalefac_scale, the bit reservoir.
Not exercised by any file at hand (LAME writes none of them): intensity stereo (MPEG-1 and
MPEG-2), mixed blocks, MPEG-2 preflag, CRC-protected frames, free format. ISO/IEC 11172-4
compliance streams would cover them (OPEN). minimp3's mixed-block band row at MPEG-2.5 8 kHz
covers 48 coefficients in its long part where the subband count says 72 (OPEN).

## The sm1-shaped twin

`ref/dsp/mp3/` redoes the numeric half (requantisation onward) in measured sm1 operations on
`ref/mp3`'s parse: Q21 words, every sum of products one x03.tap sum (exact to 48 bits) rounded
once, the IMDCT and synthesis matrices folded to their distinct rows (324 taps per long
subband, 32 rows of V per slot), the synthesis window exact in Q17. Against `tools/compare`:

| Reference | Result over the ten LAME fixtures |
|---|---|
| afconvert (Apple) | max diff 1 LSB on all |
| ffmpeg binary | max diff 1 LSB, except sweep.m2 (2 LSB in 0.017% of samples) |

Words wrap at 24 bits as sm1's do; only requantisation saturates. A stream louder than 4 at a
filterbank stage would wrap (OPEN: whether the program saturates there instead).

## Host facts

- The QEMU model's output buffer is one decoded frame (1152 samples for MP3) (**MEASURED**).
- The host's reader test walks 400 frames of the real podcast (**MEASURED**).

## References

- [ISO/IEC 11172-3](https://www.iso.org/standard/22412.html): MPEG-1 Audio.
- [ISO/IEC 13818-3](https://www.iso.org/standard/26797.html): MPEG-2 Audio, low sampling frequencies.
