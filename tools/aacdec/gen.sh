#!/bin/sh
# Builds testdata/aac/*.pkts: short runs of access units with the ref/dsp/aac decoder state
# before them, for x17's packet-level test. Needs testdata/*.aac from tools/compare/gen.sh.
# Each S is picked from aacdec's per-unit listing so the run hits its tool.
set -eu
cd "$(dirname "$0")/../.."
zig build
mkdir -p testdata/aac
run() { # fixture from count
  zig-out/bin/aacdec testdata/$1.aac --dump=testdata/aac/$1.pkts --from=$2 --count=$3 > /dev/null
}
run tone.aac_at   0 6  # priming, long_start, eight_short, long_stop, only_long
run sweep.ff_tns 256 4  # long_start then eight_short with TNS on the left channel
run pink.ff_pns  40 4  # PNS in every unit, mid-stream rng and overlap
run pink.ff_is   40 4  # intensity in every unit
run clicks.aac_at 11 6  # only_long, long_start, eight_short, long_stop, only_long, long_start
