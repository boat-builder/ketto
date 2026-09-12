# Recordito

A macOS screen recorder that produces polished videos automatically — smooth cursor
motion, well-timed zooms into the action, and attractive framing, with no manual editing.

**Status:** v1 (the vertical slice) is implemented end to end: capture → auto-zoom →
cursor smoothing → framing → live preview → MP4 export. It builds under Swift 6 strict
concurrency on Xcode 26.6, the unit tests pass (47), the app launches, and export
throughput is measured at 4.94× real time at 1080p60 and 1.59× at 4K60. What is still
open is the part that needs a real recording, and so a person to grant the permission
prompts: dropped frames and CPU at 4K60, auto-zoom targeting, and cursor accuracy. See
[docs/V1-STATUS.md](docs/V1-STATUS.md) for the verification results and the manual
checklist, and [SPEC.md](SPEC.md) for the full implementation spec.

## Stack

Swift 6 · SwiftUI · Metal · ScreenCaptureKit · AVFoundation · VideoToolbox
Target: macOS 14.0+

## Build and run

Requirements: macOS 14 or later, Xcode 16 or later (the project uses synchronized folder
groups, so every file under `Recordito/` and `RecorditoTests/` is part of the build).

**On Xcode 26 and later, install the Metal toolchain first.** Apple unbundled it from the
Xcode app, and this project compiles `Render/Shaders.metal`, so without it every build
fails with `cannot execute tool 'metal' due to missing Metal Toolchain`:

```bash
xcodebuild -downloadComponent MetalToolchain
```

It is a ~690 MB one-time download and needs no `sudo`; `xcodebuild -showComponent
MetalToolchain` reports whether it is already installed.

```bash
xcodebuild build -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64'
```

Or open `Recordito.xcodeproj` in Xcode and run the `Recordito` scheme.

The project is signed ad hoc with no team. macOS ties the Screen Recording permission
to the code signature, so an ad-hoc build may be asked for permission again after a
rebuild. Set your development team in the target's Signing settings for a stable
identity.

## Permissions

| Permission | When it is requested | Notes |
|---|---|---|
| Screen Recording | The first time you press Record | If macOS has already denied it, the recorder shows a button that opens System Settings → Privacy & Security → Screen Recording. Relaunch Recordito after granting access. |
| Microphone | When a recording starts with the microphone enabled | Turn the microphone off in the recorder to avoid the prompt entirely. |

Accessibility is never requested: mouse events come from global `NSEvent` monitors and
window-focus changes from the window server.

## Using it

1. **Record.** Pick a display, choose whether to record the microphone and system audio,
   and press Record. The main window hides, a floating control appears at the bottom of
   the recorded display, and a 3-2-1 countdown runs. Press Stop on the floating control
   when you are done. The control never appears in the recording.
2. **Edit.** The project opens in the editor: a live preview on the left and the inspector
   on the right (background, frame padding and corner radius, shadow, cursor size and
   smoothing, auto-zoom intensity, motion blur). Space plays and pauses; the arrow keys
   step one frame. Every change is saved to the project's `edit.json` automatically.
3. **Export.** Export… (⌘E) renders an MP4 (H.264 High profile, AAC audio) at 1080p,
   1440p or 4K and 30 or 60 fps, then reveals it in the Finder.

Projects are saved as `.recordito` packages in `~/Movies/Recordito`. A package contains
the untouched screen recording (`screen.mov`, cursor not baked in), the microphone and
system audio as separate tracks (`mic.caf`, `system.caf`), the event track
(`events.json`) and every editing decision (`edit.json`). Source media is never
rewritten. Open a package from the recorder's Recent Projects list, with Open Project…
(⌘O), or by double-clicking it in the Finder.

## Tests

```bash
xcodebuild test -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64'
```

The suite covers the document schemas and bundle I/O, auto-zoom generation, cursor
smoothing, the camera path, frame composition, audio alignment, the renderer
(golden-frame comparisons against committed reference PNGs) and the export pipeline on a
synthetic recording. Nothing in the suite needs a display, permissions, or a capture.

Re-record the golden frames after an intentional renderer change:

```bash
TEST_RUNNER_RECORDITO_UPDATE_GOLDEN=1 xcodebuild test -project Recordito.xcodeproj -scheme Recordito -destination 'platform=macOS,arch=arm64' -only-testing:RecorditoTests/GoldenFrameTests
```

`ExportThroughputTests` exports two synthetic minutes at 1080p60 and 4K60 and asserts the
speed targets. It is skipped unless `RECORDITO_RUN_BENCHMARKS=1` and wants a Release
build; the exact invocation is in [docs/V1-STATUS.md](docs/V1-STATUS.md).

## Roadmap

| | Milestone | Scope |
|---|---|---|
| **v1** | Vertical slice | Capture → auto-zoom → cursor smoothing → framing → MP4 export |
| **v2** | Timeline editor | Manual zoom editing, trim/cut, webcam, aspect presets, masking |
| **v3** | Publishing | YouTube (OAuth + resumable) and S3/R2, shareable unlisted links |
| **v4** | Auto subtitles | Local Whisper transcription, word-level timing, burn-in |

## Key design decisions

1. **Persist an event track, not just pixels** — cursor, clicks, and focus changes go to
   `events.json`; auto-zoom derives from that, never from frame analysis.
2. **Never pre-mix audio** — mic and system audio stay separate on disk.
3. **Render is a pure function** — `(sources, editDoc, time) -> frame`, shared by preview
   and export.
4. **Publishing is a protocol** — resolved at the end of the pipeline, so destinations are
   swappable.
5. **Record with the cursor hidden** (`showsCursor = false`) and composite our own — this
   flag gates cursor smoothing, scaling, click highlights, and auto-hide.

Rationale for all of the above is in [SPEC.md](SPEC.md).
