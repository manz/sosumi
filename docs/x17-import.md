# Importing x17's codec libraries

x17's `examples/lib/*.sm` and their `src/lib_test.zig` cases were written in another session.
None of them enters sosumi without the audit below; each one passes it or is rewritten here
(`specs/questions.md` row 7).

## Layout in sosumi

    dsp/lib/*.sm       the stage libraries, one per ref/dsp stage
    dsp/test/*.zig     their tests, run by `zig build test` in x17's assembler and emulator
    dsp/aac/packet.sm  the aac_packet glue, written here on audited stages only

To run its tests, sosumi needs x17's assembler and emulator as Zig modules (`asm`, `emu`) from
x17's `build.zig`, taken as a dependency. That export is x17's to add; until it lands, nothing
moves.

## Audit, per file

A file moves only when every point holds:

1. **Twin.** It names its `ref/dsp` model and the ISO clause (or Apple ALAC source) behind it.
   Its behaviour is that model's: same inputs, same outputs, bit for bit.
2. **Constants.** Every constant, table layout and fixed-point width comes from the twin, the
   standard or the ISA. Anything else is struck or rewritten.
3. **Citations.** ISA facts cite x17's `docs/sm1/reference.md` entry and the probe that gates
   them (`own-*`), not the line-numbered `fact N` citations.
4. **Clean text.** It has no host addresses, host symbol names and no mention of the device's
   own programs. `tools/provenance/check.sh` passes on it.
5. **Tests.** Its `lib_test` cases come over with it, compare against the `ref/dsp` twin (not a
   copy of the .sm's own arithmetic), and pass.
6. **Provenance line.** Its header says: audited from x17 at commit C, twin, ISO clause, date.

Whatever fails a point is rewritten in sosumi from the twin, not patched in x17.

Known hazard to check in every stage: an `x02.v s0, A0, ...` bundle with nothing to read loads
X:[A0] into s0, and the same bundle's multiply slots see that write. It is harmless only where
X:0 is guaranteed zero; otherwise the read goes to a dead register (x17 3015397 did this for
predictor.sm).

## Order

The AAC path first, each lib after what it calls:

    bits, mem, pcm -> huffman -> sections -> dequant -> stereo -> pns -> tns -> imdct -> window

ALAC afterwards: rice, predictor, unmix, alac.

## Log

| File | x17 commit | Twin | Verdict |
|---|---|---|---|
| bits.sm | 2f5d48b | `ref/dsp/bits.zig` | **Moved** to `dsp/lib/bits.sm`. Substance matches the twin: MSB-first reads from 16-bit Y words, floor by the rounded right shift. Constants are ISA opcodes and ptst/jmp encodings. Citations rewritten to `reference.md` `ldy` (own-ldysx), `ptst` (own-ptst-c1-*, c10..c31), `jmp` (own-jmp), `x19`. Tests (`dsp/test/bits.zig`) check getbits and readn against `ref/dsp/bits.zig`'s Reader; x17's version used its own hand reader, and covered no readn. |
| mem.sm | c900697 | none | **Moved** to `dsp/lib/mem.sm`. Y-slot and A-register plumbing, no arithmetic of a stage. Citations added for `x17.mve`, `x19.a3`, `x12.aset`, `x03.agu`. No test of its own in x17; covered by the stages that include it, which come with them. |
| pcm.sm | 2f5d48b | none | **Moved** to `dsp/lib/pcm.sm`. 16-bit passthrough, WAV and AIFF byte order. Ring shape, entry flags and status word follow `specs/aac.md`'s output contract; Y:0x3FFF / 0x4000 are x17's host stub, Y:0xFD81 and Y:0x3FF0 are ours. Test (`dsp/test/pcm.zig`) feeds three packets through x17's host model and reads the ring back. |
| add.sm | 2f5d48b | none | Not moved: only x17's `examples/macros.sm` uses it; no codec lib does. |
| huffman.sm | 2f5d48b | `ref/dsp/aac/huffman.zig` | **Moved** to `dsp/lib/huffman.sm`. Table entry format (leaf `(v << 5) + len`, pointer `(base << 5) + 16 + w`) and the packed spectral fields (last value lowest, offsets per book) are the twin's; escapes per ISO 4.6.3.3. No `x02.v`. Citation rewritten to `reference.md` `ldy`. Tests (`dsp/test/huffman.zig`) now decode the twin's own 12 book tables with `decode` / `decodeSpectral` as the reference; x17's tests rebuilt the tables and the spectral model by hand over random codes. Covered: 50 scale factor codewords past the 8-bit root, every spectral book, escapes, and the N = 9 escape failure. |
| sections.sm | 2f5d48b | `ref/dsp/aac/sections.zig` | **Moved** to `dsp/lib/sections.sm`. Every branch is the twin's and ISO 4.6.2.3's: reserved book 12 and section overrun fail, ZERO_HCB stores 0, noise energy from global_gain - 90 with a 9-bit first value less 256, intensity from 0, scale factors range-checked to 0..255. Y layout AAC_BOOK / AAC_SF / AAC_ACC is ours. No citations to rewrite, no `x02.v`. Tests (`dsp/test/sections.zig`) generate streams with the twin's scale factor codes and check books, scale factors, the -1 end and both fail paths against `readSections` / `readScalefactors`; x17's used a random code and its own model. |
| dequant.sm | 2f5d48b | `ref/dsp/aac/dequant.zig` | **Moved** to `dsp/lib/dequant.sm`. Both passes are the twin's: E from each spectral band's largest \|q\|, then every coefficient shifted to E; \|q\|^(4/3) from the direct table to 128, the Q13 interpolation above. Its host tables are the twin's, which this import made public (`direct_m/e`, `interp`, `gain`, `interp_e/rem`; DQ_IR holds 4 rem). X/Y addresses are ours. No citations to rewrite, no `x02.v`. Tests (`dsp/test/dequant.zig`) stage those tables and the real 44.1 kHz band offsets and check words and E against `dequantChannel`; x17's rebuilt the tables and the model by hand. |
| stereo.sm | 2f5d48b | `ref/dsp/aac/stereo.zig` | **Moved** to `dsp/lib/stereo.sm`. Band kinds are ISO 4.6.8's and the twin's: M/S where ms_used and neither book is noise or intensity; intensity negated for book 14, inverted by ms_used only when ms_mask_present = 1. Exponent moves and the T[b] = 2^(22 - b/4) multiply are the twin's (`quarter`, now public). It holds one shape, so it is only right for common_window pairs; the glue must not call it otherwise. No citations to rewrite, no `x02.v`. Tests (`dsp/test/stereo.zig`) build `ics.ChannelPair`s with the real 44.1 kHz offsets and check both blocks and exponents against `applyPair`; x17's used made-up offsets and its own model. |
