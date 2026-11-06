# MP3 decoder

Status: working draft. The reader side is read in RetailOS and reproduced in chikuma; the sm1
side is not started.

## Goal and boundary

Decode MPEG audio Layer III frames into PCM on sm1, from whole frames handed over by chikuma's
reader. MP3 is lossy: correctness means conformance to the MPEG decoding rules, plus matching
the device's output wherever that is measured.

The boundary is fixed by the device, not chosen:

- The reader cuts the file into frames. It skips the ID3v2 tag, finds the sync word, parses
  the header and passes **one whole frame per packet**, padding byte included (**MEASURED**:
  417 and 418 bytes for a 128 kbps / 44.1 kHz stream, `audio_feed_chunk` 0x22006AD0, the same
  feeder AAC goes through).
- The decoder therefore owns everything from side information onward, including the bit
  reservoir (`main_data_begin`). The ARM reader never touches main data (**INFERRED** from the
  reader's code; nothing in it reads past the header).

## Evidence labels

- **MPEG**: ISO/IEC 11172-3 or 13818-3.
- **FIRMWARE**: read in RetailOS's ARM code at the cited address.
- **MEASURED**: observed in a trace, an emulator run or on the device.
- **FFMPEG**: PCM from the `ffmpeg` binary; a reference output, never proof of device behaviour. Its source is not read.
- **INFERRED**: the best explanation of the above.
- **OPEN**: not established.

## What the device accepts

From `mp3_header_decode` 0x22265A40 and `mp3_frame_length` 0x222657A8 (**FIRMWARE**; named by
ipod-re's `ApplyMp3ReaderFindings.java`):

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
| Seek | Xing TOC, else VBRI, else bytes × ms / duration, then resync (`mp3_seek_ms` 0x222661A0) | FIRMWARE |

The decoder must handle MPEG-1, MPEG-2 and MPEG-2.5 Layer III: the device admits all three, so
a file in any of them reaches sm1.

## The sm1 side

- Codec mode 1 is MP3 (**MEASURED**: playing the MP3 podcast fires `codec_object_mp3`
  0x2209DB60 and no other getter). The mode byte is ctx+0x58.
- The output ring contract is AAC's (`specs/aac.md`, same `audio_output_ready` path,
  **FIRMWARE**); the per-frame unit count for 1152 samples is **OPEN**.
- Entry point, reservoir storage and synthesis history are ours to lay out; the open interface
  questions are the ones listed in `specs/aac.md`.

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
2. Device output where it can be captured: RetailOS on QEMU (ipod-re's DAC capture tooling)
   and on silicon.
3. Compare per frame, then over stateful sequences: start, steady state, seek, corrupt frame,
   end of stream. Investigate any persistent mismatch rather than widening the tolerance.

## Prior work in ipod-re

- `reports/sm1_spec.md`, "THE MP3 PATH, TRACED AND REPRODUCED": the reader chain and the trace.
- chikuma `drivers/mp3.{h,c}`: ID3v2 skip, sync search, header parse, whole-frame packets;
  `ui/tests/test_mp3.c` walks 400 frames of the real podcast.
- `reports/sm1_audio_engine.md`: the QEMU model's output buffer is one decoded frame (1152
  samples for MP3).

## References

- [ISO/IEC 11172-3](https://www.iso.org/standard/22412.html): MPEG-1 Audio.
- [ISO/IEC 13818-3](https://www.iso.org/standard/26797.html): MPEG-2 Audio, low sampling frequencies.
