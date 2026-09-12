# Recordito architecture notes

How the shipped v1 pipeline actually behaves: the tuning constants, the invariants, and
the things that are easy to break by accident. The rationale for the design lives in
[SPEC.md](../SPEC.md); this is the operational detail underneath it.

## Engine

Worth knowing before touching any of it:

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


## Playback, export and UI

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

## Expected build warnings

Three warnings are expected on Xcode 26.6 / Swift 6.3.3. All three are missing `Sendable`
annotations in system frameworks rather than defects here, and all three are deliberate.

- `Playback/MetalPreviewView.swift:38` — `'@preconcurrency' on conformance to
  'MTKViewDelegate' has no effect`. The macOS 26 SDK annotates `MTKViewDelegate`
  properly, so the attribute is now redundant; the macOS 15 SDK does not, and removing it
  would break the Xcode 16 build the README promises.
- `Playback/PreviewPlayer.swift:37` — `type 'Any' does not conform to 'Sendable'` on the
  `[String: Any]` pixel-buffer attributes handed to `AVPlayerItemVideoOutput`. An
  AVFoundation annotation gap; the dictionary is a local value that is never shared.
- `Render/SourceTexture.swift` — `capture of 'cvTexture' with non-Sendable type
  'CVMetalTexture?' in a '@Sendable' closure`, new in Swift 6.3.3. A `CVMetalTexture` must
  outlive the GPU work sampling from it, so the completion handler holds the only
  reference until the command buffer finishes; the closure never reads or mutates it, and
  CoreVideo objects are safe to retain and release from any thread. If a later compiler
  promotes this to an error, `nonisolated(unsafe)` on the binding is the intended escape
  hatch.

## Things a compiler cannot catch

- Live preview: if the first frame never appears, check that
  `AVPlayerItemVideoOutput.hasNewPixelBuffer` starts returning true after the item is
  ready; `PreviewPlayer.pollFrame` re-arms the output every 60 misses.
- `ExportPipelineTests` runs on a synthetic bundle, which has no audio. If
  `AVAssetReaderAudioMixOutput` ever rejects the LPCM settings in
  `ExportSettings.audioDecodeSettings` on a real bundle, pass `nil` and let the AAC writer
  input convert.
- `EventRecorder.frontWindowFrame` relies on `CGWindowListCopyWindowInfo` ordering (front
  to back) and `kCGWindowLayer == 0`.
- Cursor coordinates are converted from AppKit space using the main display's height
  (`DisplayEnumerator.cgPoint(fromCocoa:)`), which is the place a multi-display sign error
  would surface.
- Screen Recording permission: `CGPreflightScreenCaptureAccess` can keep returning false
  until the app is relaunched after access is granted; the recorder's banner says so.
  Ad-hoc signing keys the grant to the binary's signature, so each rebuild can re-prompt —
  set a development team in the target's Signing settings for a stable identity.

## Project layout notes

- Hand-written `Recordito.xcodeproj` using Xcode 16+ synchronized folder groups: every
  file under `Recordito/` and `RecorditoTests/` is picked up automatically. `Info.plist`
  and the entitlements file are membership exceptions.
- `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (classic Swift 6
  semantics; UI classes are annotated `@MainActor` explicitly),
  `SWIFT_STRICT_CONCURRENCY = complete`.
- `SWIFT_OBJC_BRIDGING_HEADER = Recordito/Render/ShaderTypes.h` shares the uniform struct
  between Swift and Metal.
- App Sandbox is off (direct-distribution assumption, open question 1 in SPEC). Hardened
  runtime is on, with the audio-input entitlement for the microphone.
- Running the test suite against a **Release** build needs two overrides:
  `ENABLE_TESTABILITY=YES` (Release turns it off, and `@testable import` requires it) and
  `ENABLE_HARDENED_RUNTIME=NO` (library validation otherwise refuses to load an
  ad-hoc-signed `.xctest` bundle into the app, reporting "different Team IDs").
