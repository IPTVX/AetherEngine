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

The active stack is ordered oldest first in `Scripts/iptvx-patch-stack.py`.
Each successor is authored against all preceding corrections. An already-applied
stack is accepted without duplicate edits. If a correction is missing and the
complete stack applies cleanly, apply it explicitly and inspect the result:

```sh
bash Scripts/apply-iptvx-patches.sh --apply
git diff --check
```

Apply corrections in the isolated fork checkout before tag publication. Do not
modify a host app's SwiftPM cache or apply patches during client builds.

The checker uses Git and Python 3, already used by the repository's scripts.
It copies only correction paths into a disposable scratch repository, peels
applied successors in reverse order, then replays the complete stack in forward
order. A missing successor is not required to apply until its predecessors have
been replayed. This is necessary when a new correction changes a line introduced
by the earlier audio-delay snapshot: independently reverse-checking the older
snapshot against the final tree would incorrectly report a conflict.

`--check` never changes the checkout. `--apply` preflights every correction and
applies a single validated net diff; a later conflict cannot leave an earlier
missing correction applied. The host index, unrelated files, and permissions are
preserved. Partial application, drifted contexts, malformed snapshots, and missing
patch files remain failures requiring an explicit port. Archive and remove
unrelated local instrumentation before release validation rather than weakening
context checks or adding instrumentation to a correction snapshot.

Run the maintenance script regressions without Apple tooling:

```sh
python3 -m unittest discover -s Scripts/tests -p 'test_iptvx_patch_stack.py' -v
```

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

Pre-correction baseline: upstream `7.51.0`, IPTVX fork commit
`218c922adc1043154b16c161d41eee4fa786bf73`.
Delivery: `7.51.0-iptvx`, recreated at the user's explicit request to include this
correction. The intermediate `7.51.0-iptvx.1` tag was removed.

### Complete upstream main integration — November 2, 2026

The active 45-path snapshot is ported to complete upstream main
`e1cd3d46830a04d72dbc5d61e930736bf3a1183d`, merged into published private
`287618e1828de47fd2291f7355511b5f6a73a681`. This is a source integration branch;
no Aether release tag or application remote pin is changed. The earlier direct-Live
withdrawal below remains historical: upstream PR963 now supplies the reviewed
Live implementation as part of the complete merge, rather than restoring the
withdrawn private patch.

The FFmpeg dependency now pins published `3.12.1-iptvx` at
`e27734fb855d64411003896a44e58af4ed0db730` (annotated tag object
`e5a4604fc6839fa3e6851c47be921436c87ff667`). This is the complete upstream
3.12.1 source and patch set rebuilt with the private OS16 deployment floors.
Private LibDovi/LibTrueHD pins and the audio-delay snapshot remain unchanged.

The earlier FFmpeg 3.11 binary gap is closed for its three reproduced behaviors:
AV1 hidden full-refresh keyframes, Matroska attachment skipping, and Matroska
post-error byte/generic-seek recovery. All eight unchanged regression tests pass
against both the local prepublication artifacts and the freshly resolved published
tag, with no failures or skips. The remote checkout SHA is verified; all nine
macOS framework binaries and `BUILD-INFO.txt` match the prepublication build byte
for byte. This establishes those specific behaviors, not complete upstream
runtime equivalence, missing-fixture coverage, or physical OS16 playback.

A further 60 focused shaping, reload-ownership and keyframe tests pass against
the published binaries, with zero failures or skips. The three published-binary
runs therefore pass 145 tests in total. The ten maintenance-script tests and
strict patch check/idempotent apply also pass; no test assertions changed.

The published-binary retained matrix also passes all 77 tests in nine suites,
with zero failures or skips, including the real native +/-180 fixture, software
+/-180, captured shaping during native warmup, generation ownership, ordinary
Live/background audio, exclusive direct-reader routing, and native-end recovery.
The five historical generated-fixture skips described below remain unavailable;
this update does not claim that missing coverage.

App validation against the published tag passed iOS and tvOS device-target builds
with minimum deployment 16.0. All nine embedded FFmpeg framework UUIDs on both
platforms match their new release slices; MetalFX remains `LC_LOAD_WEAK_DYLIB`.
The adapter passed 189 XCTest and four Swift Testing tests with zero failures.
No application was installed or launched. The app/harness files were restored
byte for byte to their pre-update state; app remote pins remain unchanged.

Reproduce the uncorrected baseline from published objects:

1. Check out private `287618e1828de47fd2291f7355511b5f6a73a681` in a disposable
   repository. Save its original audio-delay snapshot with `git show`, reverse
   that original snapshot, and commit only this scratch baseline.
2. Merge complete upstream `e1cd3d46830a04d72dbc5d61e930736bf3a1183d` without
   committing. Resolve compatibility-only conflicts: retain private manifest
   floors, traits and dependency pins; combine private history with upstream
   changelog/README; retain both `skipsContainerAttachments` and
   `preferAudioDescriptions` in the reload option list; place upstream display
   cadence cleanup before the existing tvOS17 availability guard.
3. Those compatibility-only files may be restored from this integration branch:
   `Package.swift`, `Package.resolved`, `README.md`, `CHANGELOG.md`, and
   `DisplayCriteriaController.swift`. In `AetherEngine+ReloadWithOptions.swift`,
   combine only the two option-list entries. Retain the OS16-safe `ProbeTestBox`
   substitutions in `UpscalingFrameHandlerTests.swift`; its assertions are unchanged.
   MetalFX imports in the two upstream upscale files also require weak linkage
   for tvOS16; keep this compatibility-only resolution outside the delay snapshot.
   No delay correction belongs in
   this baseline.
4. Copy the current snapshot and unchanged maintenance scripts into the scratch
   tree. `--check` must report the missing correction. `--apply`, `--check`, and
   a repeated `--apply` must succeed and reproduce every snapshot path exactly.

The 44 retained source/test paths remain in the active correction; the 45th is
`DirectLiveAudioDelayRoutingTests.swift`, which crosses both +/-180-second
alignment boundaries and verifies exclusive direct-reader ownership. Ordinary
Live uses upstream's independent fixed RAM budget (one oversized packet may be
admitted alone after draining); large offsets retain the compressed alignment
reader. Neither path exposes DVR. Background audio-only playback must not pause
its clock for rebuffering, including VOD; a gap is preferable to a parked-video
deadlock. Foreground large-delay policy is retained. Private delay re-anchors
request exact seeks so upstream AV1 keyframe snapping cannot move their video
position. Shaping reconciliation and upstream upscale-return settlement both
retain their generation checks; new source loads invalidate older reload work.

At source-integration commit `b79dd5eadfa9ac0dc5f7429b00542fc09072a062`,
the first focused retained matrix passed 77 tests in nine suites, including
native +/-180 with its real media fixture, software +/-180, alignment epochs,
ordinary Live/background audio, exclusive reader routing and native-end recovery.
With the then-pinned FFmpeg `3.11.0-iptvx`, the unchanged binary-gap matrix
executed eight tests: five passed and three
failed, with seven assertion issues. The failed methods cover AV1 delayed RAP
recognition, Matroska read-after-error byte reposition, and attachment skipping
(the latter tested both file and custom-reader variants). Those failures were
release blockers and were not waived; the published 3.12.1 run above now passes
them unchanged. The complete-main boundary matrix selected 198 tests: 193 passed, zero failed,
and five skipped (25 XCTest plus 173 Swift Testing, including the skips). All
retained Live delay interruption cases passed. Missing generated fixtures account
for the skips: one AE962 final-video-tail witness and four in-band parameter-set
rebuild cases (xPS/H.264). Their upstream fixture-enabled tests remain intact.
The host lacks the libx264 tool needed by the exact fixture-generation recipe.

After the weak-import correction, a focused recompilation and runtime run passed
40 tests in four suites: upscale route/load/frame handling plus two actual TCP
watchdog cases (slow-source replacement and healthy-stream preservation), with
zero failures or skips. Earlier runtime matrices preceded only these import
changes; no playback implementation changed afterward.

The maintenance gate passes all ten script tests and proves missing-patch
detection, application, idempotence and byte-identical reproduction of all 45
paths. After the documented compatibility-only resolutions, the reconstructed
baseline plus snapshot reproduces all 1,302 tracked source/test paths byte for
byte. Snapshot SHA256: `789872473be6c9795af703bdc41a5bc24b1e9ff0170f1bd52b5597c5d116f0cf`.
No checker assertions were weakened. App compilation found that ordinary
MetalFX imports produced a strong framework dependency on tvOS. Availability is
not guaranteed across supported older tvOS versions; this audit did not inspect
a tvOS16 runtime image. Both upscale imports now use `@_weakLinked`,
retaining all runtime availability guards and avoiding SwiftPM unsafe linker
flags. The device-target tvOS rebuild verified `LC_LOAD_WEAK_DYLIB` for MetalFX
in the embedded playback framework; this is binary linkage evidence, not an
OS16 physical playback test. The original source-integration validation also passed iOS and tvOS
device-target builds with minimum deployment 16.0; no app was installed or
launched. The adapter matrix passed 189 XCTest and four Swift Testing tests before
the import-only weak-link change. App/harness overrides were restored byte for
byte to the pre-integration local package configuration; no app remote pin changed.

### Historical 7.52.0 port baseline and shaping interaction

The previous snapshot was ported to complete upstream `7.52.0`
(`db35d50e5c3d5b617551ca27ec7ef4a3d4e534e3`). Its uncorrected baseline is
reproducible from published history: begin at
`218c922adc1043154b16c161d41eee4fa786bf73` (the pre-correction ancestor of
`7.51.0-iptvx`), then merge the complete `7.52.0` tag without committing.
Resolve the four baseline conflicts as follows:

- `Package.swift` / `Package.resolved`: retain the IPTVX dependency URLs and
  exact OS16-compatible LibDovi/LibTrueHD pins; upgrade FFmpegBuild to the
  complete `3.11.0-iptvx` release. Keep the upstream privacy resource and
  filter dependency changes, plus the fork deployment floors, default traits
  and library-only mobile product boundary.
- `README.md`: retain the fork platform explanation, and include upstream's
  new privacy-manifest and best-effort Xcode compatibility notes.
- `FrameExtractorCancellationTests.swift`: retain `ProbeTestBox`'s OS16-safe
  accessors while taking upstream's idle interval and early cancellation count.

For an exact reproduction after publication, those four compatibility-only
resolutions may be restored from `7.52.0-iptvx` before applying the snapshot.
They contain no audio-delay production correction. The baseline needs no
unpublished commit or orphan local ref. Apply the snapshot and repeat `--check`
and `--apply`; compare every snapshot source/test path byte for byte with the
published corrected tree. Never include this registry or the patch itself in
its code/test snapshot.

Upstream shaping does not replace the delay correction. Its compensated sample
transformer remains ahead of the existing output offset; do not add its graph
latency to compressed ordering or the renderer/muxer delay. Active shaping
intentionally chooses the PCM bridge instead of stream copy or object rendering;
shaping off retains the previous Dolby Vision/Atmos/APAC route. Finite padding
uses the actual delivered bridge codec parameters and follows graph/encoder EOF
drain, preserving channel caps and source position.

A graph change while an owned large-delay warmup runs must interrupt that owned
generation and await its source-close barrier. The coalescing loop compares both
the delivered graph and delay. VOD retains video position; large-delay Live
rejoins without changing public DVR configuration. During an unrelated initial
load, a pending graph is generation-bound and reconciled only after the original
load exits and its route is installed. Terminal states do not restart, and stop
or source replacement invalidates pending work.

Required additional regressions: upstream `AudioShapingTests`, shaped native
finite gaps and actual +/-180 Live/VOD decoded video, shaped software delivered
sample offsets, shaping during captured warmup, initial-load reconciliation,
terminal refusal and queued-task stop/replacement. Run upstream privacy,
packet-backed sidecar and callback-release tests as well as the existing complete
expanded-range matrix. Native fixture skips remain a release failure.

### 7.52.0 verification record

The complete tag and FFmpegBuild `3.11.0-iptvx`
(`84729c8d4e9c29b72cfa770272962dc443d7a229`) passed the focused macOS
validation groups below. Counts are runner results/test methods, not a claim
that parameterized argument cases are separate methods:

- Upstream shaping/privacy/sidecar/callback and retained selection/options:
  98 passed, one expected skip for the test requiring a disabled object-audio
  trait (the fork enables it). No failures.
- Native finite/Live/lifecycle: 10 Swift Testing methods, 31 argument cases,
  no failures or skips. Both shaped and unchanged pipelines retain native
  decoded progress at +/-180 and finite gap/seek boundaries. Late initial
  graph changes, terminal refusal, stop and source replacement pass.
- Live correction and graph warmup: eight methods, nine argument cases,
  no failures or skips, including current headers/User-Agent and held teardown.
- Software: seven methods, 17 argument cases, no failures or skips. Delivered
  audio offsets, shaped/unshaped +/-180, real video handover and later progress,
  finite gaps, matched Live EOF, immediate DVR landing/resume and reset pass.
- Padding/storage/policy/GPU closure: 148 runner results (127 Swift Testing
  methods across 21 suites plus 21 XCTest cases), no failures or skips.
  Parameter cases include actual HE-AAC/HE-AACv2 implicit/explicit ASC final-GOP
  EOF and leading seeks; APAC cookie/source grid, byte caps, cancellation,
  source epochs, normal saturation, DVR envelopes and small offsets pass.

The native fixture matrix had zero skips. The one software observation failure
in an earlier run was a startup assertion before the first renderer handover:
Live's initial clock re-anchor had already moved the published clock. The final
full software suite waits for a genuine first handover, then additional decoded
frames and clock progress; no production workaround was added.

Both iOS and tvOS build-only validations passed with the retained 16.0 deployment
targets, using identical final production sources. The final 44-file code/test
snapshot reverse-checks on the corrected tree, detects a missing correction on
the documented baseline, applies idempotently and reproduces byte-identical
files. These are macOS runtime and platform-compilation results; they do not
establish physical-device lip-sync or production-origin warmup latency.

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
- Keep the explicitly requested -180...180-second range aligned with IPTVX's
  adapter and picker. Positive values present audio later; the host step remains
  half a second. Reject non-finite timestamps and clamp out-of-range values at
  the engine boundary as well as the host boundary.
- Preserve the existing path for corrections within two seconds. Larger offsets
  require compressed packet alignment; increasing a numeric clamp alone does not
  produce correct playback. Leaving that path, including reset to zero, must
  reconstruct its timing state.
- Keep source-order admission, recording and timeline normalization before
  cross-track scheduling. Preserve original DTS, PTS, duration, flags and side
  data, including the opt-in DVR packet envelope. At Live EOF retain only the
  matched A/V interval; finite VOD retains its intentional silent video tail.
  Apply the audio offset once at
  the renderer or muxer, and keep video/subtitle position on the source axis.
- Bound compressed disk queues within the session's retention allowance. Include
  actual resident disk bytes in accounting. Capacity or spool errors must fail
  explicitly; never discard required packets or retain minutes of decoded media
  to make the requested value appear accepted.
- Live can need up to the absolute offset in source history before playback is
  possible. Startup/first-frame policy must distinguish that intentional warmup
  from a failed source; cancellation must still interrupt it. Internal alignment
  does not enable a public DVR window. A DVR window must represent the available
  audio/video intersection, not raw source retention alone. After a DVR seek,
  resume clamping must use the current video position rather than a stale
  published window snapshot; otherwise play can immediately undo the seek.
- A large Live delay change rejoins the source even when DVR is enabled, retaining
  transport intent rather than the old paused DVR position. Source timeline or
  format discontinuities retire unmatched old-epoch tails and restart alignment.
  A source that resets more frequently than the requested offset may be unable to
  provide a stable matched interval; bounded failure must remain explicit rather
  than an endless warmup or a silently reduced delay.
- VOD must retain the requested video position. Missing source audio at the
  beginning or end is an intentional gap; it must not skip video, stall a tail
  seek or end the title early. Preserve native codecs, Dolby Vision and object
  audio rather than changing the playback route to hide a gap-handling defect.
- Remote-HLS bypass remains explicitly unsupported.

### Porting boundaries

Inspect `AetherEngine+AudioDelay.swift`, the session-preserving reload/load path,
source teardown ownership, `HLSSegmentProducer` and `MP4SegmentMuxer`. The original
failure is the combination of a Live-without-DVR re-anchor refusal and an immutable
producer offset. Updating only the parent session's value does not update the
producer already serving the viewer.

The expanded range additionally crosses compressed packet scheduling, software
clock/lead/preroll decisions, native segment audio admission and seek read-start
selection, finite-media tail framing, and shared disk retention. Inspect
`CompressedAudioDelayAlignment`, `SoftwareAudioDelayPacketSource`,
`SoftwareAudioDelayTimeline`, `SoftwarePlaybackHost`, `PacketRingBuffer` and
`HLSVideoEngine`, `AudioDelayDiscontinuityBudget`, `AudioTailPadding`,
`HEAACSilenceEncoder` and `SpatialAudioBridge` when porting. A source/configuration epoch must not apply new
decoder or muxer state to queued old-format packets. Small-offset behavior stays
outside the new alignment stage.

The large-offset storage policy divides one session reservation between the
ordinary compressed cache/ring and alignment. Include consumed chunk prefixes,
staging bytes and record headers in residency; do not confuse a retention claim
with enforcement. Normal saturation must evict optional cache or wait for
consumer progress. Only an unsatisfiable required span/record is a capacity
failure. Preserve this distinction when upstream changes cache admission.

Native finite gaps reuse the segment muxer and audio-padding boundaries. Do not
reintroduce an HLS-period rewrite or route fallback to hide missing audio.
Leading fragments must be seekable before the first genuine audio packet, and
final padding must allow video to reach its normalized final frame. Genuine
source audio packets and codec configuration remain unchanged. APAC fill uses
the existing encoder/cookie/layout in bounded chunks. HE-AAC fill accepts only
verified compatible mono/stereo, 1024-core-frame, 2x-SBR configurations (including
PS); PCE, 960-frame and other unsupported configurations are explicit failures
when fill is required. Temporary and returned compressed bytes count toward the
same retention policy. No new binary dependency is introduced.

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

Initial bounded-range validation used synthetic H.264/AAC media on the native macOS pipeline,
including actual fMP4 packet timestamps. The complete `LiveAudioDelayTests` suite
passed five tests (six argument cases), with no failures or skips.
HLS/refusal and six related AE#464 policy
suites passed 20 tests; actual VOD loopback and software setter checks passed two
tests. iOS and tvOS builds passed with the existing OS16 floors. The check/apply
script was verified on the uncorrected baseline, then repeated to prove
idempotence and byte-identical corrected sources. These checks do not establish
physical-device lip-sync or a guaranteed rejoin duration for every Live origin.

### Expanded-range verification matrix

The full-range correction must be verified separately from the initial bounded
Live fix. Exercise -180, -30, -3, -2.5, zero and their positive counterparts as
appropriate to each boundary; a clamp/picker test does not establish delivery.

- Native and software Live: actual corrected audio timestamps and advancing
  video, both signs, source epochs, EOF, stop and source replacement.
- An owned Live warmup interrupted by zero or the opposite sign: no concurrent
  outgoing/incoming source access, latest transport and subtitle intent retained,
  no stale reload hold or foreground-restore request.
- Native finite VOD: initial mixed-fragment audio gaps, seeks inside a leading
  gap, an uncached middle gap, final-frame presentation and tail seeks, and an
  entirely empty shifted audio overlap. Verify decoded video, not only clock or
  seek-completion callbacks.
- Software finite VOD and DVR: preserve requested video position and source packet
  metadata; public DVR availability must use the shifted A/V intersection.
- Retention: account on-disk record overhead and staging, test normal saturation
  and consumer progress, and refuse records or spans that cannot fit explicitly.
- Same-format native silence: retain source codec configuration and genuine
  compressed packets, verify HE-AAC/HE-AACv2 implicit and explicit ASC forms, and
  preserve APAC cookie/layout and timestamp continuity. Unsupported required
  fill must not masquerade as a successful gap fix.
- Existing small-offset, ring, lifecycle and audio-delay policy regressions,
  followed by iOS/tvOS compilation with the retained OS16 floors.

Opt-in fixture tests must report missing fixtures as skips. A skipped native
fixture matrix is not evidence for a release. Preserve the fixture identity,
run configuration and test results with the validation record.

### Full-range validation record

The final native macOS closure passed 11 tests across three suites, with no
failures or skips; complete logs confirm all signed parameter cases. It covers
actual decoded video and native playback at both 180-second limits, finite gap
seeks at +/-2.5, +/-3 and +/-30 seconds, stop/source replacement, rotating HLS
headers, ordinary small offsets and spatial encoder continuity. Held-teardown
warmup replacement tests separately verify latest transport/subtitle intent and
absence of overlapping source I/O. A separate seekable custom-reader regression
also passed with its outgoing teardown held. Shared alignment, Live EOF, cache saturation,
padding byte caps and cancellation regressions also passed.

Software validation passed the 61-test pipeline group and the 23-test budget
closure. Final DVR and Live-EOF checks passed two parameterized tests with four
signed cases. The retained-DVR test now asserts immediate landing and new video
within three seconds, preventing natural playback from disguising an ignored or
undone seek. Finite silent-title and tail-EOF checks passed separately.

HE-AAC/HE-AACv2 validation passed 15 compatibility/padding tests, one cancellation
test with two cases and four native leading-gap cases. The native checks verify
source ASC and genuine packet preservation, prefix seeking and the final decoded
video frame. Final iOS/tvOS core builds passed with the existing OS16 floors.
The 43-file code/test snapshot passes reverse-check on this core, applies to the
uncorrected baseline, remains idempotent and reproduces byte-identical files.
These checks do not establish physical-device lip-sync or production-origin
warmup latency.

### Reproducing native full-range checks

The native integration suite accepts a seekable indexed H.264/AAC fixture with
real keyframes, hardware-decodable dimensions and at least about 25 seconds of
media. Validation used the public SMBClient fixture
`Tests/SMBClientTests/Fixtures/shares/bob/test_files/file_example_MP4_1920_18MG.mp4`,
SHA256 `d6617a009c0c6c9aebf7398d43cad6d1985ddc1b9ab0479e2ea977362b8af5b0`.
Tests remux/repeat its compressed packets and use actual per-track endpoints.
A tiny synthetic source that silently chooses software is not a native proof.

Use the repository's generated FlowDeck harness with its saved My Mac /
`AetherEngineMacTests` configuration. Set the fixture path locally:

```sh
fixture_path=/path/to/file_example_MP4_1920_18MG.mp4
flowdeck test \
  --xcodebuild-env "AETHER_NATIVE_DELAY_FIXTURE=$fixture_path" \
  --xcodebuild-env "TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE=$fixture_path" \
  --only AetherEngineMacTests/NativeLargeAudioDelayTests --json
```

Run the accompanying software, lifecycle, alignment/budget, generic padding,
HE-AAC and spatial-bridge regressions too. Inspect complete Swift Testing output
for actual signed parameter cases: some FlowDeck method filters can select zero
parameterized cases without failing the run. Use a suite selector or the exact
`-only-testing` method signature through its supported `--xcodebuild-options`
pass-through. Preserve the complete log and result bundle before another run
replaces them. Final release checks require zero unexpected skips.

### Retirement condition

Keep this correction active unless an upstream core change implements the same
contract. To retire it, identify the first upstream tag and commit supplying that
behavior, run the regressions without the local patch, and record the resulting
source and runtime evidence here. Remove the retired correction from the active
apply/check script and retire its snapshot in the same change. Retain the tests
or equivalent behavior coverage.
A changed file, passing merge, renamed API or silently accepted delay value is not
an equivalence proof.


## IPTVX-DIRECT-LIVE-AUDIO-READ-AHEAD — withdrawn by user decision

On 2026-11-02 the user explicitly requested withdrawal of the direct-Live
read-ahead correction while retaining the complete +/-180-second audio-delay
correction and iOS/tvOS 16 compatibility. This is a user-directed rollback,
not an upstream-equivalence retirement: upstream PR #934 remains the pending
resolution path. No upstream fix or equivalent behavior is claimed.

The withdrawn change was published in commit
`03c7a5c7f33320ec8d0dd13e4d0ef1b34edd0fab`. Its five source/test paths are restored
to the exact pre-read-ahead baseline
`23b3161da3efb4e486622c14f72fadb9195211bd`. The read-ahead snapshot and its active
stack entry are removed so future check/apply operations cannot reintroduce it.
The ordered transactional checker and its generic maintenance regressions remain.
The original correction is recoverable from the immutable published commit.

This withdrawal may reintroduce the known ordinary software Live audio stutter
under video backpressure, with DVR disabled. The removed correction did not add
public DVR support. The earlier expanded audio-delay snapshot remains byte for
byte unchanged and active; its native/software, Live/VOD, DVR and large-offset
contracts remain the required verification boundary.

The user authorized replacement of `7.52.0-iptvx`. Local rollback validation,
remote tag publication and consumer-pin verification are separate evidence;
this entry alone does not establish delivery or physical-device behavior.

### Withdrawal verification (2026-11-02)

All tracked `Sources/` and `Tests/` paths match the pre-read-ahead baseline
`23b3161da3efb4e486622c14f72fadb9195211bd` exactly. `Package.swift` and
`Package.resolved` are unchanged from the withdrawn delivery. The retained
44-path audio-delay snapshot is byte-identical, SHA256
`285ed004005cc12c31162df5ddadfe7e846df10b619a3c9068a4f0b9f8185c1e`.

Ten Git/Python maintenance regressions pass, including single-patch operation
without the withdrawn successor artifact. The real audio-delay snapshot is
verified missing on a reversed scratch baseline, applies successfully, and
repeated check/apply reproduces all 44 paths byte for byte.

FlowDeck My Mac validation passes 45 test methods in five suites, zero failures
and zero skips: `LiveAudioDelayTests`, `NativeLargeAudioDelayTests`,
`SoftwareLargeAudioDelayTests`, `SoftwareAudioDelayTimelineTests`, and
`LiveReplayPacketReaderTests`. The documented native fixture was supplied;
actual signed +/-180 native/software Live/VOD playback, shaping and DVR
regressions ran. The validation harness was regenerated from the unchanged
manifest in an isolated checkout after stale generated test references were
identified. These results establish source reconstruction and macOS runtime
behavior; consumer iOS/tvOS builds, tag replacement and physical-device results
remain separate evidence.
