# Recordito

A macOS screen recorder that produces polished videos automatically — smooth cursor
motion, well-timed zooms into the action, and attractive framing, with no manual editing.

**Status:** Planning. See [SPEC.md](SPEC.md) for the full implementation spec.

## Stack

Swift 6 · SwiftUI · Metal · ScreenCaptureKit · AVFoundation · VideoToolbox
Target: macOS 14.0+

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
