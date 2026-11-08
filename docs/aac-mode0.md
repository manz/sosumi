# AAC in mode 0's memory

Mode 0 gives a program X:0..0x1BFF (7168 words of 24 bits) and Y:0..0x2E7F (11904 words of 16
bits), plus Y:0x2E80..0x2EFF, 128 words that keep 24 bits (x17 handbook §2). The imported
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

Y:0x2E80..0x2EFF (24-bit): stereo T, PNS T and seeds, TNS reflection table, the PNS generator.

Y is within a few hundred words of full, so each stage's slots get placed against this table
before code moves.

## Order

1. Twin: the shared sine table and the 16-bit KBD halves; ref/dsp tests and the compare figures
   above as the check.
2. imdct.sm and window.sm: in-place on WORK, twiddles from SINE, KBD from Y.
3. The other stages onto the map; aac.sm writes the ring directly.
4. A mode-0 window check in dsp/test/aac.zig (every word touched inside the windows), the five
   fixtures bit for bit against the twin.
