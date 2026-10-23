#!/usr/bin/env bash
# 3840x2160 companions to encode_clips.sh, one clip at a time with fast presets.
# Usage: encode_clips_4k.sh <output-dir> [--av1]   (--av1 adds a software-only AV1 4K30 clip)
set -euo pipefail
OUT=${1:?usage: encode_clips_4k.sh <output-dir> [--av1]}; mkdir -p "$OUT"; cd "$OUT"
SRC60='testsrc2=size=3840x2160:rate=60,noise=alls=12:allf=t+u,format=yuv420p'
SRC30='testsrc2=size=3840x2160:rate=30,noise=alls=12:allf=t+u,format=yuv420p'
enc() { local name=$1; shift; echo "[$(date +%T)] start $name"; ffmpeg -hide_banner -loglevel error -y "$@" "$name"; echo "[$(date +%T)] done $name"; }
enc h264_2160p60.mp4 -f lavfi -i "$SRC60" -t 20 -c:v libx264 -preset veryfast -profile:v high -b:v 45M -maxrate 45M -bufsize 90M -g 120 -movflags +faststart
enc h264_2160p30.mp4 -f lavfi -i "$SRC30" -t 20 -c:v libx264 -preset veryfast -profile:v high -b:v 30M -maxrate 30M -bufsize 60M -g 60 -movflags +faststart
enc hevc_2160p60.mp4 -f lavfi -i "$SRC60" -t 20 -c:v libx265 -preset ultrafast -b:v 25M -x265-params "vbv-maxrate=25000:vbv-bufsize=50000:keyint=120:log-level=error" -tag:v hvc1 -movflags +faststart
enc vp9_2160p60.webm -f lavfi -i "$SRC60" -t 20 -c:v libvpx-vp9 -profile:v 0 -b:v 25M -maxrate 25M -bufsize 50M -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 3 -threads 16 -g 120
if [ "${2:-}" = "--av1" ]; then
  enc av1_2160p30.mp4 -f lavfi -i "$SRC30" -t 20 -c:v libsvtav1 -preset 12 -b:v 15M -g 60 -movflags +faststart
fi
echo "[$(date +%T)] ALL DONE"
