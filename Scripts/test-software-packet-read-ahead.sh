#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-packet-read-ahead.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation concurrency/data test; no macOS/iOS application target is built.
xcrun swiftc \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareStoredPacket.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareVideoPacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketDiskFIFO.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketReadAhead.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwarePacketReadAheadStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
