#!/bin/sh
# Regenerates ref/tables/huffman.zig from the vendored OpenCORE decoders.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
src="$root/third_party/opencore-aac"
out=$(mktemp -d)
c++ -std=c++11 -O1 -w -I"$root/tools/huffdump/inc" -I"$src" -include huffman.h \
    "$root/tools/huffdump/dump.cpp" "$src/decode_huff_cw_binary.cpp" "$src/hcbtables_binary.cpp" \
    -o "$out/dump"
"$out/dump" > "$out/codebooks.txt"
python3 -I "$root/tools/huffdump/to_zig.py" "$out/codebooks.txt" > "$root/ref/tables/huffman.zig"
rm -rf "$out"
