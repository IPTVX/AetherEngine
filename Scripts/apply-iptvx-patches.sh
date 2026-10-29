#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$#" -ne 1 || ( "$mode" != "--check" && "$mode" != "--apply" ) ]]; then
    echo "Usage: bash Scripts/apply-iptvx-patches.sh --check|--apply" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
patch_name="Patches/IPTVX/live-audio-delay-without-dvr.patch"
patch_path="$repo_root/$patch_name"

if [[ ! -s "$patch_path" ]]; then
    echo "Missing maintained patch: $patch_name. Restore or port it before publishing." >&2
    exit 1
fi

if git -C "$repo_root" apply --reverse --check "$patch_path" 2>/dev/null; then
    echo "Applied: IPTVX-LIVE-AUDIO-DELAY"
    exit 0
fi

if ! git -C "$repo_root" apply --check "$patch_path"; then
    echo "Port required: IPTVX-LIVE-AUDIO-DELAY conflicts with this core. Read docs/iptvx-fork-maintenance.md." >&2
    exit 1
fi

if [[ "$mode" == "--check" ]]; then
    echo "Missing correction: IPTVX-LIVE-AUDIO-DELAY. Run this script with --apply, inspect and test." >&2
    exit 1
fi

git -C "$repo_root" apply "$patch_path"
echo "Applied: IPTVX-LIVE-AUDIO-DELAY. Run its behavioral regressions before publishing."
