# Porting the reference models to sm1

Status: plan. The reference models (`ref/aac`, `ref/mp3`, `ref/alac`) are validated on the host;
nothing runs on sm1 yet.

## Inputs, and what stays out

Allowed: this repository's `ref/` and `specs/`, the forms x17 has measured with our own probe
programs (`isa.toml`, evidence MEASURED), and the interface facts the dirty side returns through
`specs/questions.md`. The device's sm1 programs and anything derived from how
they work never cross into this repository (`docs/cleanroom.md`).

## Phase 0: measure the machine

Every design choice below waits on these. Each is answered by a probe program of ours on silicon
(x17 + shiro), never by reading the image.

Interface (`specs/questions.md` 1 to 4): entry after the two-pass load, reading packet bytes,
raising the status header and the interrupt, which X/Y regions the host may overwrite.

Resources:

| Unknown | Decides |
|---|---|
| Cycles per bundle form, and the clock | the frame budget (AAC 44.1 kHz: ~43 frames/s; MP3: ~38); fast vs direct transforms |
| Usable X and Y sizes | whether tables and buffers fit; ALAC at 4096 samples per frame needs ~12K words |
| Accumulator width: is there a 48-bit multiply-accumulate beside the rounded Q23 product of `mul13`? | ALAC: a 16-bit coefficient times a 17..25-bit difference is 33..41 bits |
| Leading-zero count / normalise, shifter range, saturation | whether F24 survives or becomes block floating point everywhere |
| Bit-field extraction from packet bytes | Huffman and Rice throughput |
| Hardware loop nesting, modulo and bit-reversed addressing | the FFT and the synthesis ring |

Each answer lands in x17's `isa.toml` as MEASURED, cycle costs as a new column so `.assert
cycles` can gate programs at assembly time.

## Phase 1: a DSP-shaped reference layer

Today's `ref/` has the target's widths, not its operations. A second layer uses only measured
operations and is checked stage by stage against today's model:

- 24-bit words, products rounded exactly as `mul13` rounds, the accumulator at its measured
  width. F24's normalise becomes per-band and per-block exponents if no leading-zero count exists.
- Fast transforms. The AAC IMDCT is already an FFT with block-floating stages. MP3 gets a fast
  DCT-32 synthesis and a 9-point decomposition of the 36-point IMDCT; the direct forms stay as the
  oracle.
- Huffman: one table-driven multi-bit lookup format, shared by AAC and MP3, one x17 routine.
- ALAC: the 32-bit wraps at the DSP's real width (multi-word if Phase 0 says so), buffers in
  place as Apple's reference allows ("to conserve buffer space on embedded devices like the
  iPod", dp_dec.c).

Gate: AAC and MP3 within 1 LSB of ffmpeg and afconvert, as now; ALAC bit-exact.

State (`ref/dsp/`):

- `ops.zig`: the measured operations the layer may use, each citing its x17 probe. The
  multiplier returns slices, not a wide result: floor(ab / 2^24) or round(ab / 2^23), plus
  (2ab)[15:0]. No persistent accumulator, carry flag, data AND/OR or leading-zero count is
  measured. `mulWide` gets an exact 16 x 24 product from two multiplies (hi * 2^15 + lo).
- `bits.zig`: the bit reader. On sm1 the packet arrives through the input stream (facts 783,
  784), a byte at a time into a cache, never past the bits the decoder needs; fields of up
  to 15 bits come from a 23-bit window, AND-free.
- `alac/`: the whole ALAC decoder, done.
  - `predictor.zig`: lo and hi parts sum in separate words; only the low `chan_bits` bits of
    the prediction reach the output, exact while den_shift + chan_bits <= 32.
  - `rice.zig`: no leading-zero count, so floor(log2) and the zero run's clz are comparisons;
    the mean (up to ~2^25) is a two-word value and pb * mb / 2^9 comes from its halves.
  - `decoder.zig`: unmix with an exact product, low bytes merged by shift and add, all modulo
    2^24 until the final wrap to the depth (<= 24).
  - Bit-exact with `ref/alac` on random blocks and random bitstreams, and with Apple on all
    21 fixtures (`alacdec --dsp`): uncompressed, shifted, matrixed, partial, mono, 5.1,
    orders 0..30, 16 and 24 bits. Unexercised, as in `ref/alac`: mode != 0, LFE, DSE, FIL.
  - Refused (`error.Unsupported`): depth 32, pb > 127, escapes over 22 bits, and predictor
    widths outside `predictor.supported`. Apple's encoder output never needs them.
- Still i32: MP3. AAC is under way in `ref/dsp/aac/`, planned below.
- `aac/huffman.zig`: every codebook as a tree of 16-bit lookup tables, root 8 bits, each step
  a peek of at most 8 bits and one entry read. Leaves carry the codeword length and the values
  already unpacked (2-bit fields for 4-tuples, 5-bit for pairs), so no divide; pointers carry
  the subtable's base and width. 4544 words for all twelve books, for Y. Matches `ref/aac` on
  every codeword and on biased random bitstreams, values, signs, escapes and reader position.
  x17 twin: `examples/lib/huffman.sm`, `huff_decode(dst)` (x17 ba83d54), checked against a
  bit-by-bit matcher on random complete codes, subtables included. About 51 bundles per
  codeword that resolves at the root, 31 per further step; untuned. ldy sign-extends
  (x17 a46987b, measured on silicon), so every table entry stays below 0x8000 (tested), and
  the bit reader's refill adds 2^16 back to a packet word that loads negative.
  Spectral codewords: one x17 macro per book family (`spec_quad_s/u`, `spec_pair_s/u`,
  `spec_pair_esc`, x17 e2b5d21): fields off the leaf, offsets, sign bits, escapes, N > 8 to a
  fail label. Match the model on random codes, escape failures at N = 9 included.
- `aac/sections.zig`: section data and scale factors into flat band arrays (band g * max_sfb
  + sfb, 120 words of book and of scale factor at most); book tests, the 0..255 range and the
  section overrun are sign tests. Matches `ref/aac` on built streams and random bytes, errors
  and reader position included. x17 twin: `examples/lib/sections.sm`, `aac_sections` and
  `aac_scalefactors` (x17 3180468), band lists in Y, running values in Y across huff_decode;
  about 130 bundles per band on random codes, ~6.5K for 49 long bands (2% of a channel-frame).
- `aac/dequant.zig`: no F24. A channel comes out as words and one exponent (w * 2^e), the
  exponent from each band's largest |q|, every word below 2^22.42 and the largest at least
  2^19. |q|^(4/3) is a normalised direct table to 128, then the reference's Q13
  interpolation with s found by comparisons and the step as one rounded multiply; the gain is
  a 12-entry Q21 table and one more. Within 2 LSB of the word plus 2^-15 relative of both the
  exact value and `ref/aac` on random channels; pulses match exactly. x17 twin:
  `examples/lib/dequant.sm`, `dq_channel` (x17 b248c75), bit-exact with the model on random
  long and short channels; ~70K bundles for 49 dense long bands, up to ~83K short (22-27%).
- `aac/imdct.zig`: the dequantiser's words normalised to a largest |x| in [2^21, 2^22) by
  comparisons, then pre-twiddle, N/4-point FFT, post-twiddle and fold as `ref/aac`. `cmul` is two
  rounded products; a stage quarters its inputs from 2^22 and halves them from 2^21 (the
  reference halves its sums, which can grow past 2^23), so a + w b stays below 2^22.3; the bit
  reversal is a table. Against double precision the error grows with loudness: 0.5 Q7 at a
  2^10 peak, 73 Q7 (0.57 PCM step) at 2^21.7, where `ref/aac` gives 41; 36 Q7 from `ref/aac`.
  Tables for x17: pre and post n4 complex each, FFT n4/2, reversal n4 (long 2.8K words).
  x17 twin: `examples/lib/imdct.sm`, `imdct(...)` (x17 c7cefa0), bit-exact with the model on
  long blocks: halving, doublings, silence, a lone positive peak, noise under one large
  last coefficient. About 255K bundles a long block (82% of a channel-frame), 31K for silence;
  short windows (n2 = 128, same routine) 26K each, 208K for the eight (x17 6df8396).
  Each stage tracks its outputs' max and min branch-free (psel at 24 bits, measured) as it
  stores, and the next stage applies the scaling with one rounded shift as it loads, so no
  block scan between stages. The twiddles sit stage by stage in X; the reversal is a Y table.
- `aac/window.zig`: window and overlap-add from the IMDCT's Q7 words. The window tables hold
  w / 4 in Q23, so one rounded multiply gives Q5 words; at most three windowed terms meet at a
  position (an illegal long-only to eight-short transition), each below 2^21, so the plain
  24-bit adds never wrap and need no saturation. PCM = clamp(rshr(overlap + block, 5)), the
  shift first so the clamp's comparisons stay within 2^18. Within 1 PCM step of double
  precision from the same words over every transition, clipping included. x17 twin:
  `examples/lib/window.sm` (x17 34ec08a, 80c5cba), bit-exact: `win_long` (fused, 40K bundles),
  `win_start` / `win_stop` (58K) and `win_short` (72K), built from product, quarter, zero and
  accumulate runs into a scratch block, then one PCM and overlap pass. PCM leaves as 16-bit Y
  words.
- `aac/stereo.zig`: M/S and intensity on the dequantiser's blocks. M/S moves both live channels
  to max(eL, eR) + 1 (rounded shifts, 0 from 24 on), so m +- s are plain adds; intensity is one
  rounded multiply by 2^(22 - b/4) at the band exponent eL + 1 - floor(pos / 4), the right block
  taking the largest of its own and its intensity bands'. A channel with no spectral book only
  takes the new exponent. Within 4 LSB of the result plus 2^-14 relative of the reference on
  random pairs, long and short. PNS waits for a stage of its own (square root, reciprocal).
  x17 twin: `examples/lib/stereo.sm`, `stereo_pair()` (x17 74f38f7), bit-exact on random pairs:
  per-band kinds, a flat (start, len, band) run list, then the exponent moves and the two passes;
  up to 52K bundles a pair, most of it the moves.
- `aac/tns.zig`: the all-pole filter as a lattice on the Q23 reflection coefficients (the
  step-up's direct-form coefficients reach C(12, 6), past any Q23 word): two rounded multiplies
  a stage, every value kept inside (-2^22, 2^22) so the adds cannot wrap. A value outside puts the
  run back, halves the whole block (exponent + 1) and filters again; past 48 halvings the run is
  zeroed (a legal stream reaches that: twelve stages at k = -0.9957 have a DC gain near 2^94).
  Against double precision: encoder-like filters within 2^-15 of the block's peak, and in both
  classes closer than `ref/aac`'s F24 direct form (1.9e-5 vs 5.0e-5; full-range codes 1.3e-2 vs
  1.9e-2, ill-conditioned for any 24-bit arithmetic). x17 twin: `examples/lib/tns.sm`,
  `tns_channel()` (x17 c9cad00), bit-exact on random channels and on the give-up case; it walks the parsed
  fields and finds the ranges itself. A long block costs 70K to 250K bundles without halvings,
  up to 720K with several (scalar, about 16 bundles a stage and sample).
- `aac/pns.zig`: noise from its own 24-bit LCG (x = 0x7655 x + 0x3C6EF3 mod 2^24, a sample is
  rshr(x, 1)), so the product is exact as a low half plus a rounded high half. A band is scaled
  up until its peak is >= 2^21, its energy summed as rshr(rnd(v^2 / 2^23), s) with s even so
  the sum fits, normalised into [2^21, 2^23) by comparisons, and 1 / (4 sqrt m) taken from six
  seeds and three Newton steps (within 4 LSB). The gain rnd(z T[b]), T[b] = 2^(22 + b/4), puts
  the band at exponent p + q - 20 - s/2, energy 2^(nrg/2) within 2e-5 relative over lengths 1 to
  1024. Correlated right noise (M/S on, both bands noise) is the left band times T[b] at
  eL + q + 1, as intensity. The block then moves to the largest exponent, as in stereo.
  x17 twin: `examples/lib/pns.sm`, `pns_channel()` (x17 8369177), bit-exact on random channels
  and pairs' rights, long and short, generator state included. About 60 bundles a noise word over
  a fixed ~20K (the run list, the block's move): 20K to 50K a channel, 82K for one band over the
  whole window.
- x19 op 23 past 23: the ALAC predictor, unmix, sxe and the IMDCT lean on right shifts beyond
  23. Measured on silicon (x17 pins them): every count past +-23 shifts fully out, 0 on the
  right (no wrap mod 32 or 64) and saturation on the left.
- AAC plan. `ref/aac` leans on three things sm1 has not shown: a 48-bit sum of products
  (`cmul`), a normalise behind F24 (dequantisation, stereo tools, TNS) and saturating adds.
  The DSP-shaped AAC drops all three. Checking is two-level, since the arithmetic differs:
  each stage against its `ref/aac` twin within a stated error, and the whole decoder within
  1 LSB of ffmpeg and afconvert on the fixtures (the Phase 1 gate). x17 then matches the
  DSP-shaped model bit for bit, as ALAC does. Numeric stages first, since they fix the
  formats; the bitstream stages are integer and match `ref/aac` exactly.
  1. `ops.zig` caught up with what x17 has gated since: the whole ptst table (b < 0, b <= 0,
     b == 0 on s4/s8/s12), floor(ab / 2^24), the undoubled low half with it, 24-bit operands
     with no saturation to |ab| = 2^41, x19mac (head ALU, multiply and A step in one bundle).
  2. Dequantisation without F24: a band's exponent is floor(sf / 4), read off the bitstream,
     no leading-zero count. Mantissa = |q|^(4/3) (|q| <= 8191, below 2^17.3: the pow43
     direct table and interpolation) times 2^((sf mod 4) / 4) as Q23.
  3. IMDCT: `cmul` as two rounded products summed (one more LSB per complex product, to be
     measured end to end); the FFT's block floating point keeps its rule, "any component >=
     2^21" being a sign test on |x| - 2^21; the block exponent from the band exponents.
  4. Window and overlap-add with headroom instead of saturation, then the PCM clamp by
     comparisons.
  5. M/S, intensity, PNS (its 32-bit LCG as two words), TNS (the LPC filter with exact
     products, like ALAC's tap).
  6. Bitstream: section data, scalefactors, Huffman as one table-driven multi-bit lookup
     shared with MP3, pulse data. Then the whole decoder against the fixtures.
  Memory (`questions.md` 6): 8192 X words and 11904 16-bit Y words; the buffers take 4.4K X,
  leaving ~3.7K for tables. The rounded multiply saturates at -1 x -1 (x17 d6d3390), the
  one product that would not fit, so Q23 twiddles may use -1.
- x17 assembly, stage by stage (Phase 3 order aside, ALAC first since its model is done):
  - Bit reader: x17 `examples/lib/bits.sm`, `getbits(dst, k)` for k in 1..8, streaming 16-bit
    packet words through a cache below 2^23; floor shifts come from the rounded shift. Matches
    an MSB-first reader in the emulator across refills (x17 1c81033). 16-bit fields are two
    reads; `readn` takes up to 24 bits with the width in a register.
  - Rice codeword: x17 `examples/lib/rice.sm`, `rice_get(dst)`, the twin of `rice.get`:
    escapes, zero hi and pre * m (as additions, pre <= 8) match the model on biased random
    bitstreams, reader position included (x17 f4a77b6).
  - Rice loop: `rice_decompress()`, the twin of `rice.decompress`: lg3a by comparisons, the
    two-word mean, zero runs, the 0xFFFF clamp and overrun as an error slot. State in Y slots
    (all 16-bit), residuals one 24-bit X word each through A6 (stx keeps 24 bits, measured).
    Products are single exact multiplies, round((pb << 16) * (x << 7) / 2^23). Matches the
    reference on biased random bitstreams (x17 ed90386).
  - Predictor: `unpredict()`, the twin of `predictor.unpredict`. Every access ascends: the
    coefficients sit reversed in X, so the sum and the adaptation (k from order - 1 down)
    both walk upward with A + 1. Products are `mulWide` (plo + rounded multiply); runtime
    shifts wrap by doubling, sign extension is that shift plus an exact rounded shift.
    Matches the reference on random blocks, orders 0..31, widths 8..23, 16-bit coefficient
    wraps (x17 8bdf8e7). Every x02 multiply also bumps A1 (measured, own-x02mpy-a1), so the
    routines leave A1 alone.
  - Output: `unmix()`, the decoder's last loop: matrixing with an exact product (mulWide,
    then shift by mix_bits from the two halves), shifted low bytes, the depth's wrap, mono,
    and a gap per frame for more channels. Matches the reference's 32-bit casts on random
    frames (x17 55f9277).
  - Packet: `alac_packet()` chains the stages: element and sub-frame headers, the
    coefficients reversed into X, the low bytes (they precede the residuals, so no skip),
    escape samples, then unmix into the channel's slot. A registers load from s through
    s -> e -> R -> even A -> any A, every step gated. The first and last packets of mono,
    tone, white24 (shifted), clicks.c0 (escape) and clicks.o30 (order 30) match the
    reference's PCM, dumped by `alacdec --dump` (x17 c5e05f2). Integrate (mode != 0) runs
    in place over the residuals; no encoder emits it, so `alacdec --integrate` rewrites the
    first packet's modes to 1 and the reference decodes it (ref and --dsp agree); mono and
    stereo match (x17 e09d152). Not yet: DSE/FIL elements, more than 2 channels (the X layout), the silicon memory map.
  - Cost (x17 ab08904, `zig build bench`): bundles per sample per channel, first packets,
    and the load at the fixture's rate. One bundle of any form takes about 37.4 ns on
    silicon (26.7 M/s, MEASURED on silicon; the clock is unread, so one bundle per cycle
    is INFERRED). 100% is real time.

    | fixture | total | rice | integrate | predict | unmix | other | load |
    |---|---|---|---|---|---|---|---|
    | mono.at (order 8) | 358 | 174 | | 149 | 35 | 0 | 59% |
    | tone.at (stereo, matrixed) | 272 | 93 | | 124 | 55 | 0 | 90% |
    | white24.at (24-bit, 48 kHz) | 462 | 113 | | 231 | 63 | 55 | 166% |
    | clicks.c0.ff (escape) | 116 | | | | 30 | 86 | 38% |
    | clicks.o30.ff (order 30) | 535 | 179 | | 306 | 50 | 1 | 177% |
    | mono.at.int | 448 | 174 | 21 | 218 | 35 | 0 | 74% |

    16-bit stereo now runs under real time. The predictor's tap is six bundles a term
    (four x02 bundles plus pcond and a jmp, down from 17): each x02 bundle carries an X read,
    an A step, a multiply and an add, and each product is exact as floor((c << 8) d / 2^24)
    2^16 plus the undoubled cd[15:0] (x02 with w1[17] = 1, measured on silicon). pcond
    ends the loop on the coefficient pointer itself, so no counter. Earlier: the adaptation
    split by the sign of the residual, sign extension in seven bundles, and in Rice the k
    search from the last k and prefix bits straight off the cache. Order 30 and 24-bit stay
    over: next are the adaptation loop (now the larger half of predict) and Rice. The tap's
    one-bundle combinations (X read with the old A, the x3 add reading before the writes,
    pcond c30) are x17's model; their silicon run is pending.
- Evidence: every case the layer leans on is gated in x17. The rounded right shift (0x19 op
  23, negative count, half up on negatives) and the rounded multiply on negative operands
  (half up at -0.5 and 0.5) were measured on silicon by PROBES.md's nine programs (x17
  e0aa7e7).

## Phase 2: x17 must have

1. The assembler: labels, `bcc` with its two delay slots, `.const`, tables placed in X and Y.
2. The emulator running a whole program against a modelled host: the descriptor chain in, the
   output ring and status header out (`specs/aac.md`, input and output contracts).
3. Cycle counting and `.assert cycles`.
4. `.include` and macros: the bit reader, Huffman, PCM output and ring publishing are shared by
   all three decoders.
5. `x17 fmt` at least (a816 format / zig fmt style): one canonical layout for the sources the
   three decoders share, checked in CI. A linter can follow once the sources exist.

## Phase 3: order on sm1

1. A null codec: copy packet bytes to the output ring. The smallest end-to-end test of the
   interface on silicon.
2. AAC: the priority (the library is all AAC); it builds most shared parts.
3. MP3: reuses Huffman, pow43, the bit reader and the output; adds the reservoir, the hybrid
   filterbank and synthesis.
4. ALAC: no tables, but the hardest on width. If Phase 0 measures an accumulator of 33 bits or
   more, it moves up as a cheap toolchain test after the null codec.

## Per-stage loop

1. One x17 routine per stage.
2. A harness feeds it the DSP-shaped model's input state for that stage; the emulator's output
   must match bit for bit (the model is at sm1's widths, so exact is the bar).
3. Whole decoder: emulator PCM equals the DSP-shaped model's PCM.
4. Silicon: shiro loads the program, the fixtures play, the output ring is read back; it must
   equal the emulator's and fit the cycle budget with margin.
5. Later, the QEMU HLE: the same model behind a C ABI, linked by qemu-ipod (never the reverse).

## Risks

- ISA forms with OPEN bits and combinations that wedge: a decoder uses only fully measured
  paths, so each new need starts as a probe.
- No cycle model yet: a tight budget forces the fast paths and more Phase 1 work.
- The per-packet hand-over is INFERRED from the AAC path; MP3's units per frame are OPEN.
- ALAC's 32-bit arithmetic on 24-bit words.
