#!/bin/bash
# Checks DiscordSPS.rewriteVUI (Sources/Discord/DiscordSPS.swift) against ffmpeg's own H.264 parser. Takes the first SPS of real H.264 (libx264, which writes a VUI, and Apple's
# VideoToolbox encoder, which is what the phone uses and writes none), rewrites it, and asks ffmpeg to decode the result and to print the SPS it reads: the picture size and
# profile must be unchanged and max_num_reorder_frames must be 0. Needs ffmpeg; without it the test says so and passes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v ffmpeg >/dev/null || { echo "ffmpeg not installed: DiscordSPS test skipped"; exit 0; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
swiftc -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordSPS.swift" "$HERE/main.swift" 2>&1 | grep -E "error" || true
fails=0
check() {   # name, ffmpeg encoder args
  local name="$1"; shift
  ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 6 "$@" -f h264 "$OUT/$name.h264"
  "$OUT/t" "$OUT/$name.h264" "$OUT/$name.new.h264"
  ffmpeg -v error -i "$OUT/$name.new.h264" -f null - 2>"$OUT/$name.err" || true
  if [ -s "$OUT/$name.err" ]; then echo "FAIL $name: ffmpeg complains: $(head -2 "$OUT/$name.err")"; fails=$((fails+1)); return; fi
  local info; info=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile,width,height,has_b_frames -of csv=p=0 "$OUT/$name.new.h264")
  local orig; orig=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile,width,height -of csv=p=0 "$OUT/$name.h264")
  local reorder; reorder=$(ffmpeg -v trace -i "$OUT/$name.new.h264" -c copy -bsf:v trace_headers -f null - 2>&1 | grep -m1 "max_num_reorder_frames" | grep -o "= *[0-9]*" | tr -d '= ' || true)
  if [ "${reorder:-x}" != "0" ]; then echo "FAIL $name: max_num_reorder_frames is '${reorder:-missing}' ($info)"; fails=$((fails+1)); return; fi
  case "$info" in "$orig"*) echo "ok   $name: still $orig, decodes, max_num_reorder_frames = 0";; *) echo "FAIL $name: stream info changed: $orig -> $info"; fails=$((fails+1));; esac
}
check x264 -c:v libx264 -profile:v baseline -x264-params keyint=30
check x264-main -c:v libx264 -profile:v main -x264-params keyint=30:bframes=2
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then check videotoolbox -c:v h264_videotoolbox -profile:v baseline -realtime 1; fi
# The optional colour description (BT.709, limited range) must be read back as such.
colourcheck() {
  local name="colour-$1"; shift
  ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 6 "$@" -f h264 "$OUT/$name.h264"
  SPS_COLOUR=1 "$OUT/t" "$OUT/$name.h264" "$OUT/$name.new.h264" >/dev/null
  ffmpeg -v error -i "$OUT/$name.new.h264" -f null - 2>"$OUT/$name.err" || true
  if [ -s "$OUT/$name.err" ]; then echo "FAIL $name: ffmpeg complains: $(head -2 "$OUT/$name.err")"; fails=$((fails+1)); return; fi
  local t; t=$(ffmpeg -v trace -i "$OUT/$name.new.h264" -c copy -bsf:v trace_headers -f null - 2>&1 | grep -E "colour_primaries|transfer_characteristics|matrix_coefficients|video_full_range_flag|max_num_reorder_frames" | grep -o "= *[0-9]*" | tr -d '= ' | head -5 | tr '\n' ' ')      # the trace prints each field twice
  if [ "$t" = "0 1 1 1 0 " ]; then echo "ok   $name: BT.709 limited range read back, reorder 0"; else echo "FAIL $name: colour fields read back as '$t' (want: range 0, primaries 1, transfer 1, matrix 1, reorder 0)"; fails=$((fails+1)); fi
}
colourcheck x264 -c:v libx264 -profile:v baseline -x264-params keyint=30
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then colourcheck videotoolbox -c:v h264_videotoolbox -profile:v baseline -realtime 1; fi
[ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
