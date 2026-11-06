# ALAC decoder

Status: working draft. The container and config path are read in RetailOS; no ALAC track has
been traced and the sm1 side is not started.

## Goal and boundary

Decode an ALAC packet into the original signed PCM on sm1. ALAC is lossless: decoded samples
must equal the encoded ones exactly. sm1's intermediate values may differ from a software
decoder; the output may not.

- RetailOS's m4a reader walks `moov > trak > mdia > minf > stbl` and its sample-entry dispatch
  admits exactly `mp4a` and `alac` (`m4a_sample_entry_dispatch` 0x2213D04C, which hands the
  parameters to `audio_codec_setup` 0x2208F458) (**FIRMWARE**).
- Packet boundaries come from `stsz`/`stsc`/`stco` in that reader, so the decoder receives whole
  packets plus the config (**FIRMWARE** for the reader; the per-packet hand-over is **INFERRED**
  from the AAC path, which uses the same feeder).

## Evidence labels

- **APPLE-DOC**: Apple's ALAC package documentation.
- **APPLE-REF**: Apple's released ALAC reference source.
- **FIRMWARE**: read in RetailOS's ARM code at the cited address.
- **MEASURED**: observed in a trace, an emulator run or on the device.
- **FFMPEG**: FFmpeg's decoder; a cross-check only.
- **INFERRED**, **OPEN**.

Findings from other codecs, AAC included, are not evidence for ALAC.

## Configuration

`ALACSpecificConfig` is 24 big-endian bytes: frame length, compatible version (0), bit depth,
pb, mb, kb, channel count, max run, max frame bytes, average bit rate, sample rate
(**APPLE-DOC**). Apple's defaults are pb = 40, mb = 10, kb = 14 (**APPLE-DOC**).

What the device does with it (**FIRMWARE**, rt 0x08084640, ipod-re `reports/m4a_decoder.md`):

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

- Codec mode 3 is ALAC: the ctx+0x58 == 3 case of the setup tail (0x2208FC80) copies
  ctx+0x59..0x5c and prints the line above; `codec_object_alac` 0x220A737C returns the object
  (**FIRMWARE**, ipod-re `ApplySm1IsaFindings.java`).
- The image's mode-3 object is at 0x2294E08C: three records, sizes 0x22 / 0x6 / 0xBEC units, the
  smallest of the five images (**FIRMWARE**).
- Mode 3 is the only mode that fills codec-table entry 3; its entry 2 +0xc is 0x3F
  (**FIRMWARE**, `reports/sm1_spec.md`).
- Its per-packet tail writes a mode word of 0x801 and the packet length in **bits**
  (**FIRMWARE**).
- The +0x58 gate (0x220B2648): mode 3 neither releases nor advances the input where modes 0, 1
  and 5 do. chikuma does not model this yet (**FIRMWARE**; `reports/aac_on_silicon.md` §15).
- Whether all of ALAC runs on sm1 or the ARM shares the work: **OPEN**. The sm1 object exists, so
  at least part of it runs there (**INFERRED**).
- Entry point, buffers, persistent state, error path: **OPEN**. Nothing is traced: the dev
  library holds no ALAC track.

## Decoding stages

Apple's reference source decides; FFmpeg's `alac.c` cross-checks.

1. Read the packet's elements (single channel, channel pair, LFE) up to the end marker.
2. Per element: compressed flag, sample count, shift (extra low bits), stereo parameters.
3. Uncompressed: raw signed samples at the configured depth.
4. Compressed: adaptive Rice decoding of the residuals (pb/mb/kb, the zero-run case).
5. Adaptive linear prediction, with the coefficient update and the sample-width wrap.
6. Stereo decorrelation, then re-attach the separately coded low bits.
7. Channel order from the layout; validate counts and the end marker.

## Validation

1. Make ALAC fixtures (the dev library has none): mono and stereo, 16 and 24 bit, uncompressed
   and compressed packets, the default and a non-default frame length.
2. Reference PCM from Apple's released decoder; FFmpeg as a second opinion.
3. Trace one ALAC track on RetailOS (QEMU first) to confirm mode 3 fires and to capture the
   feeder's packet hand-over.
4. Compare sm1 output exactly. On a mismatch, find the first divergent stage; never relax the
   lossless requirement.

## References

- Apple's [ALAC package](https://github.com/macosforge/alac) and its
  [`ALACMagicCookieDescription.txt`](https://github.com/macosforge/alac/blob/master/ALACMagicCookieDescription.txt).
- FFmpeg [alac.c](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/alac.c).
