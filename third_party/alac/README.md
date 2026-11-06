# Apple ALAC reference decoder

Decoder-side files from Apple's ALAC package, https://github.com/macosforge/alac at commit
c38887c5c5e64a4b31108733bd79ca9b2496d987 (`codec/`), plus `ALACMagicCookieDescription.txt`.
Each source file carries Apple's Apache License 2.0 header (the same licence as sosumi, see
the repository's LICENSE). The package's APPLE_LICENSE.txt (APSL) covers none of these files
and is not copied.

`ref/alac/` follows these files: `rice.zig` is `dyn_decomp` (ag_dec.c), `predictor.zig` is
`unpc_block` (dp_dec.c), `decoder.zig` is `ALACDecoder::Decode` with the unmix and copy
routines of matrix_dec.c.
