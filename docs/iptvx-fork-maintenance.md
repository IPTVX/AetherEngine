# IPTVX maintained fork corrections

This registry is mandatory input to every IPTVX AetherEngine upstream integration
and fork-tag publication. A newer upstream version does not implicitly replace a
local behavioral correction. Merge the complete requested release, then inspect
and port the affected core contracts before applying or retiring a patch.

## Apply and verify on every upstream tag

Run from the fork root:

```sh
bash Scripts/apply-iptvx-patches.sh --check
```

An already-applied patch is accepted without duplicate edits. If a patch is
missing and applies cleanly, apply it explicitly and inspect the result:

```sh
bash Scripts/apply-iptvx-patches.sh --apply
git diff --check
```

Apply corrections in the isolated fork checkout before tag publication. Do not
modify a host app's SwiftPM cache or apply patches during client builds.

A conflict is a required porting decision, not permission to skip the patch.
Read the changed upstream implementation, preserve its new behavior, port this
correction to the new boundaries, update the patch snapshot and execute the
behavioral regressions before publishing. The snapshot contains code and tests;
it deliberately excludes this guide, the apply script and itself.

A successful patch check proves source application only. Validate actual delivered
audio, lifecycle and transport behavior through the relevant FlowDeck tests and
builds. Preserve iOS/tvOS 16; no new dependency binaries or deployment-floor
increase are implied by this correction.

## IPTVX-LIVE-AUDIO-DELAY — active

Baseline: upstream `7.51.0`, IPTVX fork `7.51.0-iptvx` at
`218c922adc1043154b16c161d41eee4fa786bf73`.
First delivery: `7.51.0-iptvx.1`.

### Contract to preserve

A runtime audio-delay change during Live loopback playback without DVR must reach
the active media pipeline. Merely storing a requested value in LoadOptions or on
the session is insufficient: the producer and muxer must use the correction.
The correction rejoins the current Live edge with a new producer and can briefly
rebuffer. It preserves play/pause intent; without DVR it cannot preserve the old
paused picture's source position.

Preserve these properties:

- Positive, negative and reset-to-zero offsets reach delivered audio.
- DVR stays disabled and host seek remains unavailable.
- The correction preserves the latest play/pause intent, track selection and
  request-header identity. It must not start a second concurrent origin connection
  while the previous source reader is tearing down.
- Rapid changes converge on the latest value; stop, source replacement and late
  teardown completions cannot revive or mutate a retired session.
- VOD correction and software audio retiming keep their existing behavior;
  remote-HLS bypass remains explicitly unsupported.
- Keep the existing bounded delay range. Enlarging it requires separate timestamp,
  buffering, latency and memory validation; it is not part of applying this patch.

### Porting boundaries

Inspect `AetherEngine+AudioDelay.swift`, the session-preserving reload/load path,
source teardown ownership, `HLSSegmentProducer` and `MP4SegmentMuxer`. The original
failure is the combination of a Live-without-DVR re-anchor refusal and an immutable
producer offset. Updating only the parent session's value does not update the
producer already serving the viewer.

Patch snapshot:
[`Patches/IPTVX/live-audio-delay-without-dvr.patch`](../Patches/IPTVX/live-audio-delay-without-dvr.patch).

The patch's regression tests and the existing AE#464 audio-delay suites are the
verification boundary. Run them on the affected native and software routes,
including actual runtime setter calls; a pure policy test or the requested-value
getter does not prove that audio is delivered with the correction.

`LiveAudioDelayTests` covers delivered fMP4 timestamps for both signs and zero,
changes during a held source teardown, latest transport intent, stop and source
replacement, and HLS auto-ingest with rotated request headers and User-Agent.
Run this suite on the native macOS loopback route through the repository's
FlowDeck validation harness. Keep VOD loopback and software runtime-setter
regressions in the verification matrix as separate checks.

Initial validation used synthetic H.264/AAC media on the native macOS pipeline,
including actual fMP4 packet timestamps. The complete `LiveAudioDelayTests` suite
passed five tests (six argument cases), with no failures or skips.
HLS/refusal and six related AE#464 policy
suites passed 20 tests; actual VOD loopback and software setter checks passed two
tests. iOS and tvOS builds passed with the existing OS16 floors. The check/apply
script was verified on the uncorrected baseline, then repeated to prove
idempotence and byte-identical corrected sources. These checks do not establish
physical-device lip-sync or a guaranteed rejoin duration for every Live origin.

### Retirement condition

Keep this correction active unless an upstream core change implements the same
contract. To retire it, identify the first upstream tag and commit supplying that
behavior, run the regressions without the local patch, and record the resulting
source and runtime evidence here. Remove the retired correction from the active
apply/check script and retire its snapshot in the same change. Retain the tests
or equivalent behavior coverage.
A changed file, passing merge, renamed API or silently accepted delay value is not
an equivalence proof.
