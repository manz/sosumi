#!/bin/sh
# Builds testdata/: synthetic signals encoded to ADTS AAC-LC with ffmpeg's encoder and Apple's
# (aac_at), each decoded by the ffmpeg binary and by afconvert as references.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p testdata
T=testdata
F="ffmpeg -hide_banner -loglevel error -y"

$F -f lavfi -i "sine=f=1000:sample_rate=44100:d=6,volume=0.5" -ac 2 $T/tone.wav
$F -f lavfi -i "aevalsrc='0.4*sin(2*PI*(50*t+t*t*1700))|0.4*sin(2*PI*(80*t+t*t*1500)+1)':s=44100:d=6" $T/sweep.wav
$F -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=44100:d=6" -ac 2 $T/pink.wav
# decaying clicks every 0.37 s over a quiet chord: forces short windows
$F -f lavfi -i "aevalsrc='0.1*(sin(2*PI*220*t)+sin(2*PI*277*t)+sin(2*PI*330*t))+0.8*exp(-60*mod(t,0.37))*sin(2*PI*1800*t)|0.1*(sin(2*PI*220*t)+sin(2*PI*330*t))+0.8*exp(-60*mod(t+0.1,0.37))*sin(2*PI*2400*t)':s=44100:d=6" $T/clicks.wav
$F -f lavfi -i "sine=f=440:sample_rate=44100:d=6,volume=0.5" -ac 1 $T/mono.wav

for s in tone sweep pink clicks mono; do
  for enc in aac aac_at; do
    o=$T/$s.$enc
    $F -i $T/$s.wav -c:a $enc -b:a 128k -f adts $o.aac
    $F -i $o.aac -f s16le $o.ffmpeg.s16
    afconvert -f WAVE -d LEI16 $o.aac $o.apple.wav
    python3 -I tools/compare/wavdata.py $o.apple.wav $o.apple.s16
  done
done

# one coding tool at a time, ffmpeg's encoder: plain has PNS, intensity, M/S and TNS all off
OFF="-aac_pns 0 -aac_is 0 -aac_ms 0 -aac_tns 0"
for s in sweep clicks pink; do
  for v in plain pns is ms tns; do
    case $v in
      plain) o="$OFF" ;;
      pns) o="-aac_pns 1 -aac_is 0 -aac_ms 0 -aac_tns 0" ;;
      is) o="-aac_pns 0 -aac_is 1 -aac_ms 0 -aac_tns 0" ;;
      ms) o="-aac_pns 0 -aac_is 0 -aac_ms 1 -aac_tns 0" ;;
      tns) o="-aac_pns 0 -aac_is 0 -aac_ms 0 -aac_tns 1" ;;
    esac
    b=$T/$s.ff_$v
    $F -i $T/$s.wav -c:a aac $o -b:a 128k -f adts $b.aac
    $F -i $b.aac -f s16le $b.ffmpeg.s16
  done
done

# MP3 (LAME): CBR joint stereo, VBR, mono, MPEG-2 and MPEG-2.5 rates
mp3() { # name source extra-args
  $F -i $T/$2.wav $3 -c:a libmp3lame $T/$1.mp3
  $F -i $T/$1.mp3 -f s16le $T/$1.mp3.ffmpeg.s16
  afconvert -f WAVE -d LEI16 $T/$1.mp3 $T/$1.mp3.apple.wav
  python3 -I tools/compare/wavdata.py $T/$1.mp3.apple.wav $T/$1.mp3.apple.s16
}
for s in tone sweep pink clicks mono; do mp3 $s.cbr $s "-b:a 128k"; done
mp3 clicks.vbr clicks "-q:a 2"
mp3 sweep.m2 sweep "-ar 22050 -b:a 64k"
mp3 clicks.m2 clicks "-ar 24000 -b:a 64k"
mp3 sweep.m25 sweep "-ar 11025 -b:a 32k"
mp3 clicks.m25_8k clicks "-ar 8000 -b:a 24k"
