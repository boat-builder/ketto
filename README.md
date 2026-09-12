# Ketto

A macOS screen recorder that produces polished videos automatically — smooth cursor
motion, well-timed zooms into the action, and attractive framing, with no manual editing.

Swift 6 · SwiftUI · Metal · ScreenCaptureKit · AVFoundation · VideoToolbox · macOS 14+

## Status

| Milestone | Scope | State |
|---|---|---|
| **v1** Vertical slice | Capture → auto-zoom → cursor smoothing → framing → MP4 export | ✅ **Done** |
| **v2** Timeline editor | Timeline, manual zooms, trim/cut/speed, webcam, aspect presets, crop, masks, keystrokes, audio clean-up, pause, window/region capture, GIF and presets | ✅ **Implemented** — hardware acceptance pass pending |
| **v3** Publishing | Share links via the user's own Cloudflare R2 ✅ · YouTube (OAuth + resumable) | In progress |
| **v4** Auto subtitles | Local Whisper transcription, word-level timing, burn-in | Not started |

v1 is complete and verified on real hardware: clean build under Swift 6 strict concurrency
on Xcode 26.6, export at 4.94× real time at 1080p60 and 1.59× at 4K60.

v2 is implemented and green on CI (build plus the unit tests, including golden frames that
prove the v1 picture is unchanged). Everything in the v2 scope of `docs/SPEC.md` §6 is
there; what remains is the manual acceptance pass on hardware — timeline frame rate on a
10-minute project, and a look at real recordings with the vertical preset.

Of v3 only the share links exist: an MP4 export can be uploaded to a Cloudflare R2 bucket
on the user's own account and shared as a link that lasts about three days (see "Using
it"). YouTube and captions have not begun.

## Where to look

Read this file first, then **only the section you need**. The spec is ~530 lines and
almost every task needs one slice of it, not the whole thing.

| File | Lines | What it is | Read when |
|---|---|---|---|
| `README.md` | ~230 | This index: status, build, test, doc map | Always — start here |
| [docs/SPEC.md](docs/SPEC.md) | ~530 | Architecture, data formats, algorithms, all four milestones | Building a feature — read the relevant section only |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | ~345 | How the shipped code behaves: tuning constants, invariants, the v2 timeline model, sharing, expected build warnings | Touching existing engine, render, playback, capture, export or sharing code |
| [docs/RELEASING.md](docs/RELEASING.md) | ~145 | Signing secrets, how a release is cut, how updates reach users | Setting up CI signing, cutting or debugging a release |
| `Ketto/Resources/CloudflareBackend/worker.js` | ~390 | The sharing backend the app deploys to the user's Cloudflare account; its header is the HTTP contract | Touching sharing, on either side |

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

138 tests covering the document schemas and bundle I/O, the edit timeline and its
operations, auto-zoom, cursor smoothing, the camera path and framing (including the
vertical-export criterion), frame composition, audio alignment and processing, the
renderer (golden-frame comparisons against committed PNGs plus the mask, camera and
keystroke passes), playback compositions, the editor session (undo grouping, timeline
operations, preset re-optimisation), capture timing, the export pipeline (MP4, HEVC MOV,
GIF, cuts and speed, the camera track), and the sharing client (against an in-process
stand-in for the Worker) and setup files. None of it needs a display, permissions, a
capture or a network. Two of them are opt-in throughput benchmarks, skipped by default —
see `KettoTests/ExportThroughputTests.swift` for how to run them.

The sharing backend itself is tested inside the real Workers runtime, from `WorkerTests/`
(needs Node; nothing there ships in the app):

```bash
cd WorkerTests && npm ci && npm test
```

The same folder runs the Worker locally for manual testing: put `KETTO_TOKEN=dev` in
`WorkerTests/.dev.vars`, run `npx wrangler dev` there, and connect the app to
`http://localhost:8787` with token `dev` through Settings › Sharing › "Connect to an
existing backend".

Most of the engine is plain Swift with no Apple frameworks, so it also builds and tests
with the open-source toolchain on Linux; the Metal, AVFoundation and UI layers need macOS.

Re-record the golden frames after an intentional renderer change:

```bash
TEST_RUNNER_KETTO_UPDATE_GOLDEN=1 xcodebuild test -project Ketto.xcodeproj -scheme Ketto -destination 'platform=macOS,arch=arm64' -only-testing:KettoTests/GoldenFrameTests
```

## Using it

**Launch.** Ketto opens as a floating capture bar at the bottom of the display, not a
window: Display / Window / Region, the source, the microphone, system audio, camera and
keyboard-shortcut toggles (each with its device menu), Record, and a gear that opens the app
window. Close the bar and Ketto lives on in the menu bar; ⌥⌘K brings the bar back, ⇧⌘R
starts a recording from any app, ⇧⌘P pauses it. Settings › Recording can start Ketto in
the menu bar only.

**Record.** Choose what to capture on the bar (the window picker shows live thumbnails;
Region drags a rectangle out on the display), then press Record. The bar and any app window
hide, a countdown runs (3 s by default; 0, 5 or 10 in Settings) and the recording HUD
takes the bar's place on the recorded display, never captured. The HUD pauses and resumes
into one continuous file, and stops.

**Edit.** On Stop the project opens in the editor, in the app window: live preview on a
dark stage, transport, the timeline and the inspector. The timeline shows a filmstrip with the voice and system waveforms, the
clips of the main track, the zoom blocks and the mask blocks. Drag a block to move it, its
edges to retime it, with snapping to the playhead and neighbouring edges; double-click the
zoom track to add a zoom; ⌘B splits the clip at the playhead; ⌫ deletes the selection
(a deleted clip is a cut). The inspector has four tabs — Look (canvas presets 16:9, 9:16, 1:1,
4:5 with fit or fill framing, crop, background, frame), Motion (automatic zooms, cursor
including loop-cursor, motion blur), Overlays (the camera bubble, masks, keystroke display)
and Audio (volumes, voice normalisation, noise removal) — and whatever is selected on the
timeline gets its own card on top. The preview is editable too: drag the crop, a mask's region,
the camera bubble or a zoom's target. ⌘Z / ⇧⌘Z undo and redo; edits autosave.

**Export** (⌘E, or Export… in the editor's toolbar) offers Web (MP4 H.264 1080p60), Social (30 fps, higher bitrate), Hand-off
(ProRes 422 MOV) and GIF presets, or any combination of MP4/MOV/GIF, H.264/HEVC/ProRes,
1080p/1440p/4K and 30/60 fps, saved to a file or copied to the clipboard. ⇧⌘C copies
the frame under the playhead as an image.

**Share Link**, the editor's primary toolbar action and a button in the same sheet, renders
the video as MP4 (the only format the backend serves) and uploads it to a private Cloudflare R2 bucket on your own account, then copies
a link like `https://share.example.com/v/…` that works for about three days; a finished
MP4 export offers the same with Share…. Settings › Sharing sets this up: it needs `wrangler`
installed and logged in to a Cloudflare account that already holds the domain you want
the links on. Enter the domain, copy the one command Ketto shows, run it in Terminal, and
Ketto connects on its own once the Worker answers. Shared Links in the sidebar lists what
is currently shared so a link can be copied again or the video removed early, and a second
Mac can join the same bucket by pasting the address and token.

**The app window** (the gear on the bar, ⌘L, or the menu bar item) holds the Library of
projects grouped by day, Shared Links, and Settings: Recording (frame rate, countdown,
desktop icons, launch behaviour, keyboard capture, storage folder, shortcuts, permissions),
Sharing and Updates. It follows the system appearance; on macOS 26 the bar and the HUD are
Liquid Glass.

Projects are `.ketto` packages in `~/Movies/Ketto` (or the folder chosen in Settings ›
Recording), holding the untouched screen
recording (cursor not baked in), microphone, system audio and camera as separate tracks,
the event track, and every editing decision in `edit.json`. Source media is never
rewritten; the only files Ketto adds are rebuildable derived files (the processed voice
track) in the bundle's `derived/` folder.

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
**Check for Updates…** in the Ketto menu, in the menu bar item, or in Settings › Updates,
does it on demand. Nothing is ever shown during a recording — a pending update
waits as a badge rather than opening a window that would land in the video.

Two workflows and two docs cover the whole of it:

| File | What it does |
|---|---|
| `.github/workflows/ci.yml` | PR gate (and every push to a `claude/**` work branch): build + the unit tests on macOS, and the Worker tests on Linux |
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
