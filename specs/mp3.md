# MP3 decoder

Status: working draft. The reader side is known as host interface facts. The reference model (`ref/mp3/`) decodes MPEG-1, 2 and 2.5 Layer III; its numeric half has an sm1-shaped twin (`ref/dsp/mp3/`); the sm1 program (`dsp/lib/mp3.sm`) runs from intake through the hybrid filterbank, exact against the twin.

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
| Seek target | turned into samples, rounded down to a frame boundary, sync re-found from there | FIRMWARE |
| Frame length | bitrate / 8 × samples per frame / rate + padding bit | FIRMWARE |
| CRC, private bit, emphasis | not checked by the reader | FIRMWARE |
| Xing / Info | in the first frame, 36 / 21 bytes past the header (MPEG-1 stereo / mono), 21 / 13 (MPEG-2): frame count, byte count, 100-entry TOC; the LAME tail and gapless fields are not read | FIRMWARE |
| VBRI | 36 bytes past the header; a table longer than 0x5A0 bytes is refused | FIRMWARE |
| Neither | duration from the first frame's bitrate over the bytes after it; seeks proportional by bytes | FIRMWARE |
| Container | chosen by file extension only (".mp3"); Audible ".aa" files whose codec word is 0xC00D also play in mode 1; MPEG audio inside MP4 not checked | FIRMWARE |

The decoder must handle MPEG-1, MPEG-2 and MPEG-2.5 Layer III: the device admits all three, so
a file in any of them reaches sm1. The Xing / Info / VBRI frame is an ordinary frame to the
reader (INFERRED: nothing says it is skipped), so it reaches sm1 too and must decode without
fault; LAME writes it with empty main data.

## The sm1 side

- Codec mode 1 is MP3 (**MEASURED**: playing the MP3 podcast selects mode 1 and no
  other). The mode byte is ctx+0x58.
- The output ring contract is AAC's (`specs/aac.md`, the same host output path,
  **FIRMWARE**). MP3's init pass writes the header Y:0..4 = 0, 2, 0x900, 0, 0x10: two slots of
  0x900 words, 1152 stereo frames (**MEASURED**, fact 788). Per packet the slots alternate 0, 1;
  the entry's length word is samples x the stream's channel count, mono not duplicated:
  MPEG-1 stereo 0x900, MPEG-1 mono 0x480, MPEG-2 stereo 0x480, MPEG-2 mono 0x240; FD94 = 1,
  FD95 = 0 after each packet (**MEASURED**, fact 797). With no slot released, the device's
  program stops with FD95 = 0x21 (ring full, waiting on the host) and leaves the packet queued.
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
- A seek sends the program nothing (**MEASURED**): the next frame is armed like any other, so
  the reservoir and filterbank state carry across the discontinuity, and a frame whose
  main_data_begin reaches before the seek must decode without fault.
- Entry point, reservoir storage and synthesis history are ours to lay out.
- Ring full: mp3_packet checks its slot's owned word before reading the frame. Still owned,
  it writes FD95 = 0x21 and stops (x17 handbook §11, fact 797), the frame left unread on the
  stream, so the next run reads it first. The device's own program waits in the bit-12 feed
  wait instead; how a program enters that wait, and whether the host resumes a program that
  stopped, are **OPEN**.
- The synthesis matrix (`mp3_mgrp`) rotates four x03.tap sums, {sHi:sLo} changing every
  bundle while sL and sB are shared: each named pair is its own exact 48-bit sum, no
  cross-talk (**MEASURED**, fact 798: c streamed, x[k] loaded into sB every 4 taps, 4 pairs,
  36 taps, exact in 3 of 3 runs).

### Mode 1's data budget

Fact 961 (**MEASURED**): mode 1 maps X 0..0x11FF (4608 words) and Y 0..0x187F plus the host
block 0xFD80..0xFDFF; 0x1780..0x187F holds DSP stores but no init-pass data. The image before
this budget (fede476a) touches X 6840 words and Y about 6.0K words outside the ring
(measured in x17 over the five corpus fixtures). The largest parts:

| memory | part | words |
|---|---|---|
| X | granule lines, 2 x 576 | 1152 |
| X | IMDCT overlap, 2 x 576 | 1152 |
| X | V history (now 2 x 544, from 2 x 1024) | 1088 |
| X | synthesis window, doubled for the ring's wrap | 1024 |
| X | IMDCT-36 rows, windows, IMDCT-12 rows | 504 |
| X | matrixing rows | 384 |
| X | requantisation tables, scratch, stereo, alias | ~570 |
| Y | Huffman trees (lib/huffman.sm format, smallest roots) | 2832 |
| Y | reservoir and main data, a byte per word | 1952 |
| Y | band width lists | 696 |
| Y | headers, side information, frame lengths, scale factors, slots | ~620 |

Beside a two-slot ring of 0x900 at Y:0x80, Y keeps 0x1280..0x187F and 0x09..0x7F, about 1.65K
words: the trees alone do not fit. A one-slot ring (Q33) keeps 0x980..0x187F, about 3.96K. Even
then the plan needs: main data in the free slot's second half, two bytes a word, until
granule 1's Huffman decode, with only the reservoir's last 511 bytes kept (256 words); the band
lists two to a word; frame lengths computed. X needs about 2.3K cut: the V history (done), a
fast IMDCT-36 and DCT-32 (ISO/IEC 11172-3 leaves the algorithm free), and one channel's lines
at a time. Q33 (VERDICT on the replacement host): a one-slot ring plays gapless, slot 0 at
Y:0x80, the program waiting on its owned flag; the stock host with one slot is unmeasured.
The mode-1 layout takes one slot.

The mode-1 image (`.mode 1`) now fits: X ends at 0x1125 (4390 words) with the IMDCTs run as 9-
and 3-point DCTs into 9 overlap words per subband (minimp3's structure, 576 words, its tables
100) and the synthesis window stored once (512 words), its offset wrapped modulo 512 by x02.aa
(facts 566-568, 626). Y keeps its init data below 0x1780. The image test checks both maps in
x17. Worst corpus frame 511,150 bundles (48 kHz budget 642K). VERDICT (silicon, 2026-11-12): the
mode-1 image (a1d6021) plays a 256 kbps 44.1 kHz stereo track clean over iAP; a bell-fed frame is
within 1 LSB of ffmpeg on all 2304 samples. Two silicon-only faults on the way: x19.ld after
x17.styi wedges (Q21; Y copies are ldy + x18.eagu), and x02.aa wraps only with fn 6..11 (fact
963; the window's wrap uses fn 8).

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
subband, 32 rows of V per slot, folded by N's symmetries to 384 products over butterflied
subband sums), the synthesis window exact in Q17, sample 32 - j reading V[j] by -D (one read for
both samples; differs from V[32 - j] by D only if V[j] = -2^23 wraps). The hybrid's windows are Q23 (1.0 held as
2^23 - 1), each product one x02 rounded multiply. Against `tools/compare`:

| Reference | Result over the eleven LAME fixtures |
|---|---|
| afconvert (Apple) | max diff 1 LSB on all |
| ffmpeg binary | max diff 1 LSB, except sweep.m2 (2 LSB in 0.017% of samples) and heavy.cbr (2 LSB, under 0.001%) |

Words wrap at 24 bits as sm1's do; only requantisation saturates. A stream louder than 4 at a
filterbank stage would wrap (OPEN: whether the program saturates there instead). x03.tap's 48-bit
sum saturates in x17's emulator and the twin follows it (`ops.mac`); on silicon OPEN. No
fixture comes near it.

## Host facts

- The QEMU model's output buffer is one decoded frame (1152 samples for MP3) (**MEASURED**).
- The host's reader test walks 400 frames of the real podcast (**MEASURED**).

## References

- [ISO/IEC 11172-3](https://www.iso.org/standard/22412.html): MPEG-1 Audio.
- [ISO/IEC 13818-3](https://www.iso.org/standard/26797.html): MPEG-2 Audio, low sampling frequencies.
