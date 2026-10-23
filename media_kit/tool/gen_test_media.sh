#!/usr/bin/env bash
# Usage: tool/gen_test_media.sh <output-directory>
#
# Synthetic inputs, single-threaded encoders and bitexact muxing: one ffmpeg
# build always writes the same bytes.

set -euo pipefail

out=${1:?usage: gen_test_media.sh <output-directory>}
mkdir -p "$out"
work=$(mktemp -d "$out/.work.XXXXXX")
trap 'rm -rf "$work"' EXIT

ff=(ffmpeg -hide_banner -nostdin -loglevel error -y)
exact=(-map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact)
aac=(-c:a aac -b:a 96k -ac 2)
x264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -threads 1 -x264-params log-level=error)

encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)

has_encoder() {
  grep -qE "^ [A-Z.]{6} $1 " <<<"$encoders"
}

video() {
  echo "testsrc2=size=$1:rate=$2:duration=$3"
}

sine() {
  echo "sine=frequency=$1:sample_rate=48000:duration=$2"
}

"${ff[@]}" -f lavfi -i "$(video 320x240 30 6)" -f lavfi -i "$(sine 440 6)" \
  "${x264[@]}" -g 30 "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/h264.mp4"

"${ff[@]}" -f lavfi -i "$(video 320x240 30 6)" -f lavfi -i "$(sine 440 6)" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 \
  -x265-params pools=none:frame-threads=1:log-level=error:keyint=30:min-keyint=30 \
  "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/hevc.mp4"

"${ff[@]}" -f lavfi -i "$(video 320x240 30 6)" -f lavfi -i "$(sine 440 6)" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 0 -threads 1 \
  -b:v 300k -g 30 -pix_fmt yuv420p \
  -c:a libopus -b:a 64k -ac 2 "${exact[@]}" \
  "$work/vp9.webm"

if has_encoder libsvtav1; then
  export SVT_LOG=1
  av1=(-c:v libsvtav1 -preset 12 -g 30 -svtav1-params lp=1)
elif has_encoder libaom-av1; then
  av1=(-c:v libaom-av1 -usage realtime -cpu-used 8 -row-mt 0 -threads 1 -g 30)
elif has_encoder librav1e; then
  av1=(-c:v librav1e -speed 10 -g 30)
else
  echo "gen_test_media.sh: ffmpeg has no AV1 encoder (libsvtav1, libaom-av1 or librav1e)" >&2
  exit 1
fi
"${ff[@]}" -f lavfi -i "$(video 320x240 30 6)" -f lavfi -i "$(sine 440 6)" \
  "${av1[@]}" -pix_fmt yuv420p "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/av1.mp4"

"${ff[@]}" -f lavfi -i "$(sine 440 6)" \
  "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/audio.m4a"

cat >"$work/chapters.txt" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=One
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Two
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=6000
title=Three
EOF
cat >"$work/subtitles.srt" <<'EOF'
1
00:00:00,500 --> 00:00:02,000
First subtitle

2
00:00:02,500 --> 00:00:04,000
Second subtitle

3
00:00:04,500 --> 00:00:05,500
Third subtitle
EOF
"${ff[@]}" -f lavfi -i "$(video 320x240 30 6)" \
  -f lavfi -i "$(sine 440 6)" -f lavfi -i "$(sine 880 6)" \
  -i "$work/subtitles.srt" -f ffmetadata -i "$work/chapters.txt" \
  -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
  "${x264[@]}" -g 30 "${aac[@]}" -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng \
  -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
  "$work/chapters.mkv"
rm "$work/chapters.txt" "$work/subtitles.srt"

# Keyframes at 0 and 12 s only, cut at 4 s without re-encoding: the first 8 s of
# video are non-keyframes whose references are gone (#1417).
"${ff[@]}" -f lavfi -i "$(video 320x240 30 20)" -f lavfi -i "$(sine 440 20)" \
  "${x264[@]}" -bf 0 -g 1000 -keyint_min 1000 -sc_threshold 0 \
  -force_key_frames 0,12 "${aac[@]}" "${exact[@]}" \
  "$work/late_keyframe_source.mp4"
"${ff[@]}" -i "$work/late_keyframe_source.mp4" -ss 4 -t 12 -c copy -copyinkf \
  -avoid_negative_ts make_zero "${exact[@]}" -movflags +faststart \
  "$work/late_keyframe.mp4"
rm "$work/late_keyframe_source.mp4"
first_key=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,flags \
  -of csv=p=0 "$work/late_keyframe.mp4" | awk -F, '$2 ~ /K/ && !found { print $1; found = 1 }')
if ! awk -v t="$first_key" 'BEGIN { exit !(t > 7.9 && t < 8.1) }'; then
  echo "gen_test_media.sh: late_keyframe.mp4 has its first keyframe at '$first_key', not 8 s" >&2
  exit 1
fi

size=$(wc -c <"$work/h264.mp4")
head -c $((size * 45 / 100)) "$work/h264.mp4" >"$work/truncated.mp4"

"${ff[@]}" -f lavfi -i "anoisesrc=color=white:sample_rate=48000:seed=1302:duration=1" \
  -f s16le -ac 1 "$work/noise.raw"
head -c 65536 "$work/noise.raw" >"$work/corrupt.mp4"
rm "$work/noise.raw"

"${ff[@]}" -f lavfi -i "$(video 640x360 30 10)" -f lavfi -i "$(sine 440 10)" \
  "${x264[@]}" -b:v 700k -maxrate 700k -bufsize 1400k -g 30 \
  "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/stream.mp4"

"${ff[@]}" -f lavfi -i "$(video 1280x720 60 4)" -f lavfi -i "$(sine 440 4)" \
  "${x264[@]}" -g 60 "${aac[@]}" "${exact[@]}" -movflags +faststart \
  "$work/bench_720p60.mp4"

mv "$work"/* "$out/"
