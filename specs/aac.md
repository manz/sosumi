# AAC decoder

Status: working draft. The host side is known as interface facts, and AAC plays on silicon
through the device's own sm1 program; no decoder of ours exists yet.

AAC is the priority codec: the library this targets is all AAC.

## Goal and boundary

Decode AAC-LC access units into 16-bit PCM on sm1, as a drop-in for the device's mode-0
program: same input descriptors, same configure sequence, same output contract. AAC is lossy:
correctness means conformance to ISO/IEC 14496-3, plus matching the device's output wherever
that is measured.

- The host demuxes the MP4 and hands over **one raw access unit per packet**: no ADTS header,
  no LATM (**MEASURED**: the first packet of a track is the 6-byte encoder priming frame
  `21 00 03 40 68 1c`, byte for byte the file's first sample).
- The AudioSpecificConfig reaches the host's codec setup at configure time, before any packet
  (**FIRMWARE**).
- Gapless trim (encoder delay, end padding) is the host's: the host trims PCM after decode
  (**FIRMWARE** arithmetic, meaning **INFERRED**). The decoder outputs every frame, priming
  frames included.

## Evidence labels

- **MPEG4**: ISO/IEC 14496-3 (and 13818-7 for the shared AAC tools).
- **FIRMWARE**: host behaviour, handed over as an interface fact.
- **MEASURED**: observed in a trace, an emulator run or on the device.
- **IMAGE-IO**: what the device's sm1 program observably consumes and produces at the host
  interface (packets in, PCM and status out). Its internals never cross into this repository.
- **FFMPEG**: PCM from the `ffmpeg` binary; a reference output, never proof of device behaviour. Its source is not read.
- **INFERRED**, **OPEN**.

## What the device accepts

The host's esds walk (**FIRMWARE**):

| Property | Device rule | Evidence |
|---|---|---|
| Container | MP4 sample entry `mp4a` with an `esds`; packets from stsz/stsc/stco (no co64) | FIRMWARE |
| objectTypeIndication / streamType | must be 0x40 / 5 | FIRMWARE |
| audioObjectType | must be 2, **AAC-LC only** (HE-AAC, LTP, Main are refused before decode) | FIRMWARE |
| Sampling frequency index | must be > 2 and < 0xF, never 0xD or 0xE; 0xF means an explicit 24-bit rate | FIRMWARE |
| Rates | 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 (96/88.2/64 kHz are refused) | FIRMWARE |
| esds size | body capped at 0x100 bytes; multi-byte lengths keep only their last byte | FIRMWARE |
| Frame length | 1024 samples per access unit | MPEG4; MEASURED (one 1024-frame output per packet) |
| Channels | the corpus is stereo; mono and channel configurations above 2 | OPEN |
| SBR / PS signalled implicitly in an LC stream | whether the program ignores or uses it | OPEN |

Because the ASC is rejected unless it is AAC-LC, the decoder needs no SBR, PS, LTP, main
prediction or ER tools. It does need everything an LC raw_data_block can carry: SCE, CPE, CCE,
LFE, DSE, PCE, FIL and END elements, at least to parse past the ones it does not use.

## Configure (once per track)

The host's configure order (**MEASURED** on silicon) is the decoder's environment, not something
it chooses:

1. The 0x120-byte codec table: the mode-0 block plus the common block.
2. Codec image pass 1 (selector {0, sel 0}), arm, wait for status bit 2, pass 2
   ({0x100, sel 1}). A decoder of ours is loaded the same way, as two passes.
3. The DSP parameter block at Y:0xFD80: byte +0 |= 1, then for mode 0 byte +0 |= 6 and
   **byte +6 = the AAC rate index**: 96000 0, 88200 1, 64000 2, 48000 3, 44100 (and unlisted) 4,
   32000 5, 24000 6, 22050 7, 16000 8, 12000 9, 11025 10, 8000 11.
   This is the only per-track parameter the program receives from the CPU besides the packets
   (**FIRMWARE**). Whether the program also parses the ASC itself: **OPEN**.

Codec mode 0 is AAC (**MEASURED** on an AAC track).

## Input contract

| Item | Rule | Evidence |
|---|---|---|
| Descriptor | 16 bytes {next/tag, control, buffer \| 0x80000000, 0} | MEASURED |
| Control word | N << 16 \| 0x1F << 7 for an N-byte packet (6 bytes -> 0x00060F80) | MEASURED |
| Chain head | physical address \| 1, written to sm1 +0x100 | MEASURED |
| Packets measured on silicon | 0x24, 0x24, then 0x2AA (the first real frame) on a 44.1 kHz stereo track | MEASURED |
| Packet bytes | reach the program only through the input stream, never written into Y by the host | MEASURED (fact 783) |
| Stream enable | once per stream, in the decoder pass: ld0e whose ALU word reads s12 = 1, s14 = 4. It survives re-arms; a second enable is not a no-op (OPEN) | MEASURED (facts 783, 786) |
| Stream read | x16alu class 111 code 0x20: A<2N+1> = the next n + 1 bits, MSB first, up to 13 measured; 0 before the enable | MEASURED (facts 783, 784) |
| Continuity | bits run on across packets; a read past the armed data stops the program until the next packet is armed; the host never realigns, so the program skips any padding itself | MEASURED (facts 784, 786) |
| Per packet | the host releases the previous slot, arms one descriptor (one raw access unit), re-arms the decoder at q256 (+0x98C = 1), waits for status bit 2, reads the output | MEASURED (fact 785) |

## Output contract

The output layout is the program's own: no CPU write configures it (**MEASURED**). A decoder
of ours must publish the same structure, because the host's output-ready path reads it:

| Address (sm1) | Contents | Evidence |
|---|---|---|
| Y:0 | entry table: Y:1 ring size; entry i: Y:5 + 2i owned flag, Y:6 + 2i length in 16-bit units. The device's init pass writes Y:0..4 = 0, 2, 0x800, 0, 0x10 (what the host does with Y:4: OPEN) | MEASURED (fact 787) |
| Y:0x80 | PCM buffers, buffer i at + i*units*2, interleaved 16-bit | MEASURED; Y mapping INFERRED |
| Y:0xFD94 | status header: Y:0xFD94 = 1 (output ready) and Y:0xFD95 = 0 per packet; Y:0xFD96, 0xFD97 are never written by the decode | MEASURED (facts 785, 787) |

Offsets in the table are in host bytes. The host takes entry `idx` when it is owned, copies
`length` units, clears the owned flag and advances `idx` modulo the ring size (**FIRMWARE**).
The program must not overwrite an owned buffer: with the ring full the host's hand-back stalls
(**MEASURED** on silicon). On silicon the two 0x24-byte packets each gave 0x800 frames and the
first real frame reported 0x1000 units (**MEASURED**); how those counts map onto one
1024-sample stereo frame is **OPEN**.

Measured for the program's output (fact 785): a two-slot ring, slots 0, 1, 0, 1 by packet.
Slot k's PCM is Y:0x80 + 0x800 k, 2048 words (1024 frames x 2 channels, interleaved); its
entry Y:5 + 2k = 1 (owned), Y:6 + 2k = 0x800 (length in 16-bit units); then Y:0xFD94 bit 0 =
1, Y:0xFD80 = 0 (the program clears it after reading it), and the program halts. The host
releases a slot by writing 0 to its owned word. The program keeps the slot index itself; X and
Y persist across arms (fact 760). The host has no mono path: it copies 4 bytes per frame, so a mono track fills the
slot as stereo with both samples equal, length 0x800 (**MEASURED** on the host's code; what the
device's own program does for mono is not measured). The descriptor carries the access unit's
exact byte count and the next one follows bit for bit (fact 784): no padding between them. How
errors are signalled: **OPEN**.

Also measured on silicon: a CPU read of engine SRAM while the program runs returns 0x74186A6A,
and X memory keeps only 24 bits per word.

## Decoding stages

ISO/IEC 14496-3 (AAC-LC) is normative; the `ffmpeg` binary's PCM is the first reference output.

1. raw_data_block element loop; channel element to output channel mapping.
2. ics_info: window sequence and shape, max_sfb, grouping; section data (codebook per band).
3. Scale factors (differential, Huffman); M/S mask.
4. Spectral Huffman decoding, codebooks 1..11 with escapes; ZERO_HCB, NOISE_HCB, INTENSITY_HCB.
5. Inverse quantisation (|q|^(4/3)) and scale-factor gain.
6. M/S stereo, intensity stereo, PNS.
7. TNS filtering.
8. IMDCT (2048 long, 256 short), sine/KBD windowing, overlap-add with the previous frame.
9. PCM: rounding and saturation to 16 bits, interleave.

Table formats, fixed-point widths and rounding points are ours to choose, from the standard and
the ISA. The device program's choices do not cross the wall.

## Open interface questions

To be answered by our own probe programs on silicon (the way x17's ISA gates were measured):

- Where execution enters after the two-pass load.
- How a program reads the bytes of the packet the descriptor points at.
- How a program raises the status header and the interrupt the host waits for.
- Which X/Y regions the host or the boot ROM may overwrite between packets.

x17 assembles and emulates every measured sm1 form; 275 silicon-measured test programs are gated
there.

## Corpus

The measured tracks are AAC-LC, 44.1 kHz, stereo (one track on silicon, a film soundtrack
through the movie path on QEMU, a 256 kbps mp4 test track). The library may still hold
lower-rate, mono or 48 kHz tracks; fixtures for those, plus short-window-heavy, intensity
stereo, PNS and TNS content, have to be made.

## Validation

1. Reference PCM per fixture from FFmpeg and a second independent decoder, versions recorded.
2. Device output: the device's program on silicon and on QEMU (a DAC capture correlates at
   ncc 1.000 against a host decode, which makes it a usable reference).
3. Compare per frame, then over a whole track including the priming frames and a track
   change (on reconfigure the host closes the old track's hand-back first).
4. Gate the decoder's building blocks in x17 the way the ISA is gated: one test program per
   stage, measured on silicon.

## References

- ISO/IEC 14496-3: MPEG-4 Audio (AAC-LC).
- ISO/IEC 13818-7: MPEG-2 AAC.
- ISO/IEC 14496-14 / 14496-1: the MP4 container and the esds descriptor.
