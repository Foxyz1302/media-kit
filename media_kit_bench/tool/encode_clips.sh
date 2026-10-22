#!/usr/bin/env bash
set -euo pipefail
OUT=${1:?usage: encode_clips.sh <output-dir>}; mkdir -p "$OUT"; cd "$OUT"
SRC1440='testsrc2=size=2560x1440:rate=60,noise=alls=12:allf=t+u,format=yuv420p'
SRC1080='testsrc2=size=1920x1080:rate=60,noise=alls=12:allf=t+u,format=yuv420p'
enc() { local name=$1; shift; echo "[$(date +%T)] start $name"; ffmpeg -hide_banner -loglevel error -y "$@" "$name"; echo "[$(date +%T)] done $name"; }
enc h264_1080p60.mp4 -f lavfi -i "$SRC1080" -t 20 -c:v libx264 -preset veryfast -profile:v high -b:v 12M -maxrate 12M -bufsize 24M -g 120 -movflags +faststart
enc h264_1440p60.mp4 -f lavfi -i "$SRC1440" -t 20 -c:v libx264 -preset veryfast -profile:v high -b:v 25M -maxrate 25M -bufsize 50M -g 120 -movflags +faststart
enc hevc_1440p60.mp4 -f lavfi -i "$SRC1440" -t 20 -c:v libx265 -preset fast -b:v 15M -x265-params "vbv-maxrate=15000:vbv-bufsize=30000:keyint=120:log-level=error" -tag:v hvc1 -movflags +faststart
enc vp9_1440p60.webm -f lavfi -i "$SRC1440" -t 20 -c:v libvpx-vp9 -profile:v 0 -b:v 15M -maxrate 15M -bufsize 30M -deadline good -cpu-used 5 -row-mt 1 -tile-columns 2 -threads 12 -g 120
enc av1_1440p60.mp4 -f lavfi -i "$SRC1440" -t 20 -c:v libsvtav1 -preset 10 -b:v 12M -g 120 -movflags +faststart
echo "[$(date +%T)] ALL DONE"
