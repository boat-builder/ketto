# Ketto architecture notes

How the shipped pipeline actually behaves: the tuning constants, the invariants, and
the things that are easy to break by accident. The rationale for the design lives in
[SPEC.md](SPEC.md); this is the operational detail underneath it.

## Engine

Worth knowing before touching any of it:

- Auto-zoom merges consecutive clusters with near-identical targets when the
  gap is under 3 s (`closeTargetMergeGap`) so the camera holds instead of
  zooming out and straight back in. Transit suppression delays a zoom whose
  lead-in overlaps a fast cursor flight. Clicks in the last 0.5 s are ignored
  (the Stop button). `userModified` zooms survive regeneration, and generated
  zooms never overlap them. With a `ZoomFraming` whose base view is a slice of
  the recording (`fill` framing) the zoom factor is attenuated
  (`ZoomFraming.attenuated(scale:)`) so a 2× zoom on a vertical canvas does
  not become a keyhole.
- The cursor track is exact at every click (`CursorTrack.position(at:)` adds a
  raised-cosine correction per click whose window shrinks to half the distance
  to the neighbouring click; pins are found by binary search). Raw sample gaps
  over 100 ms are treated as "held still", not interpolated.
- `ZoomTimeline` pans directly between zooms closer than 1.2 s
  (`panThreshold`) and uses 0.55 s eased ramps otherwise. Every zoom hold is a
  `FramingTrack` that pans to keep the cursor in view (dead zone 60 % of the
  view, 0.35 s ease), so the cursor can no longer walk out of a zoomed frame.
  The un-zoomed view is the `framing` track (the idle camera of `fill`
  framing) or the crop.
- `Viewport`s are relative to a *base* view and clamped inside *bounds* (the
  crop), so a zoom never stretches the picture whatever the canvas aspect.
- `EditTimeline` is the edited (output) timeline: `Clip`s of the recording laid
  end to end, each at its own speed. Zooms, masks, clicks and the cursor stay
  in source seconds; the player, the timeline UI and the exporter speak output
  seconds and convert through `sourceTime(forOutput:)` /
  `outputTime(forSource:)`. A source time inside a cut maps to the cut point,
  so markers never vanish. `resolvedClips(sourceDuration:)` sanitises (sorted,
  non-overlapping, clamped) and falls back to v1 `cuts`, then to the whole
  recording.
- `FrameComposer.state(at:)` takes an *output* time. Across a cut the previous
  viewport equals the current one, so there is no motion blur smear. Masks are
  mapped through the viewport (so they follow zooms), capped at 8 per frame
  (`kMaxMasks`). The camera overlay's dodge is a precomputed
  `CameraDodgeSchedule` (sampled at 8 Hz, 0.3 s lead-in, merged under 0.8 s),
  so scrubbing and export agree. The keystroke label groups keys closer than
  0.5 s, holds 1.5 s, and sits 1.6 font sizes inside the frame edge. The
  loop-cursor glide covers the last 0.75 s (`CursorSpec.loopBlend`).
- The renderer is one full-screen fragment pass. Everything is in canvas
  pixels scaled by `canvasScale`, so a 960×540 preview and a 3840×2160 export
  are the same picture. Motion blur samples between `previousViewport` and
  `viewport`. Sampling uses a mipmapped private copy of the source frame
  (`SourceTextureUploader`), which both preview and export go through.
  IOSurface-backed buffers are wrapped without a copy; anything else is staged
  through a shared texture. Blur masks take five taps at a coarse mip level
  (`lod = 2.5 + 2.5 × strength`); highlight masks dim everything outside
  (`highlightDim = 0.25 + 0.5 × strength`). The camera overlay is an SDF
  circle or rounded rectangle with aspect-fill UVs, an inner border and half
  the frame's shadow. Keystroke labels are Core Text pills rasterised once per
  text and size (`KeystrokeLabelRenderer`, LRU of 24). Every v2 uniform is
  zero when the feature is off, which is why the v1 golden frames are
  byte-identical.
- `FrameComposer` has a second initialiser that takes a prebuilt `CursorTrack`
  and `ZoomTimeline`. `ProjectSession` uses it so inspector changes that do
  not touch the cursor parameters or the active zooms skip re-smoothing and
  re-planning; the zoom timeline is cached by (active zooms, framing, cursor
  parameters, source duration).
- Audio DSP is pure Swift: a radix-2 `FFT`, the `NoiseReducer` (spectral gate,
  1024-sample frames, hop 256, sqrt-Hann analysis and synthesis, noise floor
  at the 30th percentile of observed magnitudes × 1.6, at most 22 dB of
  attenuation, per-bin attack/release smoothing) and `LoudnessAnalyzer`
  (400 ms blocks, absolute gate −55 dB, relative gate −12 dB, target −18 dBFS
  RMS, peaks capped at −1 dBFS, gain 0.25–8×).

## Playback and the session

- `CompositionBuilder` turns an `EditTimeline` into `AVMutableComposition`s:
  each clip is inserted at its output position and `scaleTimeRange`d for its
  speed; parts a track does not cover (a short audio file, a camera that
  started late) become empty edits so tracks never drift. Timescale 48 000.
  The same builder feeds the player and the exporter's audio reader, with
  volumes in an `AVAudioMix` and `.spectral` time pitch.
- `PreviewPlayer` runs two `AVPlayer`s — screen and camera — on the host clock
  and starts them with `setRate(_:time:atHostTime:)` at the same host time;
  both seek with zero tolerance. Frames come through one
  `AVPlayerItemVideoOutput` each, polled by `MetalPreviewView` on the `MTKView`
  display link. `load(_:seekTo:)` rebuilds and swaps the items; a load that is
  superseded before it finishes is dropped (`loadGeneration`). All times it
  exposes are output seconds.
- `ProjectSession.edit` is the single write path: assigning rebuilds the
  composer immediately, autosaves `edit.json` 0.5 s later, and — when the
  timeline or the audio decisions changed — reloads the player 0.25 s later,
  mapping the playhead onto the same recording moment. Undo: `edit`
  assignments within 0.8 s coalesce into one step (slider drags), `apply` is
  one step, `beginGesture` / `updateGesture` / `endGesture` bracket a timeline
  drag into one step; 200 steps are kept.
- Derived voice track: when `audio.normalize` or `audio.noiseRemoval` is on,
  `AudioProcessor` writes `derived/mic-nr{0|1}-norm{0|1}.caf` next to the
  source media (three passes, chunked; never more than a chunk in memory) and
  the player and exporter read it instead of `mic.caf`. While it is being
  produced, the raw track plays. The file is keyed by the options and rebuilt
  only when missing.
- Waveforms are peak-per-20 ms buckets (`WaveformLoader`, 50 per second);
  the filmstrip is about 120 thumbnails from `AVAssetImageGenerator.images(for:)`
  at an interval chosen from `[0.5, 1, 2, 3, 5, 10, …]`, delivered progressively.
- Crop editing swaps the preview's composer for one with no crop, `fit`
  framing and no zooms (`previewComposer`), so the user sees the whole
  recording with the crop rectangle over it; leaving the mode re-optimises the
  automatic zooms when the crop changed.

## Timeline and inspector

- `EditorTimelineView` maps output seconds to points with `TimelineGeometry`
  (`pixelsPerSecond`; 0 in the session means "fit", the zoom slider is a log
  scale up to 600 px/s). The ruler, filmstrip and waveforms are `Canvas`
  layers sized to the *visible* window and offset by the scroll position, so
  a long project draws as cheaply as a short one. Blocks are ordinary views
  offset by their output range. The playhead is its own view and the only
  thing that reads `player.currentTime` in the timeline; snap targets are
  computed when a drag starts. Programmatic scrolling uses invisible anchors
  every 0.25 s and `ScrollViewReader`.
- Drags convert point deltas to source seconds through the speed of the clip
  under the block (`Δsource = Δoutput × speed`) and snap in source seconds
  (`TimelineSnapper`, tolerance 8 px) to the recording bounds, the playhead
  and every other block's edges. Clip trims never cross a neighbour; zoom
  moves stay inside the gap between neighbours (`EditOperations`).
- The preview overlay (`PreviewOverlayView`) draws its handles from the same
  `FrameState` the Metal view renders, through `FrameComposer.canvasRect` /
  `sourcePoint`, so they sit exactly on what they edit. Every overlay drag
  pauses playback.
- The Edit menu replaces the standard Undo/Redo group (the session owns the
  stacks) and binds ⌫, ⌘B, ⌘K, ⇧⌘M and ⇧⌘C. These bare-key equivalents
  would also fire inside a text field; the editor has none.

## Capture

- `RecordingClock` is the one time base: host seconds of the first screen
  frame plus the list of pauses. `recordingTime(forHost:)` is nil inside a
  pause and subtracts completed pauses otherwise; `elapsedRecordingTime(at:)`
  is what the HUD shows. `VideoTrackWriter` drops paused frames and retimes
  the rest with `CMSampleBufferCreateCopyWithNewTiming` (pixels shared);
  `AlignedAudioWriter` drops paused buffers and lets its planner trim the
  overlap of the first buffer after a pause; `EventRecorder.makeDocument`
  drops paused events; `CameraCapture` writes `camera.mov` directly in
  recording time (session starts at zero, frames at their recording time).
- `CaptureSource` is a display, a window or a region (points, Core Graphics
  coordinates). Window capture uses `SCContentFilter(desktopIndependentWindow:)`
  and `EventRecorder` re-reads the window's frame every 0.5 s so event
  coordinates follow it. Region capture sets `SCStreamConfiguration.sourceRect`
  relative to the display. Pixel sizes are rounded to even numbers.
- Hiding desktop icons excludes the Finder windows at
  `CGWindowLevelForKey(.desktopIconWindow)` (plus Ketto's own windows) from a
  display or region filter; the wallpaper window is at a different level and
  stays.
- Keystrokes come from a global `NSEvent` key-down monitor, which only
  delivers while the app is trusted for Accessibility (`AXIsProcessTrusted`).
  `KeystrokeMapping` turns key codes into the menu symbols and, in
  `.shortcuts` mode, drops anything that is not a shortcut — plain typing,
  which can be a password, is never stored unless the user chose
  `.everything`. The prompt is only ever triggered by switching the feature
  on.
- `RegionSelectionPanel` is a borderless, key-accepting panel at screen-saver
  level over the chosen display; its flipped view reports the rubber-band
  rectangle in Core Graphics points.

## Export

- `Exporter` runs on one serial queue. Every output frame maps through the
  composer to a recording time; `SequentialFrameSource`s for `screen.mov` and
  `camera.mov` hand out the latest frame at or before that time (clips are in
  recording order, so the readers only move forwards). Frames go through
  `FrameRenderer` into the writer adaptor's pooled pixel buffers (movies) or a
  readable texture handed to `GIFWriter` (ImageIO, 256 colours per frame,
  delay in hundredths of a second, loop count 0). Audio comes from the
  `CompositionBuilder` composition through an `AVAssetReaderAudioMixOutput`.
- `ExportSettings` carries container (MP4, MOV, GIF), codec (H.264, HEVC,
  ProRes 422 — MOV only), size, frame rate, a bitrate multiplier and the GIF
  loop flag. Bitrates: 0.09 bits/pixel/frame for H.264, 0.065 for HEVC, times
  `quality`, clamped to 2–80 Mbps; ProRes picks its own. `ExportPreset` is
  the one-click layer over it (Web, Social, Hand-off, GIF).
- Destinations: `LocalFileDestination` moves the file where the user chose;
  `ClipboardDestination` moves it into `~/Library/Caches/Ketto/Clipboard`
  (keeping the five newest) and writes the file URL to the pasteboard.
  `StillFrameRenderer` renders one frame at canvas resolution from
  `AVAssetImageGenerator` frames for Copy Frame.

## Expected build warnings

One warning is expected on Xcode 26.6 / Swift 6.3.3:

- `Playback/MetalPreviewView.swift:38` — `'@preconcurrency' on conformance to
  'MTKViewDelegate' has no effect`. The macOS 26 SDK annotates `MTKViewDelegate`
  properly, so the attribute is now redundant; the macOS 15 SDK does not, and removing it
  would break the Xcode 16 build the README promises.

Two earlier warnings went away with the v2 rewrite of their files: the
`[String: Any]` pixel-buffer attributes in `PreviewPlayer` now live in a static helper the
compiler accepts, and `SourceTexture.swift` has not been touched. If the
`CVMetalTexture?` capture warning returns there, `nonisolated(unsafe)` on the binding is
the intended escape hatch: the completion handler only keeps the texture alive until the
GPU work finishes.

## Updates

- `UpdateController` owns a `SPUStandardUpdaterController` and is started from
  `applicationDidFinishLaunching`, never from `init`. It refuses to start at all unless
  `Info.plist` carries both a `SUFeedURL` and a real `SUPublicEDKey`, so a checkout without
  release keys is quiet rather than broken.
- `start()` bails out under `XCTestConfigurationFilePath`. The unit tests run against the
  app as their test host, so otherwise every `xcodebuild test` would check the update feed —
  and, once a release exists, download and try to install one over the build in DerivedData.
- `SPUUpdaterDelegate` is annotated `NS_SWIFT_UI_ACTOR` in Sparkle 2.9, so the conformance
  needs nothing; `SPUStandardUserDriverDelegate` is not, so that one carries
  `@preconcurrency` or Swift 6 rejects the whole module. Check the header before adding a
  third conformance rather than assuming either way.
- Sparkle's own state is not observable by SwiftUI, so every transition worth drawing is
  mirrored into `UpdateController.phase` from the delegate callbacks. Each callback carries
  an explicit `@objc(selector)`: they are optional requirements of an Objective-C protocol,
  where a mismatched Swift name is silently ignored instead of rejected by the compiler.
- `AppModel.hideMainWindows()` / `showMainWindows()` are the choke point for
  `setDeferred(_:)`. While deferred, `standardUserDriverShouldHandleShowingScheduledUpdate`
  returns false, so a scheduled update becomes a badge in the recorder instead of a window
  in the capture. The check button and the menu item are disabled over the same span.
- `phase` is also how "the check failed" is distinguished from "no update found" without
  matching on Sparkle's error codes: `didFinishUpdateCycleFor` only records a failure if
  neither `didFindValidUpdate` nor `updaterDidNotFindUpdate` moved `phase` first.

## Things a compiler cannot catch

- Live preview: if the first frame never appears, check that
  `AVPlayerItemVideoOutput.hasNewPixelBuffer` starts returning true after the item is
  ready; `PreviewPlayer.pollFrame` re-arms both outputs every 60 misses.
- Camera sync: both players are started at one host time. If the camera ever drifts,
  check that `automaticallyWaitsToMinimizeStalling` is still false on both (it is required
  by `setRate(_:time:atHostTime:)`) and that the camera composition was built from the
  same `EditTimeline` as the screen one.
- `ExportPipelineTests` runs on synthetic bundles. The voice-track and camera cases write
  their own `mic.caf` / `camera.mov`; if `AVAssetReaderAudioMixOutput` ever rejects the
  LPCM settings in `ExportSettings.audioDecodeSettings` on a real bundle, pass `nil` and let
  the AAC writer input convert.
- GIF frame delays are stored in hundredths of a second, so 15 fps plays back at 14.3 fps;
  choose 10, 20 or 25 fps when exact timing matters.
- `EventRecorder.frontWindowFrame` relies on `CGWindowListCopyWindowInfo` ordering (front
  to back) and `kCGWindowLayer == 0`. Window capture relies on the same call to follow the
  window; if a captured window's events drift, look there first.
- Cursor coordinates are converted from AppKit space using the main display's height
  (`DisplayEnumerator.cgPoint(fromCocoa:)`), which is the place a multi-display sign error
  would surface. `RegionSelectionView.convertToCG` makes the same assumption.
- Screen Recording permission: `CGPreflightScreenCaptureAccess` can keep returning false
  until the app is relaunched after access is granted; the recorder's banner says so.
  Accessibility behaves the same way for keystroke capture. Ad-hoc signing keys both grants
  to the binary's signature, so each rebuild can re-prompt — set a development team in the
  target's Signing settings for a stable identity.
- Audio mix volumes above 1 (the sliders go to 200 %) are applied by AVFoundation as
  amplification in practice; if a platform ever clamps them, bake the extra gain into the
  derived voice track the way normalisation is.

## Project layout notes

- Hand-written `Ketto.xcodeproj` using Xcode 16+ synchronized folder groups: every
  file under `Ketto/` and `KettoTests/` is picked up automatically. `Info.plist`
  and the entitlements file are membership exceptions.
- `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (classic Swift 6
  semantics; UI classes are annotated `@MainActor` explicitly),
  `SWIFT_STRICT_CONCURRENCY = complete`. Imported C globals that are not
  concurrency-safe (`kAXTrustedCheckOptionPrompt`) are spelled out as literals.
- `SWIFT_OBJC_BRIDGING_HEADER = Ketto/Render/ShaderTypes.h` shares the uniform struct
  between Swift and Metal. It is 16-byte aligned by construction; keep the float and int
  groups padded to multiples of four when adding fields.
- App Sandbox is off (direct-distribution assumption, open question 1 in SPEC). Hardened
  runtime is on, with the audio-input and camera entitlements. Local builds sign ad
  hoc with no team; release builds are signed with Developer ID and notarized by
  `.github/workflows/release.yml`, which overrides `CODE_SIGN_IDENTITY`,
  `CODE_SIGN_STYLE` and `DEVELOPMENT_TEAM` on the command line rather than committing a
  team into the project.
- Sparkle is the only package dependency, linked into the app target and embedded
  automatically by Xcode. The test target does not link it; it gets
  `FRAMEWORK_SEARCH_PATHS` and `LD_RUNPATH_SEARCH_PATHS` entries instead, which is all
  `@testable import Ketto` needs to resolve the Sparkle types `UpdateController`
  mentions.
- `MARKETING_VERSION` (`CFBundleShortVersionString`) and `CURRENT_PROJECT_VERSION`
  (`CFBundleVersion`) are both stamped to the same `X.Y.Z` at release time. Sparkle
  compares `CFBundleVersion` against the appcast's `sparkle:version`, so keeping the two
  keys equal makes that a plain dotted-version comparison. Nothing shipped before this
  scheme, so there is no build carrying the old `CURRENT_PROJECT_VERSION = 1` for it to
  compare against.
- The app icon is generated from `ketto-logo.svg` at the repository root. After
  changing the logo, re-run `swift Scripts/make-appicon.swift` from the root: it rewrites
  the ten PNGs and the `Contents.json` in
  `Ketto/Resources/Assets.xcassets/AppIcon.appiconset`. Each slot is rasterised
  straight from the vector at its exact pixel size rather than downsampled from one large
  bitmap, so the 16 pt icon stays legible. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
  makes the asset compiler inject `CFBundleIconName` at build time, so no icon key is
  needed in `Info.plist`.
- Running the test suite against a **Release** build needs two overrides:
  `ENABLE_TESTABILITY=YES` (Release turns it off, and `@testable import` requires it) and
  `ENABLE_HARDENED_RUNTIME=NO` (library validation otherwise refuses to load an
  ad-hoc-signed `.xctest` bundle into the app, reporting "different Team IDs").
- CI (`.github/workflows/ci.yml`) runs on pull requests and on every push to a
  `claude/**` branch, so a work branch is verified before a PR exists. The engine
  (`Ketto/Models`, `Ketto/Engine`, `Ketto/Capture/KeystrokeMapping.swift`) has no Apple
  framework imports and also builds with the open-source Swift toolchain on Linux.
