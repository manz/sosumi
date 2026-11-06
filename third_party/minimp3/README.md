# minimp3

From https://github.com/lieff/minimp3 at ea99364f61c14656440e8d77e9c233ccf3124633, unmodified.
CC0 1.0 (`LICENSE`).

Used by `tools/mp3tables/gen.py`, which rebuilds the Layer III Huffman tables in canonical form
from `tabs`, `tabindex`, `tab32` and `tab33` by running minimp3's tree walk on every codeword.
The scale factor band widths, the partitions of MPEG-2 scale factors and the stereo logic in
`ref/mp3/` are taken from this file.
