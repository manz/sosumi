# ALAC decoder

Status: working draft. The container and config path are known as host interface facts; no
ALAC track has been traced. The reference model (`ref/alac/`) is bit-exact against Apple's
decoder. `dsp/lib/alac.sm` decodes 16-bit, 1 or 2 channel packets on sm1 under x17's host model,
bit for bit against `ref/dsp/alac` (`dspplay --check`); its speed is in `dspplay`'s summary.
How the device splits ALAC between the host and sm1, and which streams it accepts, are
`specs/questions.md` 11 and 12.

## Goal and boundary

Decode an ALAC packet into the original signed PCM on sm1. ALAC is lossless: decoded samples
must equal the encoded ones exactly. sm1's intermediate values may differ from a software
decoder; the output may not.

- The host's m4a reader walks `moov > trak > mdia > minf > stbl` and its sample-entry dispatch
  admits exactly `mp4a` and `alac`, then hands the parameters to the host's codec setup
  (**FIRMWARE**).
- Packet boundaries come from `stsz`/`stsc`/`stco` in that reader, so the decoder receives whole
  packets plus the config (**FIRMWARE** for the reader; the per-packet hand-over is **INFERRED**
  from the AAC path, which uses the same feeder).

## Evidence labels

- **APPLE-DOC**: Apple's ALAC package documentation.
- **APPLE-REF**: Apple's released ALAC reference source.
- **FIRMWARE**: host behaviour, handed over as an interface fact.
- **MEASURED**: observed in a trace, an emulator run or on the device.
- **FFMPEG**: PCM from the `ffmpeg` binary; a reference output, never proof of device behaviour. Its source is not read.
- **INFERRED**, **OPEN**.

Findings from other codecs, AAC included, are not evidence for ALAC.

## Configuration

`ALACSpecificConfig` is 24 big-endian bytes: frame length, compatible version (0), bit depth,
pb, mb, kb, channel count, max run, max frame bytes, average bit rate, sample rate
(**APPLE-DOC**). Apple's defaults are pb = 40, mb = 10, kb = 14 (**APPLE-DOC**).

What the host does with it (**FIRMWARE**):

    cfg+0x59  bit depth   printed: "alac: bit depth = %d, pb = 0x%X, mb = 0x%X, kb = 0x%X"
    cfg+0x5a  pb          -> ctx+0x06
    cfg+0x5b  mb          -> ctx+0x0a
    cfg+0x5c  kb          -> ctx+0x08

The context order is not the cookie order: kb lands at +8 and mb at +0xa.

| Property | Rule | Evidence |
|---|---|---|
| Bit depth | 16, 20, 24, 32 in Apple's package | APPLE-DOC; device subset OPEN |
| Channels | 1 to 8 in Apple's package | APPLE-DOC; device subset OPEN |
| Frame length | configured; 4096 default, above 16384 unsupported | APPLE-DOC |
| Channel layout record | optional 24-byte record after the config | APPLE-DOC; device use OPEN |

## The sm1 side

- Codec mode 3 is ALAC: the host's setup copies ctx+0x59..0x5c for ctx+0x58 == 3 and prints
  the line above (**FIRMWARE**).
- Mode 3 is the only mode that fills codec-table entry 3; its entry 2 +0xc is 0x3F
  (**FIRMWARE**).
- Its per-packet tail writes a mode word of 0x801 and the packet length in **bits**
  (**FIRMWARE**).
- The host's +0x58 gate: mode 3 neither releases nor advances the input where modes 0, 1
  and 5 do (**FIRMWARE**).
- Per packet the host hands the engine compressed bits (mode and length in bits, **INFERRED**); no host stage before the run found; after the run and the read-back **OPEN** (`specs/questions.md` 11).
- Configure (fact 788, read from the host's configure code, not yet read back on silicon (Q26)): Y:0xFD80 |= 0x1F (bits 0-4),
  Y:0xFD82 bit depth, Y:0xFD83 pb, Y:0xFD84 kb, Y:0xFD85 mb (kb before mb). Channel count,
  frame length and sample rate are not passed, and the program never sees the cookie: channels
  come from the frame's element tags, the frame length from the ring below.
- Output ring (fact 788, MEASURED on Apple's ALAC init pass): Y:0..4 = 0, 1, 0x2000, 0, 0x10,
  one slot of 0x2000 words (4096 frames x 2 channels) at Y:0x80. The host copy path is 16-bit
  stereo (4 bytes a frame): assume 16-bit stereo out, a mono stream on both sides. A short
  last frame's length as its frame count x 2: **INFERRED**. The host releases slots only for
  modes 0, 1 and 5, so ALAC's slot is never released: the program does not wait on its owned
  word (**OPEN**).
- Input (fact 788, corrected): the stream read of `specs/aac.md`'s input contract. Before
  every arm the host writes +0x40C = 0x801, sets +0x400 = 1, reads the 16-word block
  +0x420..+0x45C and +0x404, writes the block back with word 0 = 0x10000, word 2 = the bit
  length (bytes x 8) of the packet the next descriptor delivers, every other word 0, reads
  +0x404, sets +0x400 = 0, arms (+0x98C = 1) and writes the descriptor (MEASURED, every
  packet of one track). How a program reads word 2: **OPEN**. The host's per-packet code does
  not write the parameter block (FD80 and up) (MEASURED as far as an MMIO log shows: the
  block is SRAM).
- Memory map (fact 960, MEASURED on silicon; modelled in x17 `play --mode 3`): mode 3's DSP Y
  is 0..0x227F (16-bit), the window 0x2400..0x267F (16 bits through DSP stores; no .ydata
  there) and the host's 0xFD80..0xFDFF. Elsewhere a store is dropped and `ldy` reads 0. X:
  0..0x1FFF assumed (**INFERRED**; 0x2000..0x20FF via entry 3). A Y flag kept outside the map
  reads 0 every packet, so state such as the stream enable's flag must sit inside it.
- The EQ is a CPU-side filter in the output stage, shared by every codec: no part of an sm1
  image (MEASURED).
- Whether all of ALAC runs on sm1 or the ARM shares the work: **OPEN**. Mode 3 has an sm1 codec
  object, so at least part of it runs there (**INFERRED**).
- Entry point, buffers, persistent state, error path: **OPEN**. Nothing is traced: the dev
  library holds no ALAC track.

## Decoding stages

Apple's reference source decides; the `ffmpeg` binary's PCM is a second reference output.

1. Read the packet's elements (single channel, channel pair, LFE) up to the end marker.
2. Per element: compressed flag, sample count, shift (extra low bits), stereo parameters.
3. Uncompressed: raw signed samples at the configured depth.
4. Compressed: adaptive Rice decoding of the residuals (pb/mb/kb, the zero-run case).
5. Adaptive linear prediction, with the coefficient update and the sample-width wrap.
6. Stereo decorrelation, then re-attach the separately coded low bits.
7. Channel order from the layout; validate counts and the end marker.

## Reference model state

`ref/alac/` ports Apple's reference decoder (`third_party/alac`, **APPLE-REF**). `tools/alacdec`
reads the .m4a sample tables and writes raw PCM at the stream's depth; `tools/alacdec/gen.sh`
builds the fixtures, encoded by afconvert and by ffmpeg.

| Fixture set | Result |
|---|---|
| 21 files: 16-bit stereo and mono 44.1 kHz, 24-bit 48 and 96 kHz, white noise, 5.1 at 48 kHz; prediction orders 0 to 30 | byte-identical to afconvert's PCM |
| the same against the `ffmpeg` binary | byte-identical, except 5.1: ffmpeg reorders the channels to WAV order, every channel identical |

Exercised: SCE, CPE, verbatim packets (16 and 24 bit), shifted low bytes, matrixed stereo,
partial last packets. Never exercised, no encoder at hand writes them: prediction mode != 0 (the
integrator), LFE elements (Apple's encoder codes LFE as an SCE), DSE and FIL elements, 20- and
32-bit depth. A 32-bit CPE needs a 33-bit channel and is refused (`UnsupportedWidth`).

Output is in bitstream order, as Apple's `Decode` writes it: for 5.1 that is C, L, R, Ls, Rs,
LFE. Mapping to speakers is the reader's job (device behaviour **OPEN**).

## Validation

1. Make ALAC fixtures (the dev library has none): mono and stereo, 16 and 24 bit, uncompressed
   and compressed packets, the default and a non-default frame length.
2. Reference PCM from Apple's released decoder; FFmpeg as a second opinion.
3. Trace one ALAC track on the device (QEMU first) to confirm mode 3 fires and to capture the
   feeder's packet hand-over.
4. Compare sm1 output exactly. On a mismatch, find the first divergent stage; never relax the
   lossless requirement.

## References

- Apple's [ALAC package](https://github.com/macosforge/alac) and its
  [`ALACMagicCookieDescription.txt`](https://github.com/macosforge/alac/blob/master/ALACMagicCookieDescription.txt).
