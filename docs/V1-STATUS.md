# v1 implementation — status and remaining work

Branch: `claude/v1-implementation-dca836`. Last updated 2026-09-11.

Everything below the "Done" line compiles under Swift 6 strict concurrency
(`xcodebuild build-for-testing` succeeds) and the unit tests listed pass.
Nothing has been run against a live screen capture yet: that needs the UI in
section 3 plus Screen Recording permission granted to the built app.

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

## Done

| Area | Files | Tests |
|---|---|---|
| Schemas | `Models/EventsDocument.swift`, `Models/EditDocument.swift`, `Models/RGBAColor.swift`, `Models/CodableDefaults.swift` | `DocumentTests` |
| Bundle IO | `Models/RecordingBundle.swift` (`.recordito`, `ProjectLibrary` in `~/Movies/Recordito`) | `DocumentTests` |
| Auto-zoom | `Engine/AutoZoomGenerator.swift` | `AutoZoomGeneratorTests` |
| Cursor smoothing | `Engine/CursorSmoother.swift`, `Engine/TimedSpline.swift`, `Engine/OneEuroFilter.swift` | `CursorSmootherTests` |
| Camera path | `Engine/ZoomTimeline.swift`, `Engine/Viewport.swift`, `Engine/Easing.swift` | `ZoomTimelineTests` |
| Per-frame state | `Engine/FrameComposer.swift`, `Engine/CursorGlyphs.swift` | `FrameComposerTests` |
| Renderer | `Render/Shaders.metal`, `Render/ShaderTypes.h`, `Render/FrameRenderer.swift`, `Render/CursorAtlas.swift`, `Render/SourceTexture.swift`, `Render/TextureImage.swift` | `GoldenFrameTests` (3 committed reference PNGs in `RecorditoTests/Fixtures`) |
| Capture | `Capture/*.swift` (see commit message of the capture commit) | `AudioAlignmentTests` (compiled, not yet executed in a test run) |

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
  (`SourceTextureUploader`), which both preview and export must go through.

## Remaining

### 1. Playback (`Recordito/Playback/`)

- `PreviewPlayer` (`@MainActor`): `AVMutableComposition` with the
  `screen.mov` video track plus `mic.caf` and `system.caf` audio tracks
  inserted at zero (audio preview for free, still never pre-mixed on disk);
  `AVPlayer` + `AVPlayerItemVideoOutput(pixelBufferAttributes:
  [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
  kCVPixelBufferMetalCompatibilityKey: true])`; `seek(to:toleranceBefore:
  .zero, toleranceAfter: .zero)` for scrubbing; periodic time observer for the
  transport UI; call `requestNotificationOfMediaDataChange(withAdvanceInterval:)`
  after seeks and whenever `hasNewPixelBuffer` stays false, otherwise the
  output goes dormant.
- `MetalPreviewView`: `NSViewRepresentable` around `MTKView`
  (`colorPixelFormat = .bgra8Unorm`, `preferredFramesPerSecond = 60`,
  `isPaused = false`, `enableSetNeedsDisplay = false`). Coordinator conforms
  with `@preconcurrency MTKViewDelegate`. In `draw(in:)`: `itemTime =
  output.itemTime(forHostTime: CACurrentMediaTime())`; if
  `hasNewPixelBuffer(forItemTime:)`, `copyPixelBuffer` and upload through
  `SourceTextureUploader`; then `renderer.encode(state:
  composer.state(at: itemTime.seconds), source:, into: drawable.texture,
  commandBuffer:)`, present, commit. Keep the aspect ratio of the canvas with
  `.aspectRatio(canvas.aspectRatio, contentMode: .fit)`.
- `ProjectSession` (`@Observable @MainActor`): bundle + `EventsDocument` +
  `EditDocument` + `SourceInfo(display:)`; rebuilds the `FrameComposer` when
  the edit document changes (it is cheap: a few ms for a 2-minute track);
  debounced autosave of `edit.json`; `regenerateZooms()` uses
  `AutoZoomGenerator(parameters: AutoZoomParameters(intensity:))` with
  `existing: edit.zooms` so user-modified zooms are preserved.

### 2. Export (`Recordito/Export/`)

- `ExportSettings`: presets 1080p / 1440p / 4K (canvas aspect preserved),
  30 / 60 fps, H.264 High profile, bitrate roughly `pixels * fps * 0.09`
  capped at 60 Mbps, AAC 48 kHz stereo 192 kbps.
- `Exporter` (own serial queue, `@unchecked Sendable`, cancellable):
  `AVAssetReader` on `screen.mov` with `AVAssetReaderTrackOutput`
  `outputSettings: [kCVPixelBufferPixelFormatTypeKey: BGRA,
  kCVPixelBufferMetalCompatibilityKey: true]`; `AVAssetWriter` (`.mp4`) with an
  `AVAssetWriterInputPixelBufferAdaptor` whose `sourcePixelBufferAttributes`
  are BGRA + Metal compatible so output frames are rendered straight into the
  pool's buffers via `SourceTextureUploader.wrap`; video loop driven by
  `videoInput.requestMediaDataWhenReady(on:)`: for frame `i` at `t = i / fps`
  pull decoded frames until the next PTS exceeds `t`, hold the last one,
  upload it (only when it changed), render `composer.state(at: t, fps:)`,
  `commandBuffer.waitUntilCompleted()`, `adaptor.append(pixelBuffer,
  withPresentationTime: CMTime(value: i, timescale: fps))`. Audio: a second
  `AVAssetReader` on an `AVMutableComposition` of `mic.caf` + `system.caf`
  with `AVAssetReaderAudioMixOutput` (LPCM) feeding an AAC
  `AVAssetWriterInput` with its own `requestMediaDataWhenReady` loop. Tag
  colour as BT.709 like the capture writer. Progress = frames / total. Skip
  the audio input entirely when neither track exists.
- `PublishDestination` protocol exactly as in SPEC.md section 3 plus
  `VideoMetadata { title, description }`; `LocalFileDestination(targetURL:)`
  moves the finished temp file into place and returns its URL.
- Test: `ExportPipelineTests` writes a synthetic 2 s 320×200 30 fps
  `screen.mov` with `AVAssetWriter` from `SyntheticSource.pixelBuffer`
  frames, an events document from `SyntheticSource.events` scaled to that
  size, runs the exporter to a temp `.mp4` at 640×360 30 fps, and asserts the
  file exists, has a video track of that size and a duration within 0.1 s.

### 3. UI (`Recordito/UI/`, `Recordito/App/`)

- `AppModel` (`@Observable @MainActor`): states `setup`, `countdown(n)`,
  `recording(RecordingSession)`, `editing(ProjectSession)`, `exporting`.
  Owns the HUD panel. `startRecording(configuration:)`: hide the main window
  (`orderOut`), show the HUD, count 3-2-1, then `session.start()`. `stop()`:
  `session.stop()`, close the HUD, open the editor with the bundle, show the
  main window. Wire `RecordingSession.onUnexpectedStop` to the same path.
- `RecorderSetupView`: if `CapturePermissions.screenRecordingGranted` is
  false show the explanation with a "Grant Screen Recording Access" button
  (`requestScreenRecording()`, then `openScreenRecordingSettings()` if it is
  still false); display picker from `DisplayEnumerator.displays()`;
  microphone toggle + `AudioInputDevice.available()` picker (permission is
  requested by the session, lazily); system audio toggle; Record button;
  recent projects from `ProjectLibrary.recentProjects()` with thumbnails.
- `RecordHUDPanel` (`NSPanel` subclass: `.nonactivatingPanel`, `.borderless`,
  level `.floating`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]`, `isMovableByWindowBackground`,
  positioned at the bottom centre of the recorded display) hosting
  `RecordHUDView` through `NSHostingView`: big countdown digits, then a red
  dot, elapsed time, and a Stop button. The HUD never appears in the capture
  because `ScreenCaptureEngine` excludes every window of our own process, and
  clicks on it are dropped by `EventRecorder.handleClick`.
- `EditorView`: `HSplitView { preview column | InspectorView }`. Preview
  column: `MetalPreviewView` + transport bar (play/pause, scrubber `Slider`
  bound to the player time, `mm:ss.f` labels). Toolbar: "Export…".
- `InspectorView` (`Form`, `.formStyle(.grouped)`): Background (solid /
  gradient picker, two `ColorPicker`s bound through `RGBAColor` ↔ `Color`
  helpers, angle slider, a handful of gradient presets), Frame (padding 0–200,
  corner radius 0–64, shadow radius 0–120 / opacity 0–1 / offset −40–80),
  Cursor (scale 0.5–3, smoothing 0–1, hide when idle, click highlight), Zoom
  (auto zoom toggle, intensity 0.5–1.5 with debounced regeneration,
  "Regenerate" button), Effects (motion blur toggle).
- `ExportSheet`: preset pickers, `NSSavePanel` (`.mpeg4Movie`, default name
  from the bundle), progress bar, cancel, "Reveal in Finder" on completion.
- `AppDelegate` via `NSApplicationDelegateAdaptor`: `application(_:open:)`
  opens `.recordito` bundles from Finder; keep the app running when the last
  window closes only while recording. Commands: New Recording (⌘N),
  Open Project… (⌘O), Export… (⌘E).
- Replace the placeholder `App/RecorditoApp.swift`.

### 4. Docs and verification

- README: replace "Status: Planning" with build/run instructions, the
  permissions story, and the test commands above.
- Manual acceptance pass (needs a person at the machine to grant TCC prompts):
  1. 2-minute 4K60 recording: `RecordingStatistics.droppedFrames == 0`,
     CPU under 15 % (Activity Monitor).
  2. Auto zooms land on the content clicked in a typical app demo.
  3. Cursor visibly smooth; frame at a click shows the tip on the click point.
  4. Preview and export identical (golden test covers the renderer; compare a
     paused preview frame with the exported frame at the same time).
  5. 2-minute 1080p60 export completes faster than real time (log the ratio in
     the export sheet).

### 5. Known risks to check during the live test

- ScreenCaptureKit audio arrives as float32 non-interleaved 48 kHz;
  `AlignedAudioWriter` converts other layouts with `AVAudioConverter`. Verify
  `mic.caf` from `AVCaptureAudioDataOutput` (device-native format) plays back.
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
