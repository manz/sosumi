# AC-3 decoder

Status: stub. The device is known to select and decrypt an AC-3 track; nothing about its
decoder is identified.

## What is known

- The film QJGW ("Là-haut") has four sound tracks: two `mp4a` (AAC, 44.1 kHz stereo) and two
  `ac-3` (48 kHz), all `drms`. Playing it, the firmware **selected an AC-3 track**: all 293
  sampled AES audio inputs fall inside AC-3 samples, none in the AAC tracks (**MEASURED**,
  ipod-re `reports/fairplay.md` §7z).
- The AES input is the raw `mdat` ciphertext, starting partway into each sample (partial
  encryption) (**MEASURED**, same section).
- A clean AC-3 frame has **not** been produced from a decrypted sample yet. Earlier attempts
  wrapped the payload as AAC (same section, "NOT YET PROVEN").

## What is open

- **Which codec mode carries AC-3.** Modes 0 (AAC), 1 (MP3) and 3 (ALAC) are named; mode 5
  (object 0x229511E8) and modes 2/4/6 (shared object 0x22917488) are not. Either could be AC-3.
  Naming it takes the same experiment that named modes 0 and 1: play the film and see which
  `codec_object_*` getter fires.
- Whether sm1 decodes AC-3 or the video path handles it some other way.
- Channel handling: AC-3 is up to 5.1; the iPod outputs stereo, so a downmix happens somewhere.
- Frame size: 1536 samples per AC-3 frame (**ATSC A/52**). The QEMU model already sizes its
  output buffer for that; it is our model, not device evidence.

## Next step

Trace the getters while RetailOS plays QJGW on QEMU. That names the mode and decides whether
this spec grows the same sections as `mp3.md`.

## References

- ATSC A/52, Digital Audio Compression (AC-3, E-AC-3) Standard.
