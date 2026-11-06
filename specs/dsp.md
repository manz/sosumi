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
