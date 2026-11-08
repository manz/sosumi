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

    bits, mem, pcm -> huffman -> sections -> dequant -> stereo -> pns -> tns -> imdct -> window -> aac

ALAC afterwards: rice, predictor, unmix, alac (moved).

## Log

The ISO/IEC 14496-3 clause numbers in the imported headers and commit messages were written from
memory and are not yet checked against the standard's text (OPEN).

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
| pns.sm | 2f5d48b | `ref/dsp/aac/pns.zig` | **Moved** to `dsp/lib/pns.sm`. Our 24-bit LCG (a = 0x7655, c = 0x3C6EF3, ISO leaves the generator open), the sum-of-squares scaling, the 6-entry seed and three Newton steps, and correlated right noise at eL + q + 1 are the twin's; `quarter` and `seed` are the twin's public tables. Citation added for `x03.mpy` (own-x03plo). No `x02.v`. Tests (`dsp/test/pns.zig`) run both modes against `channel` / `right` on `ics` channels and pairs, with random band widths and a whole-window band; words, exponent and the generator state match. |
| tns.sm | 2f5d48b | `ref/dsp/aac/tns.zig` | **Moved** to `dsp/lib/tns.sm`. The lattice on Q23 reflection coefficients, the (-2^22, 2^22) bound with put-back, halve and retry up to 48 times, then zero the run: all the twin's. Its table is the twin's `refl` (coef_res 0 at TN_K + 0..7, 1 at TN_K + 8..23). TN_REC is our flattening of tns_data(). No citations to rewrite, no `x02.v`. Tests (`dsp/test/tns.zig`) build `ics.Tns`, flatten it to TN_REC and check words, exponent, halvings and runs zeroed against `apply` with the real 44.1 kHz offsets and TNS limits; x17's used made-up offsets and its own model. |
| imdct.sm | 2f5d48b | `ref/dsp/aac/imdct.zig` | **Moved** to `dsp/lib/imdct.sm`. Normalisation to [2^21, 2^22), pre-twiddle into a bit-reversed n2/2-point FFT, per-stage scaling, post-twiddle, fold and one saturating output shift: all the twin's. Its tables are the twin's `Tables(n2)` (`pre`, `post`, `rev`); TW is the twin's `fft` laid out stage by stage. Citation added for the `x19` shift. No `x02.v` (only `x02.ainc` / `x02.mpy`, whose side effects the header documents). Tests (`dsp/test/imdct.zig`) run long and short blocks, six shapes each (halving, doublings, silence, a lone peak, a large last coefficient), against `imdct`; x17's rebuilt the tables and the model by hand. |
| window.sm | dd66f03 | `ref/dsp/aac/window.zig` | **Moved** to `dsp/lib/window.sm`. The w / 4 Q23 halves, the four sequences' layouts, the rounded shift by 5 before the clamp and the overlap hand-on are the twin's `block` and `synth`. The macros take constant table addresses, so the glue copies each shape's rising halves into fixed slots. No citations to rewrite, no `x02.v`. Tests (`dsp/test/window.zig`) run every sequence for every previous/current shape pair with the twin's real sine and KBD halves, quiet, clipping and at the clamp's edges; x17's used random window values and its own model. |
| aac.sm | 70471ae | `ref/dsp/aac/decoder.zig` | **Moved** to `dsp/lib/aac.sm`: the aac_packet glue. Element loop, ics parse into a channel record, pulses, then per pair left PNS, M/S and intensity (common_window only, status 4 otherwise), right PNS and each channel's TNS, IMDCT, window and overlap: the twin `Decoder.decode`'s order. CCE and PCE stop with status 1, as the twin's `ElementNotImplemented`. Host tables and state slots are ours. No citations to rewrite, no `x02.v`. x17's `testdata/aac/books.txt` stays behind: the test stages the twin's own tables. Tests (`dsp/test/aac.zig`) load each `aacdec --dump` fixture's state and decode all its units, PCM bit for bit against the twin's `Decoder`. X use runs to 0x5131 and Y to 0x65FF: an emulator layout, not the silicon fit. |
| rice.sm | b95e52f | `ref/dsp/alac/rice.zig` | **Moved** to `dsp/lib/rice.sm`. Mean slots load through e12, not e2 (x17 reference.md `ldy`). Citations rewritten. No `x02.v`. Tested with the packet test below. |
| predictor.sm | b95e52f | `ref/dsp/alac/predictor.zig` | **Moved** to `dsp/lib/predictor.sm`. The `x02.v` hazard is handled: bundles with nothing to read load X:[A0] into s8, which is dead there. The exact c * d sum (floor(cd / 2^16) * 2^16 + cd[15:0]) relies on x02 mode 5's low product being 24 bits, masked by x18.and. Citations rewritten. Tested with the packet test below. |
| unmix.sm | b95e52f | `ref/dsp/alac/decoder.zig` (unmix and low bytes) | **Moved** to `dsp/lib/unmix.sm`. Citations rewritten. Tested with the packet test below. |
| alac.sm | b95e52f | `ref/dsp/alac/decoder.zig` | **Moved** to `dsp/lib/alac.sm`. Mode-0 layout: X 0..0x1BFF one lane at a time, a pair's lane 0 parked in Y:0x1D00 as 16 bits, the ring at Y:0x80 over the staged packet, status 6 when a packet reaches Y:0x1D00. Output 16-bit only (status 4 above). Tests (`dsp/test/alac.zig`) run `dsp/player.zig`, x17's host model with the packet at Y:0x80, over the seven `alacdec --dsp --dump` fixtures, PCM bit for bit against the twin `Decoder`. They are regenerated here and byte-identical to x17's copies. Stage-level tests are not ported: x17's rice, predictor and unmix tests check hand models (`refGet`, `refDecompress`, `refUnpredict`), not the twins, so the packet test against the twin is the gate (OPEN: per-stage tests on the twins). |

## Silicon follow-ups

Reported by the dirty side after the moves, 2026-11-08; the stage tests run on x17's emulator
model and do not see them:

- **x19.xrd's X read index**: silicon reads A<{w1[2:0], head[31:30]}>; x17 185c2fa assembles
  `x19.xrd s, #k` to it, so the source keeps its meaning. No lib text changed, and the tests
  pass against x17 bb264cb, which also refuses `x19.xrd #0/#31` and `stx A0/A31` (none here)
  and keeps an x02 X read into s0 out of the bundle (none here).
- **ldy through e2 returns junk** (x17 fba720e refuses it): no lib here loads through e2; the
  tests pass against x17 fba720e.
- **X in mode 0 is 0..0x1BFF** (`specs/questions.md` 6): stereo.sm (ST_T), pns.sm (PN_T,
  PN_SEED, PN_RNG) and tns.sm (TN_K, TN_KC, TN_B) put tables at X:0x1F00 and up, outside the
  window. Their layout has to move before the silicon fit; the emulator runs are unaffected.
- **x03 and x18 low products are 24 bits, unmasked** (x17 121d31b, reference.md `x03.mpy`):
  pns.sm's LCG read x03.mpy's low half as [15:0]; it now masks it with x18.and. predictor.sm
  already masked x02's. No other lib reads an x03 or x18 low half.
- **x17 b95e52f's ALAC pass** (silicon-checked on bfa9566): delay slots filled, x17.styi
  post-increment stores, unmix_y16 for depth 16, and the e2 note dropped (fact 658 retracted
  650). ISA-only, no new constants. Taken into all four ALAC libs, assembled against x17
  >= bfa9566 as required. Packet test and dspplay --check stay bit-exact. Mean bundles per
  packet: tone.at 2.36M -> 2.23M, pink.at 2.79M -> 2.65M, mono.at 1.61M -> 1.54M,
  clicks.o30.ff 4.61M -> 4.48M.
