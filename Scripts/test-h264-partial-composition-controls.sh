#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-partial-controls.XXXXXX")
trap 'rm -f "$TASK_TMP/healthy.mp4" "$TASK_TMP/partial.mp4" "$TASK_TMP/middle.mp4"; rmdir "$TASK_TMP"' EXIT
bash "$TASK_ROOT/Scripts/test-h264-partial-composition.sh"
# Reproducible public solid-colour/tone fixture. Keep an 8-second valid head, then remove
# only composition offsets; never duplicate any real source media into a test artifact.
ffmpeg -hide_banner -loglevel error -n \
  -f lavfi -i 'color=c=blue:s=96x64:r=30:d=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=24' \
  -c:v libx264 -preset fast -pix_fmt yuv420p -g 30 -bf 2 \
  -x264-params 'scenecut=0:b-adapt=0' -c:a aac -video_track_timescale 90000 \
  -metadata comment='Aether synthetic timestamp fixture' -movflags +faststart "$TASK_TMP/healthy.mp4"
ruby "$TASK_ROOT/Scripts/tests/make-partial-ctts-fixture.rb" "$TASK_TMP/healthy.mp4" "$TASK_TMP/partial.mp4"
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" \
  "$TASK_TMP/partial.mp4" 0 10 0 6 22
ruby "$TASK_ROOT/Scripts/tests/make-partial-ctts-fixture.rb" "$TASK_TMP/healthy.mp4" "$TASK_TMP/middle.mp4" middle
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" \
  "$TASK_TMP/middle.mp4" 0 10 0 6 14 22
