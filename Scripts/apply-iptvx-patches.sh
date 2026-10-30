#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$#" -ne 1 || ( "$mode" != "--check" && "$mode" != "--apply" ) ]]; then
    echo "Usage: bash Scripts/apply-iptvx-patches.sh --check|--apply" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
exec python3 "$script_dir/iptvx-patch-stack.py" "$mode" "$repo_root"
