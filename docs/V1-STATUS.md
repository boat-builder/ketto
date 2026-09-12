# v1 implementation — status and remaining work

Branch: `claude/v1-completion-verification-6570d0`.
Last updated 2026-09-12.

Every area of the v1 scope in SPEC.md section 6 has an implementation, and the whole
project now compiles, tests and runs on a real toolchain (Xcode 26.2, Swift 6.2.3, Apple
silicon). The playback, export and UI layers had been written without a compiler in the
previous pass; bringing them to a Mac turned up exactly one build error, now fixed:

- `UI/ExportSheet.swift` — `Task { @MainActor [weak self] in … }` nested inside an
  already-`[weak self]` closure is "reference to captured var 'self' in
  concurrently-executing code": Swift treats a weak capture as mutable, so a nested
  concurrent closure may not re-capture it. The progress handler is now built once in
  the main-actor scope of `export(session:settings:to:)` and passed into the task.

What is left is the part that needs a person at the machine: a real recording, which
means granting the Screen Recording and Microphone prompts. See section 2.

## Build and test

```bash
xcodebuild build -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64'
```

```bash
xcodebuild test -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64'
```

Re-record golden frames after an intentional renderer change:

```bash
TEST_RUNNER_RECORDITO_UPDATE_GOLDEN=1 xcodebuild test -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64' -only-testing:RecorditoTests/GoldenFrameTests
```

Project notes:
- Hand-written `Recordito.xcodeproj` using Xcode 16+ synchronized folder groups:
  every file under `Recordito/` and `RecorditoTests/` is picked up automatically.
  `Info.plist` and the entitlements file are membership exceptions.
- `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`
  (classic Swift 6 semantics; UI classes are annotated `@MainActor` explicitly).
- `SWIFT_OBJC_BRIDGING_HEADER = Recordito/Render/ShaderTypes.h` shares the
  uniform struct between Swift and Metal.
- Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`, no team). macOS keys Screen
  Recording permission to the code signature, so each rebuild may re-prompt.
  Set your team in Xcode for a stable identity.
- App Sandbox is off (direct-distribution assumption, open question 1 in SPEC).
  Hardened runtime is on, with the audio-input entitlement for the microphone.

## 0. Verified on a real toolchain

Machine: Apple silicon, macOS 26.0 SDK, Xcode 26.2 (Swift 6.2.3), `SWIFT_STRICT_CONCURRENCY = complete`.

| Check | Result |
|---|---|
| `xcodebuild build` | succeeds, no errors |
| `xcodebuild test` | 47 passed, 0 failed, 2 skipped (the opt-in benchmarks below) |
| App launch | launches to the recorder, runs, quits cleanly, no crash report |
| Export faster than real time @ 1080p60 (SPEC §6 acceptance 5) | **4.93×** real time |
| Export ≥ 0.5× real time @ 4K60 (SPEC §7 performance target) | **1.55×** real time |
| Preview and export identical (SPEC §6 acceptance 4) | structurally identical path, see below |

Two warnings remain, both benign and both left alone on purpose:

- `Playback/MetalPreviewView.swift:38` — `'@preconcurrency' on conformance to
  'MTKViewDelegate' has no effect`. The macOS 26 SDK annotates `MTKViewDelegate`
  properly, so the attribute is now redundant; the macOS 15 SDK does not, and removing
  it would break the Xcode 16 build the README promises.
- `Playback/PreviewPlayer.swift:37` — `type 'Any' does not conform to 'Sendable'` on the
  `[String: Any]` pixel-buffer attributes handed to `AVPlayerItemVideoOutput`. An
  AVFoundation annotation gap; the dictionary is a local value that is never shared.

### Export throughput benchmark

`RecorditoTests/ExportThroughputTests.swift` measures acceptance criterion 5 without a
capture: it writes a two-minute synthetic `screen.mov` using `VideoTrackWriter`'s own
HEVC settings (so the decode side faces the same bitstream a real capture produces),
drives it with an event track that clicks somewhere new every 6 s — twenty zooms across
the recording, so the camera is ramping, panning or holding for most of the export and
the renderer stays off its cheap single-sample path — and then runs the real `Exporter`.

It is skipped by default. Run it against a Release build, which is what the numbers
describe:

```bash
xcodebuild build-for-testing -project Recordito.xcodeproj -scheme Recordito \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
```

```bash
TEST_RUNNER_RECORDITO_RUN_BENCHMARKS=1 xcodebuild test-without-building \
  -project Recordito.xcodeproj -scheme Recordito \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -only-testing:RecorditoTests/ExportThroughputTests
```

Both overrides are needed: Release turns `ENABLE_TESTABILITY` off, which `@testable
import Recordito` requires, and Release leaves the hardened runtime on, whose library
validation refuses to load an ad-hoc-signed `.xctest` bundle into the app ("different
Team IDs").

Measured, two minutes of 60 fps source each:

| Output | Source | Elapsed | Speed | Size |
|---|---|---|---|---|
| 1920×1080 @ 60 | 1920×1080 HEVC | 24.4 s | 4.93× real time | 167 MB |
| 3840×2160 @ 60 | 3840×2160 HEVC | 77.3 s | 1.55× real time | 668 MB |

The 1080p figure is the same (4.93× vs 4.95×) whether the camera moves constantly or
sits still for most of the recording, so the export is bound by decode and encode rather
than by the Metal pass — content complexity should not move these numbers much.

### Preview and export

Both paths are the same two calls: `composer.state(at:fps:)` for the frame state, then
`renderer.encode(state:source:into:commandBuffer:)` through a `SourceTextureUploader`
(`Playback/MetalPreviewView.swift:62` and `Export/Exporter.swift:322`). They differ only
in the target — a drawable versus a pooled `CVPixelBuffer` — and
`GoldenFrameTests.testPixelBufferTargetMatchesTextureTarget` asserts those two targets
render identical pixels. What that does *not* prove is frame *timing*: that the source
frame the preview shows at time *t* is the one the exporter picks at time *t*. That is
acceptance item 4 in section 2 and still wants an eyeball.

---

## 1. Done

| Area | Files | Tests |
|---|---|---|
| Schemas | `Models/EventsDocument.swift`, `Models/EditDocument.swift`, `Models/RGBAColor.swift`, `Models/CodableDefaults.swift` | `DocumentTests` |
| Bundle IO | `Models/RecordingBundle.swift` (`.recordito`, `ProjectLibrary` in `~/Movies/Recordito`) | `DocumentTests` |
| Auto-zoom | `Engine/AutoZoomGenerator.swift` | `AutoZoomGeneratorTests` |
| Cursor smoothing | `Engine/CursorSmoother.swift`, `Engine/TimedSpline.swift`, `Engine/OneEuroFilter.swift` | `CursorSmootherTests` |
| Camera path | `Engine/ZoomTimeline.swift`, `Engine/Viewport.swift`, `Engine/Easing.swift` | `ZoomTimelineTests` |
| Per-frame state | `Engine/FrameComposer.swift`, `Engine/CursorGlyphs.swift` | `FrameComposerTests` |
| Renderer | `Render/Shaders.metal`, `Render/ShaderTypes.h`, `Render/FrameRenderer.swift`, `Render/CursorAtlas.swift`, `Render/SourceTexture.swift`, `Render/TextureImage.swift` | `GoldenFrameTests` (3 committed reference PNGs in `RecorditoTests/Fixtures`) |
| Capture | `Capture/*.swift` | `AudioAlignmentTests` |
| Playback | `Playback/PreviewPlayer.swift`, `Playback/MetalPreviewView.swift`, `Playback/ProjectSession.swift` | exercised through the UI only |
| Export | `Export/ExportSettings.swift`, `Export/Exporter.swift`, `Export/PublishDestination.swift` | `ExportPipelineTests` |
| UI | `App/RecorditoApp.swift`, `App/AppDelegate.swift`, `App/AppModel.swift`, `UI/ContentView.swift`, `UI/RecorderSetupView.swift`, `UI/RecordHUD.swift`, `UI/EditorView.swift`, `UI/InspectorView.swift`, `UI/ExportSheet.swift`, `UI/ColorBridging.swift` | manual |

Engine details worth knowing before touching them:
- Auto-zoom merges consecutive clusters with near-identical targets when the
  gap is under 3 s (`closeTargetMergeGap`) so the camera holds instead of
  zooming out and straight back in. Transit suppression delays a zoom whose
  lead-in overlaps a fast cursor flight. Clicks in the last 0.5 s are ignored
  (the Stop button). `userModified` zooms survive regeneration.
- The cursor track is exact at every click (`CursorTrack.position(at:)` adds a
  raised-cosine correction per click whose window shrinks to half the distance
  to the neighbouring click). Raw sample gaps over 100 ms are treated as
  "held still", not interpolated.
- `ZoomTimeline` pans directly between zooms closer than 1.2 s
  (`panThreshold`) and uses 0.55 s eased ramps otherwise.
- The renderer is one full-screen fragment pass. Everything is in canvas
  pixels scaled by `canvasScale`, so a 960×540 preview and a 3840×2160 export
  are the same picture. Motion blur samples between `previousViewport` and
  `viewport`. Sampling uses a mipmapped private copy of the source frame
  (`SourceTextureUploader`), which both preview and export go through.
  IOSurface-backed buffers are wrapped without a copy; anything else is staged
  through a shared texture.
- `FrameComposer` has a second initialiser that takes a prebuilt `CursorTrack`.
  `ProjectSession` uses it so inspector changes that do not touch the cursor
  parameters (`FrameComposer.cursorParameters(for:)`) skip re-smoothing.

Playback, export and UI details:
- `PreviewPlayer` builds an `AVMutableComposition` of `screen.mov` + `mic.caf`
  + `system.caf` (audio mixed for monitoring only) and vends frames through an
  `AVPlayerItemVideoOutput`. `MetalPreviewView`'s coordinator polls it on the
  `MTKView` display link, uploads new frames through `SourceTextureUploader`
  and encodes `composer.state(at:)` for the same item time, so the picture and
  the overlays never drift apart. The output is re-armed with
  `requestNotificationOfMediaDataChange` after seeks and after quiet spells so
  it does not go dormant.
- `ProjectSession.edit` is the single write path: assigning rebuilds the
  composer immediately and autosaves `edit.json` 0.5 s later; the intensity
  slider regenerates zooms 0.3 s after it settles; `close()` flushes.
- `Exporter` runs on one serial queue: `AVAssetReaderTrackOutput` (BGRA) →
  hold-last-frame resampling to the output frame rate → `FrameRenderer` into
  the writer adaptor's pooled pixel buffers → `AVAssetWriter` (H.264 High,
  ~0.09 bits/pixel/frame, 2–60 Mbps, BT.709 tags; AAC 48 kHz stereo 192 kbps
  from an `AVAssetReaderAudioMixOutput` over both audio tracks). The audio
  input is omitted when neither track exists. `cancel()` works before or
  during a run. The finished temp file is handed to `LocalFileDestination`,
  the only `PublishDestination` in v1.
- `AppModel` is the phase machine (`setup` → `countdown` → `recording` →
  `finishing` → `editing`). Starting a recording hides every visible window,
  shows `RecordHUDPanel` (non-activating floating panel at the bottom centre of
  the recorded display; excluded from capture because the engine excludes the
  whole process, and its clicks are dropped by `EventRecorder`), counts down,
  then starts the session. `RecordingSession.onUnexpectedStop` feeds the same
  stop path. Quitting mid-recording stops the capture first
  (`terminateLater`). `application(_:open:)` opens `.recordito` packages from
  the Finder; ⌘N / ⌘O / ⌘E are in the File menu.

## 2. Remaining — the manual acceptance pass

This is the whole of what is left, and it needs a person at the machine: every item
below requires a real capture, which means granting the Screen Recording prompt (and the
Microphone prompt if the mic is on). Nothing here can be automated away — TCC prompts
are deliberately not scriptable.

Acceptance criteria 4 (partly) and 5 are already covered by section 0; 1, 2 and 3 are
open.

**Setup.** Build and launch:

```bash
xcodebuild build -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64'
```

Launch the built `Recordito.app`, press Record once and grant Screen Recording when
macOS asks, then **quit and relaunch** — `CGPreflightScreenCaptureAccess` keeps
returning false until the process restarts, and the recorder's banner says so. Because
signing is ad hoc, the grant is keyed to the binary's signature and macOS may ask again
after a rebuild; set a development team in the target's Signing settings for a stable
identity.

**1 — Capture holds up at 4K60.** Pick a 4K display, record about two minutes of normal
app use, and press Stop on the floating HUD.

- Dropped frames: the editor shows a warning line when `RecordingStatistics.droppedFrames
  > 0`. No line means zero. (`UI/EditorView.swift:15`)
- CPU: watch Recordito in Activity Monitor during the recording. Target is under 15 % on
  an M1; expect a spike at start while the encoder spins up.
- While you are here, confirm the HUD is **not** in the recording, and that its Stop
  click is absent from `events.json` inside the `.recordito` package
  (`Show Package Contents` in the Finder).

**2 — Auto zooms land on the right content.** Record a typical app demo: click a
sidebar item, then a button somewhere else, then something in a third region. Play the
result back in the editor. Each click should be framed by a zoom that holds on the thing
you clicked, and two clicks close together in the same area should hold rather than zoom
out and straight back in. If zooms feel too aggressive or too timid, the Intensity
slider in the inspector regenerates them.

**3 — Cursor is smooth and pixel-accurate at clicks.** Play back and watch the cursor:
it should glide, not jitter, and it should not lag behind fast flicks. Then step to a
click frame with the arrow keys and check the pointer *tip* sits on the thing that was
clicked — `CursorTrack.position(at:)` is built to be exact at every click, so any visible
offset is a real bug. Also confirm the I-beam and pointing-hand shapes are picked up
(hover text in Safari, a link) — `CursorTypeDetector` matches by rasterised alpha shape
and is the most likely thing here to be wrong.

**4 — Preview and export match (the timing half).** The rendering half is proven by
`GoldenFrameTests`; what is left is timing. Pause the preview at a distinctive moment,
export, and open the exported MP4 at the same timestamp. The picture should be the same
frame, not a neighbour.

**5 — Export speed.** Already measured automatically (section 0: 4.93× at 1080p60,
1.55× at 4K60). On a real recording the export sheet shows the ratio while rendering and
again in the completion message — worth a glance to confirm it agrees.

**Also worth checking while you have a capture in hand:**

- Audio: confirm `mic.caf` (device-native format from `AVCaptureAudioDataOutput`) plays
  back in the editor and lands in the export, and that system audio does too. Check they
  stay in sync with the picture across the whole two minutes.
- Encoder quality: `VideoTrackWriter` uses HEVC at ~0.10 bits/pixel/frame (≈46 Mbps at
  4K60) with a 1 s GOP. Check text crispness and file size on a real recording and adjust
  the constant if it looks soft.
- Multi-display: cursor coordinates are converted from AppKit space using the main
  display's height (`DisplayEnumerator.cgPoint(fromCocoa:)`). Verify on a secondary
  display, including one positioned above or to the left of the main one — that is where
  a sign error would show up. The HUD should appear on the display being recorded.

## 3. Runtime trouble spots

The build-error list that used to live here is resolved (section 0). What remains are
things a compiler cannot catch, in rough order of likelihood:

- Live preview: if the first frame never appears, check that
  `AVPlayerItemVideoOutput.hasNewPixelBuffer` starts returning true after the
  item is ready; `PreviewPlayer.pollFrame` re-arms the output every 60 misses.
- `ExportPipelineTests` passes on the synthetic bundle, which has no audio. If
  `AVAssetReaderAudioMixOutput` rejects the LPCM settings in
  `ExportSettings.audioDecodeSettings` on a *real* bundle, pass `nil` and let the AAC
  writer input convert.
- `EventRecorder.frontWindowFrame` relies on `CGWindowListCopyWindowInfo`
  ordering (front to back) and `kCGWindowLayer == 0`.
- Screen Recording permission: `CGPreflightScreenCaptureAccess` can keep
  returning false until the app is relaunched after access is granted; the
  recorder's banner says so.

## 4. Stretch items not started

- Click highlight ripple and motion blur are in (they were v1 stretch goals).
- Nothing else from the v2 list has been started; the timeline, trim/cut,
  webcam, aspect presets and masking all remain out of scope.
