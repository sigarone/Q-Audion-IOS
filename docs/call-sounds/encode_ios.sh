#!/bin/sh
# Encodes the generated call sounds (gen_call_sounds.py output) into the CAF files bundled by the iOS app.
#   usage: encode_ios.sh <dir with the WAV files> <output dir>
# All files are IMA4 (adpcm_ima_qt) in a CAF container, mono:
#   qa_ring_<id>.caf   28 s ringtone for CallKit (ringtoneSound), 22.05 kHz
#   qa_loop_<id>.caf   loop unit for the in-app ring, 22.05 kHz
#   qa_cue_<name>.caf  call cues, 32 kHz
# IMA4 is used for the loops too: unlike AAC it adds no priming or padding frames, so a loop stays seamless.
set -eu
src="${1:?source dir}"; out="${2:?output dir}"
mkdir -p "$out"
enc() { ffmpeg -nostdin -loglevel error -y -i "$1" -ac 1 -ar "$2" -c:a adpcm_ima_qt -f caf "$3"; }
for id in vetro impulso arpeggio calore digitale legno duetto; do
  enc "$src/ringtone_${id}_28s.wav"  22050 "$out/qa_ring_${id}.caf"
  enc "$src/ringtone_${id}_loop.wav" 22050 "$out/qa_loop_${id}.caf"
done
for name in connecting ringback key_exchange connected ended busy dialing_tick; do
  enc "$src/cue_${name}.wav" 32000 "$out/qa_cue_${name}.caf"
done
