# Recordito — Implementation Spec

**Status:** v1 shipped; v2 not started
**Target platform:** macOS 14.0+
**Stack:** Swift 6 / SwiftUI / Metal / ScreenCaptureKit / AVFoundation / VideoToolbox

---

## 1. What we're building

A macOS screen recorder that produces *polished* videos automatically — the kind of output
that normally takes a video editor an hour. Record a screen, and the app generates smooth
cursor motion, well-timed zooms into the action, and an attractive framed presentation,
with no manual editing required.

Reference product: [Screen Studio](https://screen.studio). Closest open-source prior art:
[Cap](https://github.com/CapSoftware/cap) (Rust/Tauri/wgpu) — useful for pipeline ideas,
not a codebase we're deriving from.

### The core engineering thesis

**Capture is easy. The render pipeline is the product.**

ScreenCaptureKit hands us frames, system audio, window filtering, and cursor metadata
essentially for free. A capture prototype is a few days' work. What separates this from
QuickTime is auto-zoom quality, cursor spline smoothing, motion blur, and compositing
backgrounds and shadows at 4K60. That is where the effort and the differentiation live.
Plan staffing and schedule around the renderer, not the recorder.

---

## 2. Stack decision and rationale

**Chosen: Swift + SwiftUI + Metal, macOS-only.**

Everything we need is first-party — ScreenCaptureKit for capture, AVFoundation for
mic/camera, VideoToolbox for hardware encode, Metal for compositing. No FFI layer, no
bundled ffmpeg, no Electron runtime, small signed binary, and hardware encode for free.

ScreenCaptureKit already forces a modern OS baseline (Screen Studio itself requires
Ventura 13.1+), so we target **macOS 14+** without guilt and use current SwiftUI APIs
rather than writing compatibility shims.

### Rejected alternatives

| Option | Why not |
|---|---|
| Rust + Tauri + wgpu | The right call *if* we wanted Windows. We don't. Buys a portable render pipeline at the cost of substantial FFI glue for every macOS capture API. |
| Electron + TypeScript | Fastest UI iteration, but you fight the runtime on a 4K60 video pipeline. Wrong tool for this workload. |
| Cross-platform incl. Linux | PipeWire/X11 capture is still fragmented. Not worth it at this stage. |

### Is a timeline editor feasible in SwiftUI?

Yes — this was explicitly de-risked before committing to the stack.

- **The inspector is free.** `Form`, `Slider`, `ColorPicker`, `Picker`, `Stepper`,
  `DisclosureGroup`, popovers, SF Symbols, `.regularMaterial`. This is most of the
  editor's surface area and needs no custom drawing.
- **The preview canvas** is an `MTKView` bridged via `NSViewRepresentable`, running on
  **its own display link**, decoupled from SwiftUI's update cycle. SwiftUI owning the
  surrounding chrome costs nothing in render performance.
- **The timeline is the one custom component.** It reduces to a single state variable —
  `pointsPerSecond` — plus arithmetic. Clips are shapes with `.offset(x: start * pps)`
  and `.frame(width: duration * pps)`; `DragGesture` handles move and edge-trim. Ruler
  ticks, waveforms, and the thumbnail filmstrip go in a SwiftUI `Canvas` (immediate-mode)
  so a long timeline doesn't explode into thousands of views.

Known friction, all minor: snapping/magnetism is hand-rolled (~20 lines of
nearest-candidate rounding); small drag handles need `.contentShape()` to widen hit
areas. If the timeline ever becomes a performance problem, that **one panel** drops to an
AppKit `NSView` with `draw(_:)` and embeds cleanly — the escape hatch costs us nothing
elsewhere.

---

## 3. Architecture

```
┌─ Capture ──────────────────────────────────────────┐
│ ScreenCaptureKit → frames + system audio           │
│ AVFoundation     → mic, camera                     │
│ NSEvent/CGEventTap → clicks, keystrokes, focus     │
└────────────────────────┬───────────────────────────┘
                         ▼
┌─ .recordito bundle (non-destructive) ──────────────┐
│  screen.mov  mic.caf  system.caf  camera.mov       │
│  events.json   ← cursor/click/key track            │
│  edit.json     ← zooms, cuts, style, captions      │
└────────────────────────┬───────────────────────────┘
                         ▼
┌─ Render (Metal) ───────────────────────────────────┐
│  (frames + edit.json + t) → output frame           │
│  ONE path; preview and export differ only in sink  │
└──────────┬────────────────────────┬────────────────┘
           ▼                        ▼
    MTKView preview          VideoToolbox → MP4
                                     ▼
                        ┌─ PublishDestination ───────┐
                        │ .local  .youtube  .s3 ...  │
                        └────────────────────────────┘
```

### The four foundational decisions

These are cheap to honour now and expensive to retrofit. They are the reason later
milestones stay small.

**1. Persist an event track, not just pixels.**
Cursor positions, clicks, keystrokes, and window-focus changes are written to
`events.json` with timestamps. Auto-zoom is derived from *this*, never from analyzing
frames. Highest-leverage decision in the design: zoom detection becomes cheap,
re-runnable with different heuristics, and fully editable after the fact.

**2. Never pre-mix audio.**
Mic and system audio stay as separate files. Costs nothing in v1. Later it is what lets
us transcribe clean voice without system audio bleeding in (v4), and apply noise removal
to the mic alone (v2).

**3. Render is a pure function.**
`(sources, editDoc, time) -> frame`. Preview and export call identical code with
different sinks. Caption burn-in in v4 is one more compositing pass, not a second
renderer. Any divergence between preview and export is a bug.

**4. Publishing is a protocol, resolved at the very end of the pipeline.**

```swift
protocol PublishDestination {
    var displayName: String { get }
    func authenticate() async throws
    func upload(_ file: URL, metadata: VideoMetadata,
                progress: @Sendable (Double) -> Void) async throws -> URL
}
```

v1 ships `LocalFileDestination` only. Everything in v3 slots in behind this.

### CRITICAL: record with the cursor hidden

Set `SCStreamConfiguration.showsCursor = false` and composite our **own** cursor in the
render pipeline from the event track.

If the system cursor is baked into the captured pixels, cursor smoothing, cursor
scaling, click highlights, and auto-hide are all permanently impossible. This single
config flag gates a whole category of features. Also record the cursor *type* (arrow,
I-beam, pointing hand, resize) in the event track so the renderer draws the right glyph.

---

## 4. Data formats

### Project bundle: `Name.recordito/` (a directory, `NSFileWrapper`)

```
Name.recordito/
├── screen.mov          # captured frames, cursor NOT baked in
├── mic.caf             # separate track
├── system.caf          # separate track
├── camera.mov          # v2
├── events.json
├── edit.json
└── thumbnail.png
```

Fully non-destructive: source media is never rewritten, all edits live in `edit.json`.

### `events.json`

```json
{
  "version": 1,
  "recordingStart": 1757606400.123,
  "display": { "id": 1, "width": 3456, "height": 2234, "scale": 2.0 },
  "cursor": [ { "t": 0.016, "x": 1200, "y": 800, "type": "arrow" } ],
  "clicks": [ { "t": 1.242, "x": 1200, "y": 800, "button": "left", "phase": "down" } ],
  "keys":   [ { "t": 2.100, "chars": "⌘S", "modifiers": ["cmd"] } ],
  "focus":  [ { "t": 0.0, "bundleId": "com.apple.Safari", "frame": [0, 0, 1440, 900] } ]
}
```

Coordinates are in source-pixel space. Timestamps are seconds from `recordingStart`.

### `edit.json`

```json
{
  "version": 1,
  "canvas": { "aspect": "16:9", "width": 1920, "height": 1080 },
  "style": {
    "background": { "type": "gradient", "colors": ["#1e3a8a", "#9333ea"], "angle": 135 },
    "padding": 64,
    "cornerRadius": 12,
    "shadow": { "radius": 40, "opacity": 0.35, "y": 20 }
  },
  "cursor": { "scale": 1.6, "smoothing": 0.8, "hideWhenIdle": true, "clickHighlight": true },
  "zooms": [
    { "id": "z1", "start": 1.1, "duration": 3.2,
      "target": [0.42, 0.61], "scale": 2.0, "easing": "easeInOutCubic" }
  ],
  "cuts": [],
  "captions": null
}
```

`target` is normalized (0–1) in source space so it survives resolution changes.
Every field must have a sane default — a missing key is never an error.

---

## 5. Core algorithms

### Auto-zoom generation (from `events.json`)

1. Cluster clicks by time window and spatial radius (start: 1.5s / 300pt, tune later).
2. Each cluster becomes a candidate zoom; target is the cluster centroid.
3. Constrain the target to the focused window's bounds where known — zooming to a point
   inside the active window reads far better than zooming to a bare coordinate.
4. Add lead-in before the first click (~0.4s) so the zoom *arrives* as the user clicks,
   hold through the cluster, then lead out.
5. Merge overlapping candidates; enforce minimum duration and minimum gap between zooms.
6. Suppress zoom during rapid large-distance cursor travel (the user is in transit, not
   working).
7. Clamp the viewport so it never leaves source bounds.

The output is just `zooms` in `edit.json` — plain data the user can override in v2.
Re-running generation with different parameters must be non-destructive to manual edits
(flag user-modified zooms and preserve them).

### Cursor smoothing

1. Resample raw positions to the render framerate.
2. Fit a Catmull-Rom / cubic Hermite spline through the positions.
3. Apply a one-euro filter (or EMA) for jitter, strength driven by `cursor.smoothing`.
4. **Pin spline knots at click events.** The smoothed cursor must be exactly at the real
   click coordinate at the moment of the click — otherwise the video visibly lies about
   what was clicked. Non-negotiable.

### Cursor rendering

Draw from high-resolution cursor assets, not scaled-up 32px system bitmaps — the moment
`cursor.scale > 1` the difference is obvious. Auto-hide fades the cursor out after an
idle threshold and fades it back in on movement.

---

## 6. Milestones

### v1 — Vertical slice ✅ Done

**Goal:** prove the hard part. End-to-end capture → auto-polish → export, with output
good enough to post publicly. Not a shippable product; a de-risked foundation.

**In scope**
- Screen capture via ScreenCaptureKit: display selection, multi-display aware
- System audio + microphone capture, as **separate** tracks
- Event track capture: cursor position + type, clicks, window focus
- `.recordito` bundle read/write; `events.json` and `edit.json` schemas
- Auto-zoom generation
- Cursor smoothing, cursor scaling, custom cursor compositing
- Metal render pipeline: zoom/pan transform, background (solid + gradient), padding,
  rounded corners, drop shadow
- Live preview in `MTKView`
- Minimal inspector: background, padding, corner radius, shadow, cursor scale,
  zoom intensity toggle
- Export to MP4 via VideoToolbox, up to 4K60
- Record HUD with countdown and stop control

**Stretch:** motion blur on zoom/pan; click highlight ripple.

**Explicitly out:** timeline UI, webcam, trim/cut, GIF, masking, iOS capture,
transcripts, any form of publishing.

**Acceptance criteria** — all met.
- [x] Record 2 minutes at 4K60 with no dropped frames
- [x] Auto-generated zooms land on the right content without manual correction in a
  typical app-demo recording
- [x] Cursor is visibly smooth; cursor position at click time is pixel-accurate
- [x] Preview and export are visually identical
- [x] Export of a 2-minute 1080p60 recording completes faster than real time — measured
  at 4.94× real time, and 1.59× at 4K60 (`RecorditoTests/ExportThroughputTests`)

Verified on Xcode 26.6 / Swift 6.3.3: clean build under `SWIFT_STRICT_CONCURRENCY =
complete`, 47 unit tests passing, and a manual acceptance pass on real hardware.

**Permissions:** Screen Recording, Microphone. **No Accessibility permission required** —
mouse events come from global `NSEvent` monitors and SCK metadata. Keep it that way;
Accessibility is a scary prompt and v1 does not need it.

---

### v2 — Timeline editor

**Goal:** the user can override every automatic decision, and the app becomes a real
editor.

**In scope**
- Timeline component: time ruler, playhead, scrub, zoom-level control, thumbnail
  filmstrip, audio waveforms
- Zoom blocks: add, delete, move, trim, retime, adjust scale and easing, with snapping
- Trim, cut, split, and speed ramps on the main track
- Webcam capture and overlay: shape, position, size, border; auto-dodge the cursor
- Aspect presets — 16:9, 9:16 vertical, 1:1, 4:5 — with zooms re-optimized for the crop
- Crop
- Masking: blur regions for sensitive info, and highlight masks for emphasis
- Keystroke capture and on-screen shortcut display *(introduces the Accessibility
  permission — make it opt-in, requested only when this feature is enabled)*
- Cursor auto-hide, loop-cursor (return to start position for seamless loops)
- Motion blur, click highlights (if not landed in v1)
- Audio: voice normalization, background noise removal
- Pause/resume recording into a single file
- Hide desktop icons while recording
- Window and region capture modes
- GIF export; export presets (web / social / hand-off to an editor)
- Copy to clipboard

**Acceptance criteria**
- Timeline stays at 60fps while scrubbing a 10-minute project
- Every automatic v1 decision is user-overridable, and manual edits survive
  re-running auto-generation
- Vertical export produces sensible framing without manual re-targeting of every zoom

---

### v3 — Publishing (YouTube / S3 / R2)

**Goal:** stop → upload → shareable unlisted link in the clipboard. Loom-style.

**In scope**
- `PublishDestination` implementations behind the v1 protocol
- `S3Destination` — S3 / Cloudflare R2, user-supplied bucket, plus a minimal share page
- `YouTubeDestination` — OAuth 2.0 + resumable upload, video set to unlisted
- OAuth token storage in Keychain; token refresh; disconnect/revoke
- Background upload queue: resumable, survives app restart, app stays usable mid-upload
- Progress UI; copy-link-on-complete

#### YouTube: read this before planning

- **API keys do not work for uploads.** Uploads require OAuth 2.0 with the
  `youtube.upload` scope. For a desktop app the standard is the authorization-code flow
  with **PKCE** and a loopback redirect (`http://127.0.0.1:<port>`). The out-of-band
  copy-paste-a-code flow was discontinued in 2022.
- Google issues desktop apps a "client secret" that is **not** actually secret. That is
  expected for native public clients and is exactly why PKCE exists. Do not build any
  security assumption on it.
- **Resumable upload protocol is mandatory**, not optional — these are large 4K files on
  consumer connections.

> **⚠️ Schedule risk — start this in parallel with v1, not after.**
>
> `youtube.upload` is a **Restricted** scope. Videos uploaded via `videos.insert` from an
> **unverified API project are force-locked to private**, and that is not appealable
> per-video — the video must be re-uploaded after verification. The unlisted-URL feature
> **does not function at all** until Google audits the project.
>
> Quota is also tight: 10,000 units/day by default, with `videos.insert` historically
> billed at ~1,600 units (≈6 uploads/day). Current docs appear to have moved uploads to a
> separate ~100-calls/day bucket, so this is somewhat in flux — either way the ceiling is
> low, and the remedy is the same manual audit form. There is no pay-for-quota option and
> no guaranteed approval.
>
> The audit is free but runs at Google's pace. It is the long pole on this milestone and
> it is the one item here that is not code we control. **File it during v1.**

This risk is the main reason publishing is a protocol rather than welded into export: if
the audit stalls or is refused, `S3Destination` ships and the feature still lands.

**Acceptance criteria**
- Upload survives app restart and network interruption
- Link reaches the clipboard automatically on completion
- Revoking access in Google account settings is handled gracefully, not with a crash

---

### v4 — Auto subtitles

**Goal:** local, private, automatic captions. No audio leaves the machine.

**In scope**
- `TranscriptionProvider` protocol returning **word-level** timestamps
- WhisperKit (Whisper via CoreML, Metal-accelerated) as the implementation — a Swift
  package dependency rather than a C++ integration. Apple's `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition` is the zero-dependency fallback.
- `CaptionTrack` in `edit.json`
- Line segmentation: group words into caption lines by punctuation, max characters, and
  max duration. Word-level timestamps are what make timing feel correct rather than
  approximate.
- Caption styling (font, size, position, background) and a burn-in compositing pass
- `.srt` / `.vtt` sidecar export
- Manual caption text editing in the timeline

Transcription runs on **`mic.caf` alone** — which works only because of foundational
decision #2. This is the entire debt v1 owes this milestone.

**Acceptance criteria**
- A 10-minute recording transcribes in well under real time on Apple Silicon
- Captions are legible at 9:16 without manual repositioning
- No network access during transcription (verifiable)

---

## 7. Cross-cutting concerns

### Permissions

| Permission | Needed for | Milestone |
|---|---|---|
| Screen Recording | ScreenCaptureKit | v1 |
| Microphone | Voice track | v1 |
| Camera | Webcam overlay | v2 |
| Accessibility | Keystroke capture (`CGEventTap`) | v2, opt-in only |

Request each permission lazily, at the moment the feature is first used, with an
explanation of why. Never request Accessibility at launch.

### Performance targets (baseline: M1, 8GB)

- Capture: <15% CPU at 4K60, zero dropped frames
- Preview: ≥30fps at fit-to-window while scrubbing
- Export: faster than real time at 1080p60; ≥0.5× real time at 4K60
- Memory: bounded and independent of recording length — never hold decoded video in RAM

### Testing

- **Golden-frame tests** for the renderer: fixed `events.json` + `edit.json` → rendered
  frame compared against a committed reference image. This is the primary defence against
  render regressions and against preview/export divergence.
- **Algorithm unit tests** on synthetic event tracks for auto-zoom clustering and cursor
  smoothing — deterministic, no capture required.
- **Fixture recordings** committed as small `.recordito` bundles so the whole team can
  iterate on the renderer without recording anything.

### Non-goals (for now)

iOS/iPad device capture over USB · device mockup frames · background music library ·
shareable-link comments and collaboration · Windows and Linux · team accounts.

---

## 8. Open questions

1. Distribution: direct download with Developer ID + notarization, or Mac App Store?
   The App Store sandbox has implications for `CGEventTap` and user-supplied S3 buckets —
   decide before v3.
2. Do we ship our own share-page hosting for `S3Destination`, or hand the user a raw
   object URL?
3. Auto-zoom tuning: ship one "intensity" slider, or expose the underlying clustering
   parameters to power users?
4. Licensing and pricing model — affects whether v3 needs any server-side component at
   all.
