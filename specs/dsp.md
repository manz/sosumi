# Porting the reference models to sm1

Status: plan. The reference models (`ref/aac`, `ref/mp3`, `ref/alac`) are validated on the host;
nothing runs on sm1 yet.

## Inputs, and what stays out

Allowed: this repository's `ref/` and `specs/`, the forms x17 has measured with our own probe
programs (`isa.toml`, evidence MEASURED), and the interface facts the dirty side returns through
`specs/questions.md`. The image's sm1 programs, their disassembly and anything derived from how
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
- `bits.zig`: the bit reader. The packet is 16-bit words (x17's host staging; the engine
  path is OPEN); fields of up to 8 bits come from a 23-bit window, AND-free.
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
- Still i32: all of AAC and MP3.
- x17 assembly, stage by stage (Phase 3 order aside, ALAC first since its model is done):
  - Bit reader: x17 `examples/lib/bits.sm`, `getbits(dst, k)` for k in 1..8, streaming 16-bit
    packet words through a cache below 2^23; floor shifts come from the rounded shift. Matches
    an MSB-first reader in the emulator across refills (x17 dafcc90). 16-bit fields are two
    reads; `readn` takes up to 24 bits with the width in a register.
  - Rice codeword: x17 `examples/lib/rice.sm`, `rice_get(dst)`, the twin of `rice.get`:
    escapes, zero hi and pre * m (as additions, pre <= 8) match the model on biased random
    bitstreams, reader position included (x17 9ec89af).
  - Rice loop: `rice_decompress()`, the twin of `rice.decompress`: lg3a by comparisons, the
    two-word mean, zero runs, the 0xFFFF clamp and overrun as an error slot. State in Y slots
    (all 16-bit), residuals one 24-bit X word each through A6 (stx keeps 24 bits, measured).
    Products are single exact multiplies, round((pb << 16) * (x << 7) / 2^23). Matches the
    reference on biased random bitstreams (x17 1d286c7).
  - Predictor: `unpredict()`, the twin of `predictor.unpredict`. Every access ascends: the
    coefficients sit reversed in X, so the sum and the adaptation (k from order - 1 down)
    both walk upward with A + 1. Products are `mulWide` (plo + rounded multiply); runtime
    shifts wrap by doubling, sign extension is that shift plus an exact rounded shift.
    Matches the reference on random blocks, orders 0..31, widths 8..23, 16-bit coefficient
    wraps (x17 9ec4ea2). Every x02 multiply also bumps A1 (measured, own-x02mpy-a1), so the
    routines leave A1 alone.
  - Output: `unmix()`, the decoder's last loop: matrixing with an exact product (mulWide,
    then shift by mix_bits from the two halves), shifted low bytes, the depth's wrap, mono,
    and a gap per frame for more channels. Matches the reference's 32-bit casts on random
    frames (x17 6d4826d).
  - Packet: `alac_packet()` chains the stages: element and sub-frame headers, the
    coefficients reversed into X, the low bytes (they precede the residuals, so no skip),
    escape samples, then unmix into the channel's slot. A registers load from s through
    s -> e -> R -> even A -> any A, every step gated. The first and last packets of mono,
    tone, white24 (shifted), clicks.c0 (escape) and clicks.o30 (order 30) match the
    reference's PCM, dumped by `alacdec --dump` (x17 4eaf236). Not yet: integrate (mode != 0),
    DSE/FIL elements, more than 2 channels (the X layout), the silicon memory map.
- Evidence: every case the layer leans on is gated in x17. The rounded right shift (0x19 op
  23, negative count, half up on negatives) and the rounded multiply on negative operands
  (half up at -0.5 and 0.5) were measured on silicon by PROBES.md's nine programs (x17
  de022ba).

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
