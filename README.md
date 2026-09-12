# Ketto

A macOS screen recorder that produces polished videos automatically — smooth cursor
motion, well-timed zooms into the action, and attractive framing, with no manual editing.

Swift 6 · SwiftUI · Metal · ScreenCaptureKit · AVFoundation · VideoToolbox · macOS 14+

## Status

| Milestone | Scope | State |
|---|---|---|
| **v1** Vertical slice | Capture → auto-zoom → cursor smoothing → framing → MP4 export | ✅ **Done** |
| **v2** Timeline editor | Manual zoom editing, trim/cut, webcam, aspect presets, masking | Not started |
| **v3** Publishing | YouTube (OAuth + resumable), S3/R2, shareable links | Not started |
| **v4** Auto subtitles | Local Whisper transcription, word-level timing, burn-in | Not started |

v1 is complete and verified: clean build under Swift 6 strict concurrency on Xcode 26.6,
47 unit tests passing, export at 4.94× real time at 1080p60 and 1.59× at 4K60, and every
acceptance criterion in the spec checked on real hardware. Nothing beyond v1 has begun —
no timeline, trim, webcam, aspect presets, masking, publishing or captions exist yet.

## Where to look

Read this file first, then **only the section you need**. The spec is ~450 lines and
almost every task needs one slice of it, not the whole thing.

| File | Lines | What it is | Read when |
|---|---|---|---|
| `README.md` | ~115 | This index: status, build, test, doc map | Always — start here |
| [docs/SPEC.md](docs/SPEC.md) | ~450 | Architecture, data formats, algorithms, all four milestones | Building a feature — read the relevant section only |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | ~120 | How the shipped v1 code behaves: tuning constants, invariants, expected build warnings | Touching existing engine, render, playback or export code |
| [docs/RELEASING.md](docs/RELEASING.md) | ~145 | Signing secrets, how a release is cut, how updates reach users | Setting up CI signing, cutting or debugging a release |

### Picking one section out of the spec

| You need | Section of `docs/SPEC.md` |
|---|---|
| Why the stack is what it is | §2 Stack decision |
| How the pipeline fits together, and the four invariants not to break | §3 Architecture |
| `events.json`, `edit.json`, `.ketto` schemas | §4 Data formats |
| Auto-zoom, cursor smoothing, cursor rendering | §5 Core algorithms |
| **What to build next** — scope and acceptance criteria per milestone | §6 Milestones |
| Permissions, performance targets, testing strategy | §7 Cross-cutting concerns |
| Still undecided | §8 Open questions |

Each milestone in §6 is self-contained: its own in-scope list, explicit non-goals, and
acceptance criteria. To implement a slice, read §6 for that milestone plus whichever of
§3–§5 it touches.

## Build and run

Requires macOS 14+ and Xcode 16+. The project uses synchronized folder groups, so every
file under `Ketto/` and `KettoTests/` is in the build automatically.

The one external dependency is [Sparkle](https://github.com/sparkle-project/Sparkle),
resolved by Swift Package Manager on the first build and pinned in
`Ketto.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

**On Xcode 26+, install the Metal toolchain first** — Apple unbundled it, and this project
compiles `Render/Shaders.metal`, so without it every build fails with `cannot execute tool
'metal'`. One-time, ~690 MB, no `sudo`:

```bash
xcodebuild -downloadComponent MetalToolchain
```

```bash
xcodebuild build -project Ketto.xcodeproj -scheme Ketto -destination 'platform=macOS,arch=arm64'
```

Or open `Ketto.xcodeproj` in Xcode and run the `Ketto` scheme. Signing is ad hoc
with no team, and macOS keys Screen Recording permission to the code signature, so each
rebuild can re-prompt — set your team in the target's Signing settings for a stable
identity.

## Tests

```bash
xcodebuild test -project Ketto.xcodeproj -scheme Ketto -destination 'platform=macOS,arch=arm64'
```

47 tests covering the document schemas and bundle I/O, auto-zoom, cursor smoothing, the
camera path, frame composition, audio alignment, the renderer (golden-frame comparisons
against committed PNGs) and the export pipeline. None of it needs a display, permissions
or a capture. Two opt-in throughput benchmarks are skipped by default — see
`KettoTests/ExportThroughputTests.swift` for how to run them.

Re-record the golden frames after an intentional renderer change:

```bash
TEST_RUNNER_KETTO_UPDATE_GOLDEN=1 xcodebuild test -project Ketto.xcodeproj -scheme Ketto -destination 'platform=macOS,arch=arm64' -only-testing:KettoTests/GoldenFrameTests
```

## Using it

Pick a display, choose microphone and system audio, press Record. The main window hides, a
floating control appears on the recorded display (never captured), and a 3-2-1 countdown
runs. On Stop the project opens in the editor — live preview left, inspector right
(background, padding, corner radius, shadow, cursor size and smoothing, auto-zoom
intensity, motion blur). Space plays, arrow keys step a frame, edits autosave. Export…
(⌘E) renders an MP4 at 1080p/1440p/4K and 30/60 fps.

Projects are `.ketto` packages in `~/Movies/Ketto`, holding the untouched screen
recording (cursor not baked in), microphone and system audio as separate tracks, the event
track, and every editing decision. Source media is never rewritten.

## Releases and updates

Every push to `main` cuts a release: GitHub Actions builds a universal (Apple Silicon and
Intel) app, signs it with Developer ID, notarizes and staples it, and publishes a `.dmg`
for new installs plus a signed archive and a Sparkle `appcast.xml` for everyone already
running it. The latest build is always at

```
https://github.com/boat-builder/ketto/releases/latest/download/Ketto-macos.dmg
```

Installed copies update themselves: Sparkle checks the feed daily, verifies the download
against the EdDSA public key in `Info.plist`, swaps the bundle in place and relaunches.
**Check for Updates…** in the Ketto menu, or the button in the top right of the
recorder, does it on demand. Nothing is ever shown during a recording — a pending update
waits as a badge rather than opening a window that would land in the video.

Two workflows and two docs cover the whole of it:

| File | What it does |
|---|---|
| `.github/workflows/ci.yml` | PR gate: build + the 47 unit tests |
| `.github/workflows/release.yml` | test → version bump + tag → signed, notarized release |
| [docs/RELEASING.md](docs/RELEASING.md) | The seven secrets, the one-time key setup, and how to recover a failed release |
| `Ketto/App/UpdateController.swift` | The app side of updates |

A fresh clone builds and runs with updates simply switched off: `SUPublicEDKey` in
`Info.plist` is a placeholder until `Scripts/generate-sparkle-keys.sh` is run once, and the
app skips starting Sparkle rather than complaining about it. The release workflow refuses
to publish a build that still carries the placeholder.

## Invariants

Break these and the design stops working. Rationale in `docs/SPEC.md` §3.

1. **Persist an event track, not just pixels** — auto-zoom derives from `events.json`,
   never from frame analysis.
2. **Never pre-mix audio** — mic and system audio stay separate on disk. v4 transcription
   depends on this.
3. **Render is a pure function** — `(sources, editDoc, time) -> frame`, shared by preview
   and export, so the two cannot diverge.
4. **Publishing is a protocol** — resolved at the end of the pipeline, destinations
   swappable.
5. **Record with the cursor hidden** and composite our own — this gates cursor smoothing,
   scaling, click highlights, and auto-hide.
