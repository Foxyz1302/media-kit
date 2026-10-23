#!/usr/bin/env bash
# Clips for the BENCH_CHECKS regression checks, written next to the performance clips.
# Usage: encode_check_clips.sh <clips-dir>
set -euo pipefail
OUT=${1:?usage: encode_check_clips.sh <clips-dir>}; mkdir -p "$OUT"; cd "$OUT"
A=(-f lavfi -i anullsrc=r=48000:cl=stereo)
SRC='testsrc2=size=1280x720:rate=30'
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# Media(start: 5 min) and seek-right-after-open.
ff -f lavfi -i "$SRC" "${A[@]}" -t 360 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 1M -g 60 -c:a aac -b:a 32k -shortest -movflags +faststart long_720p30_6min.mp4

# First keyframe 8 s in, audio from 0 (media-kit#1417): cut a 10 s-GOP clip at 2 s, keeping the initial non-keyframes.
ff -f lavfi -i "$SRC" "${A[@]}" -t 20 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 2M -g 300 -keyint_min 300 -sc_threshold 0 -c:a aac -b:a 32k -shortest lk_src.mp4
ff -i lk_src.mp4 -ss 2 -c copy -copyinkf -movflags +faststart late_keyframe.mp4
rm lk_src.mp4

# Harder variant: MPEG-TS cut mid-GOP at a packet boundary, so no SPS/PPS exist before the keyframe 9.4 s in.
ff -f lavfi -i "$SRC" "${A[@]}" -t 20 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 2M -g 300 -keyint_min 300 -sc_threshold 0 -c:a aac -b:a 32k -shortest -f mpegts lk_full.ts
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,pos -of csv=p=0 lk_full.ts > lk_packets.txt
POS=$(awk -F, '$1 >= 2.0 {print $2; exit}' lk_packets.txt); POS=$(( POS / 188 * 188 ))
tail -c +$((POS + 1)) lk_full.ts > late_keyframe.ts
rm lk_full.ts lk_packets.txt

# End of file -> loop / complete -> open the next item (media-kit#1453).
ff -f lavfi -i "$SRC" "${A[@]}" -t 4 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 2M -c:a aac -b:a 32k -shortest -movflags +faststart short_a_4s.mp4
ff -f lavfi -i 'testsrc=size=1280x720:rate=30' "${A[@]}" -t 4 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 2M -c:a aac -b:a 32k -shortest -movflags +faststart short_b_4s.mp4

# HLS VOD with a start position (media-kit#997): 120 s in 4 s segments, with EXT-X-ENDLIST.
ff -f lavfi -i "$SRC" "${A[@]}" -t 120 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -b:v 2M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 32k -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_filename 'vod_%03d.ts' vod.m3u8
echo "check clips done"
