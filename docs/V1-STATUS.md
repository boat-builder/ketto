# v1 implementation — status and remaining work

Branch: `claude/zealous-meitner-fvrp9p` (continues `claude/v1-implementation-dca836`).
Last updated 2026-09-11.

Every area of the v1 scope in SPEC.md section 6 now has an implementation. The engine,
renderer and capture layers were built and verified in the previous pass; the playback,
export and UI layers were added in this one on a machine without an Apple toolchain, so
they have been reviewed for Swift 6 strict-concurrency correctness by hand but have not
yet been compiled or run. The first thing to do on a Mac is section 3 below.

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

## 2. Remaining

### Manual acceptance pass (needs a person at the machine to grant TCC prompts)

1. 2-minute 4K60 recording: `RecordingStatistics.droppedFrames == 0` (the editor
   shows a warning line when frames were dropped), CPU under 15 % (Activity
   Monitor).
2. Auto zooms land on the content clicked in a typical app demo.
3. Cursor visibly smooth; frame at a click shows the tip on the click point.
4. Preview and export identical (golden test covers the renderer; compare a
   paused preview frame with the exported frame at the same time).
5. 2-minute 1080p60 export completes faster than real time. The export sheet
   shows the ratio while rendering and in the completion message.

## 3. What to check first on a Mac

The new layers were written without a compiler. Expected trouble spots, in order:

- Build errors. Likely candidates are Swift 6 isolation diagnostics in the
  SwiftUI views (`Binding(get:set:)` closures and `LabeledSlider.format`),
  the `@preconcurrency MTKViewDelegate` conformance in `MetalPreviewView`, and
  Sendable diagnostics on AVFoundation types (every file that uses AVFoundation
  imports it with `@preconcurrency`).
- `ExportPipelineTests`: the first test writes a 2 s H.264 movie, exports it at
  640×360 and checks the track size and duration. If `AVAssetReaderAudioMixOutput`
  rejects the LPCM settings in `ExportSettings.audioDecodeSettings` on a real
  bundle (the synthetic bundle has no audio), pass `nil` and let the AAC writer
  input convert.
- Live preview: if the first frame never appears, check that
  `AVPlayerItemVideoOutput.hasNewPixelBuffer` starts returning true after the
  item is ready; `PreviewPlayer.pollFrame` re-arms the output every 60 misses.
- HUD: confirm it is absent from the recording and that its Stop click is not
  in `events.json`.
- ScreenCaptureKit audio arrives as float32 non-interleaved 48 kHz;
  `AlignedAudioWriter` converts other layouts with `AVAudioConverter`. Verify
  `mic.caf` from `AVCaptureAudioDataOutput` (device-native format) plays back
  in the editor and lands in the export.
- `CursorTypeDetector` matches `NSCursor.currentSystem` by rasterised alpha
  shape; verify the I-beam and pointing hand are detected in Safari/Xcode.
- `EventRecorder.frontWindowFrame` relies on `CGWindowListCopyWindowInfo`
  ordering (front to back) and `kCGWindowLayer == 0`.
- `VideoTrackWriter` uses HEVC at ~0.10 bits/pixel/frame (≈46 Mbps at 4K60)
  with a 1 s GOP and `movieFragmentInterval = 5 s`; check text crispness and
  file size on a real recording and adjust the constant if needed.
- Multi-display: cursor coordinates are converted from AppKit space using the
  main display's height (`DisplayEnumerator.cgPoint(fromCocoa:)`); verify on a
  secondary display, including one positioned above or left of the main one.
  The HUD is positioned with the `NSScreen` whose `NSScreenNumber` matches the
  chosen display.
- Screen Recording permission: `CGPreflightScreenCaptureAccess` can keep
  returning false until the app is relaunched after access is granted; the
  recorder's banner says so.

## 4. Stretch items not started

- Click highlight ripple and motion blur are in (they were v1 stretch goals).
- Nothing else from the v2 list has been started; the timeline, trim/cut,
  webcam, aspect presets and masking all remain out of scope.
