# OpenCORE AAC decoder tables

Unmodified files from PacketVideo's AAC decoder as shipped in AOSP
`platform/frameworks/base`, tag `android-2.3.7_r1`,
`media/libstagefright/codecs/aacdec/`. Copyright (C) 1998-2009 PacketVideo, Apache License 2.0
(each file carries its header; the licence text is `LICENSE` at the repository root).

Used only to derive tables:

- `decode_huff_cw_binary.cpp`, `hcbtables_binary.cpp`, `hcbtables.h`, `s_hcb.h`: run by
  `tools/huffdump` to recover each codebook as (index, length, codeword), giving
  `ref/tables/huffman.zig`.
- `sfb.cpp`: scale factor band edges, converted by hand into `ref/tables/swb.zig`.
- `e_huffmanconst.h`: the scale factor, noise and intensity offsets used in `ref/ics.zig`.
