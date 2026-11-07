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

## Order

The AAC path first, each lib after what it calls:

    bits, mem, add, pcm -> huffman -> sections -> dequant -> stereo -> pns -> tns -> imdct -> window

ALAC afterwards: rice, predictor, unmix, alac.

## Log

| File | x17 commit | Twin | Verdict |
|---|---|---|---|
| bits.sm | 8ca5ba4 | `ref/dsp/bits.zig` | Substance matches the twin: MSB-first reads from 16-bit Y words, floor by the rounded right shift. Constants are ISA opcodes and ptst/jmp encodings. Fails point 3: cites `fact 409`, `377/387/389`, `94`; rewrite to `reference.md` `ldy` (own-ldysx), `ptst` (own-ptst-*), `jmp` (own-jmp). Not moved yet (waits on the module export). |
