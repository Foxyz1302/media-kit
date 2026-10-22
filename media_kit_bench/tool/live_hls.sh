#!/usr/bin/env bash
# A real live HLS stream for the liveHls check (media-kit#1445): encoded in real time into a sliding
# 5-segment window without EXT-X-ENDLIST, so it is not seekable. Keep it running during the checks.
# Usage: live_hls.sh <clips-dir> [seconds]
set -euo pipefail
OUT=${1:?usage: live_hls.sh <clips-dir> [seconds]}; cd "$OUT"
rm -f live.m3u8 live_*.ts
exec ffmpeg -hide_banner -loglevel error -re -f lavfi -i 'testsrc2=size=1280x720:rate=30' -f lavfi -i anullsrc=r=48000:cl=stereo \
  -t "${2:-600}" -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 32k \
  -f hls -hls_time 2 -hls_list_size 5 -hls_flags delete_segments+omit_endlist -hls_segment_filename 'live_%05d.ts' live.m3u8
