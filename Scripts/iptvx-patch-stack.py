#!/usr/bin/env python3
"""Check ordered fork corrections beneath overlapping successors without editing sources."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# Oldest first: a successor is authored against the complete preceding stack.
PATCHES = [
    ("IPTVX-LIVE-AUDIO-DELAY", "Patches/IPTVX/live-audio-delay-without-dvr.patch"),
    ("IPTVX-DIRECT-LIVE-AUDIO-READ-AHEAD", "Patches/IPTVX/direct-live-audio-read-ahead.patch"),
]


class PatchFailure(Exception):
    """A missing snapshot or conflicting source needs an explicit maintenance decision."""


def git(root, *arguments):
    """Run Git without global newline conversion or external diff drivers."""
    return subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-c", "core.safecrlf=false",
         "-C", str(root), *arguments],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def require_success(result, context):
    """Keep Git's actionable failure detail instead of accepting partial application."""
    if result.returncode:
        raise PatchFailure(context + "\n" + result.stderr.decode(errors="replace").strip())
    return result.stdout


def patch_files(root, patches):
    """Collect only touched paths, including absent files a patch will create."""
    paths = set()
    for identifier, relative in patches:
        patch = root / relative
        if not patch.is_file() or not patch.stat().st_size:
            raise PatchFailure(f"Missing maintained patch: {relative} ({identifier}). Restore or port it before publishing.")
        output = require_success(
            git(root, "apply", "--numstat", "-z", str(patch)),
            f"Invalid maintained patch: {relative} ({identifier}).",
        )
        for record in output.split(b"\0"):
            if not record:
                continue
            fields = record.split(b"\t", 2)
            if len(fields) != 3 or not fields[2]:
                raise PatchFailure(f"Unsupported path record in {relative}; port the snapshot explicitly.")
            path = Path(fields[2].decode())
            if path.is_absolute() or ".." in path.parts or path.parts[0] == ".git":
                raise PatchFailure(f"Unsafe maintained patch path: {path}.")
            paths.add(path)
    return paths


def apply_stack(root, patches, apply):
    """Preflight the complete stack in scratch, then apply one atomic net diff if requested.

    Reverse peeling deliberately does not require a missing successor to apply yet:
    its predecessor may also be absent. Forward replay is the conflict gate.
    The host index and unrelated dirty/untracked files are never staged or copied.
    """
    paths = patch_files(root, patches)
    with tempfile.TemporaryDirectory(prefix="iptvx-patch-stack-") as temporary:
        scratch = Path(temporary)
        require_success(git(scratch, "init", "--quiet"), "Cannot create patch validation scratch repository.")
        for path in paths:
            source = root / path
            if source.exists() or source.is_symlink():
                destination = scratch / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination, follow_symlinks=False)
        require_success(git(scratch, "add", "--force", "."), "Cannot snapshot current correction paths.")
        applied = [False] * len(patches)
        for index in reversed(range(len(patches))):
            patch = str(root / patches[index][1])
            if git(scratch, "apply", "--reverse", "--check", patch).returncode == 0:
                require_success(git(scratch, "apply", "--reverse", patch), "Cannot peel maintained successor.")
                applied[index] = True
        unpeeled = ", ".join(identifier for index, (identifier, _) in enumerate(patches) if not applied[index])
        for identifier, relative in patches:
            patch = str(root / relative)
            context = (f"Port required: {identifier} conflicts with this core. Read docs/iptvx-fork-maintenance.md.\n"
                       f"Unpeeled snapshots (missing or drifted): {unpeeled or 'none'}. "
                       "A partial successor can prevent replaying its predecessor.")
            require_success(git(scratch, "apply", "--check", patch), context)
            require_success(git(scratch, "apply", patch), context)
        missing = [identifier for index, (identifier, _) in enumerate(patches) if not applied[index]]
        if missing and not apply:
            raise PatchFailure("Missing correction: " + ", ".join(missing) + ". Run this script with --apply, inspect and test.")
        if missing:
            # Intent-to-add only new paths: staging deletions here would hide them
            # from the net diff against the original snapshot.
            untracked = require_success(git(scratch, "ls-files", "--others", "-z"), "Cannot inspect new correction files.")
            new_paths = [path.decode() for path in untracked.split(b"\0") if path]
            if new_paths:
                require_success(git(scratch, "add", "--intent-to-add", "--force", "--", *new_paths), "Cannot inspect new correction files.")
            difference = require_success(git(scratch, "diff", "--no-ext-diff", "--binary", "--full-index"), "Cannot prepare correction diff.")
            if not difference:
                raise PatchFailure("Correction state is ambiguous: missing patches produced no net change. Port the snapshots explicitly.")
            delta = scratch / "validated-stack.patch"
            delta.write_bytes(difference)
            require_success(git(root, "apply", "--check", str(delta)), "Source changed after patch preflight; inspect and rerun.")
            require_success(git(root, "apply", str(delta)), "Cannot apply validated correction stack; inspect and rerun.")
        for identifier, _ in patches:
            print(f"Applied: {identifier}")
        if missing:
            print("Run the registry's behavioral regressions before publishing.")


def main():
    """Expose only the documented check/apply entry point and actionable failures."""
    if len(sys.argv) != 3 or sys.argv[1] not in ("--check", "--apply"):
        print("Usage: iptvx-patch-stack.py --check|--apply REPOSITORY", file=sys.stderr)
        return 2
    try:
        apply_stack(Path(sys.argv[2]).resolve(), PATCHES, sys.argv[1] == "--apply")
    except (PatchFailure, OSError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
