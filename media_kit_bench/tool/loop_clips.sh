#!/usr/bin/env bash
# 40 s copies (<name>_40s.<ext>) of the 20 s clips, by stream copy, so that a run's plain, overlay and
# animated windows (9 + 5 + 6 s after startup) all end before the end of the file.
# Usage: loop_clips.sh <clips-dir> <clip>...
set -euo pipefail
DIR=${1:?usage: loop_clips.sh <clips-dir> <clip>...}; shift
for c in "$@"; do
  out="${c%.*}_40s.${c##*.}"
  extra=()
  [ "${c##*.}" = mp4 ] && extra=(-movflags +faststart)
  ffmpeg -hide_banner -loglevel error -y -stream_loop 1 -i "$DIR/$c" -c copy "${extra[@]}" "$DIR/$out"
  echo "$out"
done
