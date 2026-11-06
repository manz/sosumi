#!/bin/sh
# Builds testdata/alac/: ALAC from Apple's encoder (afconvert) and ffmpeg's, decoded by both as
# raw little-endian PCM at the stream's depth. Needs testdata/*.wav from tools/compare/gen.sh.
set -eu
cd "$(dirname "$0")/../.."
T=testdata
A=$T/alac
mkdir -p $A
F="ffmpeg -hide_banner -loglevel error -y"

# extra sources: 24-bit at 48 and 96 kHz, white noise (incompressible: verbatim packets), 5.1
$F -i $T/sweep.wav -ar 48000 -c:a pcm_s24le $A/sweep24.wav
$F -i $T/clicks.wav -ar 96000 -c:a pcm_s24le $A/clicks24_96k.wav
$F -f lavfi -i "anoisesrc=color=white:amplitude=1:sample_rate=44100:d=4" -ac 2 $A/white.wav
$F -f lavfi -i "anoisesrc=color=white:amplitude=1:sample_rate=48000:d=4" -ac 2 -c:a pcm_s24le $A/white24.wav
$F -f lavfi -i "aevalsrc='0.3*sin(2*PI*220*t)|0.3*sin(2*PI*330*t)|0.3*sin(2*PI*440*t)|0.5*sin(2*PI*40*t)|0.2*sin(2*PI*550*t)|0.2*sin(2*PI*660*t)':s=48000:d=4:channel_layout=5.1" $A/surround.wav
cp $T/tone.wav $T/pink.wav $T/clicks.wav $T/mono.wav $A/

refs() { # name depth
  case $2 in 16) fmt=s16le; ai=LEI16;; 24) fmt=s24le; ai=LEI24;; esac
  $F -i $A/$1.m4a -f $fmt $A/$1.ffmpeg.raw
  afconvert -f WAVE -d $ai $A/$1.m4a $A/$1.apple.wav
  python3 -I tools/compare/wavdata.py $A/$1.apple.wav $A/$1.apple.raw
}
for s in tone pink clicks mono white surround; do
  afconvert -f m4af -d alac $A/$s.wav $A/$s.at.m4a; refs $s.at 16
  $F -i $A/$s.wav -c:a alac $A/$s.ff.m4a; refs $s.ff 16
done
for s in sweep24 clicks24_96k white24; do
  afconvert -f m4af -d alac/3 $A/$s.wav $A/$s.at.m4a; refs $s.at 24
  $F -i $A/$s.wav -c:a alac -sample_fmt s32p $A/$s.ff.m4a; refs $s.ff 24
done
# ffmpeg's encoder at its extremes: no prediction (order 0..1) and the deepest (order 30)
$F -i $A/pink.wav -c:a alac -min_prediction_order 1 -max_prediction_order 1 $A/pink.o1.ff.m4a; refs pink.o1.ff 16
$F -i $A/clicks.wav -c:a alac -min_prediction_order 30 -max_prediction_order 30 $A/clicks.o30.ff.m4a; refs clicks.o30.ff 16
$F -i $A/clicks.wav -c:a alac -compression_level 0 $A/clicks.c0.ff.m4a; refs clicks.c0.ff 16
