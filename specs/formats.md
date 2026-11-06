# Formats the iPod classic plays

Apple's technical specifications for the iPod classic 160GB (Late 2009), the 6G this project
targets ([support.apple.com/112601](https://support.apple.com/en-ca/112601), [SP572](https://support.apple.com/kb/SP572)):

> Audio formats supported: AAC (8 to 320 Kbps), Protected AAC (from iTunes Store), MP3 (8 to
> 320 Kbps), MP3 VBR, Audible (formats 2, 3, 4, Audible Enhanced Audio, AAX, and AAX+), Apple
> Lossless, AIFF, and WAV

> [video] with AAC-LC audio up to 160 Kbps, 48kHz, stereo audio in .m4v, .mp4, and .mov file formats

AC-3 and Dolby appear nowhere on the page.

| Format | Codec work for sosumi | Spec | State |
|---|---|---|---|
| AAC, Protected AAC, video soundtracks | AAC-LC (FairPlay is the reader's, not the codec's) | `aac.md` | reference model done |
| MP3, MP3 VBR | MPEG-1/2/2.5 Layer III | `mp3.md` | reference model done |
| Apple Lossless | ALAC | `alac.md` | reference model done |
| AIFF, WAV | none expected: PCM, byte order at most | none | whether sm1 is involved is OPEN |
| Audible AAX, AAX+ | AAC in MP4, Audible DRM in the reader | `aac.md` | covered by AAC, INFERRED; whether files Audible sells today still play on the device is OPEN (the list is from 2009) |
| Audible formats 2, 3, 4, Enhanced (.aa) | a speech codec for 2 and 3, MP3 for 4 and Enhanced: INFERRED, from general knowledge of the .aa format, unverified | none | lowest priority (audiobooks) |
| AC-3 | not an advertised format | `ac3.md` | the device was measured selecting a film's AC-3 track (ipod-re `reports/fairplay.md` §7z), which the spec sheet does not explain: OPEN, parked |
