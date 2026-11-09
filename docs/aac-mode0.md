# AAC in mode 0's memory

Mode 0 gives a program X:0..0x1BFF (7168 words of 24 bits) and Y:0..0x2E7F (11904 words of 16
bits), plus Y:0x2E80..0x2EFF, 128 more 16-bit words: the DSP's Y store keeps 16 bits there too,
so there is no 24-bit Y (specs/questions.md 15). The imported
aac_packet uses X up to 0x5131 and Y up to 0x65FF. This is the plan to fit it, Y taking
everything that 16 bits can carry.

## What has to stay 24-bit

- The spectrum, IMDCT, window and overlap words: Q7 and Q5 values up to 2^22.
- The IMDCT twiddles and the sine window. Measured with the 16-bit variant of the twin
  (tools/compare --dsp against the ffmpeg binary's PCM, 25 fixtures): the worst difference grows
  from 1-2 to 4-6 LSB, and up to 3.6% of samples move past 1 LSB.

## What goes to Y at 16 bits

- The KBD rising halves (long 1024, short 128), stored as w / 4 to 16 significant bits. Same
  measurement: every fixture within one LSB of the 24-bit twin, SNR at most 0.6 dB lower
  (mono.aac 78.6 -> 78.0 dB).
- Everything already in Y: Huffman tables, channel records, swb_offset, bit reversal, the
  packet, the PCM ring.

## One sine table for the IMDCT and the sine window

Every angle the long and short IMDCTs and both sine windows need is k * pi / 4096:

| Use | Angle | k |
|---|---|---|
| long pre-twiddle | pi (n + 1/4) / 1024 | 4n + 1 |
| long post-twiddle | pi k / 1024 | 4k |
| long FFT | 2 pi k / 512 | 16k |
| short pre, post, FFT | pi (n + 1/4) / 128, ... | multiples of 8 |
| long sine window | pi (n + 1/2) / 2048 | 2n + 1 |
| short sine window | pi (n + 1/2) / 256 | 16n + 8 |

With cos(t) = sin(pi/2 - t), the odd k up to 2047 and the multiples of 4 up to 2048 cover all
of them: 1024 + 513 = 1537 words of Q23 in X, in place of about 4100 words of tables today. The
twin's tables are then defined from this one table, so twin and program read the same values.

## The map

X (24-bit):

| X | Words | Contents |
|---|---|---|
| 0x0000 | 2048 | WORK: a channel's spectrum, then the IMDCT and window in place; its upper half is scratch for PNS, TNS and stereo before the IMDCT |
| 0x0800 | 1024 | SPEC_R: a pair's right spectrum while the left is finished |
| 0x0C00 | 1024 | OVL0, channel 0's overlap |
| 0x1000 | 1024 | OVL1 |
| 0x1400 | 1537 | SINE, sin(k pi / 4096), the k above |
| 0x1A01 | ~420 | dequantiser tables, TNS state and the save slots |

Y (16-bit):

| Y | Words | Contents |
|---|---|---|
| 0x0000 | 128 | output ring table (host contract), small slots |
| 0x0080 | 2048 | PCM ring buffer: 1024 frames x 2 channels, written in place, no PCMY copy |
| 0x0880 | 768 | the packet, staged by the host (6144 bits per channel, two channels) |
| 0x0B80 | 4544 | Huffman tables |
| ... | ~1650 | channel records, packed from 0x200 each |
| ... | 512 | bit reversal (long; short reads every eighth: rev6(i) = rev9(8i)) |
| ... | 1152 | KBD halves |
| ... | ~400 | swb_offset, the AK slots, stage slots |

Stereo T, PNS T and seeds, the TNS reflection table and the PNS generator need 24 bits, so they stay in X
(Y:0x2E80..0x2EFF keeps only 16 bits, specs/questions.md 15).

Y is within a few hundred words of full, so each stage's slots get placed against this table
before code moves.

## IMDCT in place

imdct.sm today needs IN (n2), Z (n2) and OUT (2 n2): 4096 words for a long block. On WORK:

- Long: the spectrum at WORK + 1024, Z at WORK + 0. The post-twiddle writes u back over the
  spectrum. The fold then writes out[0 .. 1023] over Z (reading u), then out[1536 ..] = -u[0 ..
  511] over u's upper half, then out[1024 .. 1535] as that copy reversed.
- Short: the spectrum at WORK + 1024. Window w's 256 outputs land at 448 + 128 w, which never
  reaches an input not yet read (1024 + 128 w' for w' > w). Its IN, Z and OUT scratch (512) fits
  WORK + 0 .. 447 with the normalised input in its own slot; that span is zeroed at the end.
- The window runs in place on WORK. So every stage finds a channel's spectrum at WORK + 1024
  with WORK + 0 .. 1023 free as scratch.

## Window tables

aac.sm copies each shape's halves into WRISE and WFALL (2048 words of X), and that room is gone.
The window loops read the sine rise from SINE (stride 2 long, 4 short) or the KBD rise from Y,
so each half loop comes in two variants picked by the shape.

## Program size

aac_packet assembles to 35397 syllables. P holds 0x4000 (4 lanes x 0x1000 rows), and pass 2 loads
at row 0x40 (handbook §11), leaving 16128. Every macro call expands in place, and calls and
returns are undefined on sm1 (handbook §9), so the code shrinks by sharing: one copy of each
stage, entered by an absolute jump and left by dispatching on a Y slot, the way aac.sm already
runs its parse (AK_PH) and its channel tail (AK_FR). This has to come first: it decides where
the stages' slots live.

## Order

1. Twin: the shared sine table and the 16-bit KBD halves; ref/dsp tests and the compare figures
   above as the check. Done.
2. Program size: one copy per stage, shared through Y-slot dispatch, under 16128 syllables; a
   size check in dsp/test/aac.zig.
3. imdct.sm and window.sm: in place on WORK, twiddles from SINE, KBD from Y.
4. The other stages onto the map; aac.sm writes the ring directly.
5. A mode-0 window check in dsp/test/aac.zig (every word touched inside the windows), the five
   fixtures bit for bit against the twin.
