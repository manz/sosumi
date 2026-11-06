# Reading list: AAC on a fixed-point DSP

Public material, all on the allowed side of `cleanroom.md`. Each entry says what it is good for.

## The target class

- **ARM OptimoDE / AudioDE** (2004-2005). A configurable VLIW data engine; the AudioDE
  configuration is an audio build with a **24-bit datapath**, chosen to cut intermediate scaling.
  ARM's MP3 figure: 8 MHz, 22 KB program, 22 KB data. ESPICO was the codec partner. sm1's 24-bit X
  words and VLIW bundles fit this class (x17's ISA, **INFERRED**). Architecture only; no code.
  - [EE Times: OptimoDE brings high quality audio](https://www.eetimes.com/optimode-brings-high-quality-audio-to-embedded-devices/)
  - [Design-Reuse: ESPICO codecs on OptimoDE](https://www.design-reuse.com/news/10120/espico-audio-codecs-that-run-arm-optimode-embedded-signal-processing-data-engines.html)
  - [heise: Audio-Erweiterung für ARM-Prozessoren](https://www.heise.de/news/Audio-Erweiterung-fuer-ARM-Prozessoren-161219.html)
  - [EDN 2004 DSP directory](https://www.edn.com/2004-dsp-directory/)

## Whole decoders on DSPs

- Wu et al., fixed-point AAC-LC encoder/decoder on TI OMAP5912 (C55x + ARM), IEICE Trans. Inf. &
  Syst. E93-D(5), 2010. TNS, M/S, IMDCT and IQ optimisation; Huffman table shrinking.
  [J-STAGE](https://www.jstage.jst.go.jp/article/transinf/E93.D/5/E93.D_5_1225/_article)
- HE-AAC on TMS320C55x, ETRI, J. Acoust. Soc. Korea 25(4E), 2006: 48 MIPS, 135 KB for 48 kbps
  stereo; 16/32/40-bit types. [ETRI](https://ksp.etri.re.kr/ksp/article/read?id=41801),
  [PDF](https://koreascience.kr/article/JAKO200606141780319.pdf)
- VLIW-aware AAC decoder on PACDSP, 15 MHz. The closest published analogue to scheduling AAC on
  a small VLIW. [IEEE](https://ieeexplore.ieee.org/document/4560181/)
- Tseng & Hang, MPEG-4 AAC on DSP/FPGA, NYCU thesis: IMDCT rewrite 503x, Huffman and 512-point
  IFFT offload numbers. [record](https://ir.lib.nycu.edu.tw/handle/11536/44179),
  [PDF](https://ir.lib.nycu.edu.tw/bitstream/11536/44179/1/165601.pdf)
- NYCU thesis, AAC on TI C64x. [PDF](https://ir.lib.nycu.edu.tw/bitstream/11536/66668/1/159401.pdf)

## IMDCT

- Britanak & Rao, IMDCT for MPEG Layer III, IEEE SPL 8(2), 2001 (plus its correction). The
  standard N/4-point complex FFT structure.
- Duhamel, Mahieux & Petit, fast MDCT via FFT (the algorithm Britanak-Rao builds on).
- EUSIPCO 2006: radix-2 IMDCT with rotation factors suited to fixed point.
  [PDF](https://new.eurasip.org/Proceedings/Eusipco/Eusipco2006/papers/1568980508.pdf)
- Korean paper splitting the N/4 IFFT (about 70% of IMDCT cost).
  [PDF](https://koreascience.kr/article/JAKO200709906383556.pdf)
- US 7395209, fixed-point audio decoding: IFFT with dynamic per-stage scaling, 1K 24-bit words of
  IMDCT memory. [PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7395209)

## Huffman

- Lee, Jeong & Chang, efficient Huffman decoding for MPEG-2 AAC, IEEE TSAP 2005,
  DOI 10.1109/TSA.2005.852989.
- Multi-symbol accessing Huffman decoding for MPEG-2 AAC, JEET 9(4), 2014,
  DOI 10.5370/JEET.2014.9.4.1411. Compacted fixed-length tables, long codes handled apart.
- Multi-layer prefix grouping, J. Signal Proc. Systems 2008, DOI 10.1007/s11265-008-0210-x.
  Two-level lookup on a DSP: 89% fewer cycles, 33% smaller tables than linear search.
- US 7739119: Huffman is 30-40% of decode and grows with bitrate.
  [PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7739119)
- US 6741191, 7046175, 5615020: table-lookup schemes and their memory trade-offs.

## Inverse quantisation (x^(4/3))

- US 6779015, power on a fixed-point processor by table plus linear approximation.
  [PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6779015)
- US 8725504, inverse quantisation in audio decoding: interpolation error and a small correction
  table. [PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8725504)
- US 7333036, AAC on programmable processors (24-bit DSP, scaling, log/exp approximations).
  [PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7333036)
- KICS paper, IQ table interpolation with dedicated DSP instructions.
  [PDF](https://journal.kics.or.kr/digital-library/manuscript/file/32406/NODE00941574.pdf)

## Code we may read

- OpenCORE AAC decoder (PacketVideo; fixed point, ARM-tuned). Core is Apache 2.0; **some files
  in the tarball are GPL**, so check each file's header before reading it.
  [project](https://code.google.com/p/opencore-aacdec)

## Not useful

- ARM DUI 0129A, ARM MPEG-AAC Decoder Programmer's Guide (1999): an API guide for ARM's software
  decoder on ARM cores. No internals, not the data engine.
