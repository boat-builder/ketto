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

141 tests covering the document schemas and bundle I/O, the edit timeline and its
operations, auto-zoom, cursor smoothing, the camera path and framing (including the
vertical-export criterion), frame composition, audio alignment and processing, the
renderer (golden-frame comparisons against committed PNGs plus the mask, camera and
keystroke passes), playback compositions, the editor session (undo grouping, timeline
operations, preset re-optimisation), capture timing, the export pipeline (MP4, HEVC MOV,
GIF, cuts and speed, the camera track), the sharing client (against an in-process stand-in
for the Worker), the setup files and the agent prompt. None of it needs a display,
permissions, a capture or a network. Two of them are opt-in throughput benchmarks, skipped
by default — see `KettoTests/ExportThroughputTests.swift` for how to run them.

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

**Record.** Pick a display, a window or a region, choose microphone, system audio and
camera, optionally keyboard-shortcut capture (asks for Accessibility access, only then)
and hiding the desktop icons, then press Record. Switching the camera on asks for camera
access and puts a floating bubble with your picture on the display — the bubble the
video will show, mirrored like a mirror. Drag it wherever it is least in the way: it is
never captured, it stays through the countdown and the recording showing exactly what
is being recorded, and where you leave it is where the bubble starts out in the edit.
The main window hides, a floating control appears on the recorded display (never
captured), and a 3-2-1 countdown runs, during which the camera warms up so its track
starts with the first frame. The control pauses and resumes the recording into one
continuous file, and stops it.

**Edit.** On Stop the project opens in the editor: live preview, transport, the timeline
and the inspector. The timeline shows a filmstrip with the voice and system waveforms, the
clips of the main track, the zoom blocks and the mask blocks. Drag a block to move it, its
edges to retime it, with snapping to the playhead and neighbouring edges; double-click the
zoom track to add a zoom; ⌘B splits the clip at the playhead; ⌫ deletes the selection
(a deleted clip is a cut). The inspector covers canvas presets (16:9, 9:16, 1:1, 4:5; fit
or fill framing), crop, background, frame, cursor (including loop-cursor), automatic
zooms, the camera bubble (shape, size, corner radius, position by corner preset or
horizontal and vertical sliders, border, shadow, mirror, moving out of the cursor's way),
masks, keystroke display, audio (volumes, voice normalisation, noise removal) and
effects. The preview is editable too: drag the crop, a mask's region, the camera bubble
or a zoom's target. ⌘Z / ⇧⌘Z undo and redo; edits autosave.

**Export** (⌘E) offers Web (MP4 H.264 1080p60), Social (30 fps, higher bitrate), Hand-off
(ProRes 422 MOV) and GIF presets, or any combination of MP4/MOV/GIF, H.264/HEVC/ProRes,
1080p/1440p/4K and 30/60 fps, saved to a file or copied to the clipboard. ⇧⌘C copies
the frame under the playhead as an image.

**Share Link**, in the same sheet, renders the video as MP4 (the only format the backend
serves) and uploads it to a private Cloudflare R2 bucket on your own account, then copies
a link like `https://share.example.com/v/…` that works for about three days; a finished
MP4 export offers the same with Share…. Settings › Sharing sets this up through your coding
agent: it needs `wrangler` on this Mac, logged in to a Cloudflare account that already holds
the domain you want the links on. Enter the domain, press Copy Prompt, paste the prompt into
your agent (Claude Code, Codex, Cursor…), and Ketto connects on its own once the Worker
answers. The prompt names the folder Ketto wrote the Worker and its configuration to and
spells out every wrangler step; the `setup.sh` in that folder runs the same steps for anyone
who would rather use Terminal. The same page lists what is currently shared so a link can be
copied again or the video removed early, and a second Mac can join the same bucket by
pasting the address and token.

Projects are `.ketto` packages in `~/Movies/Ketto`, holding the untouched screen
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
**Check for Updates…** in the Ketto menu, or the button in the top right of the
recorder, does it on demand. Nothing is ever shown during a recording — a pending update
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
