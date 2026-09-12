import Foundation
import CoreGraphics

/// The editing operations the timeline and the inspector perform on an `EditDocument`. Every operation is a
/// pure value transformation so it can be undone by keeping the previous document.
extension EditDocument {
    // MARK: - Main track

    /// Replaces the implicit main track with explicit clips so ids stay stable across edits.
    mutating func materializeClips(sourceDuration: Double) {
        clips = resolvedClips(sourceDuration: sourceDuration)
        cuts = []
    }

    /// Splits the clip containing source time `t` into two. Returns the ids of the left and right halves,
    /// or nil when `t` is not strictly inside a clip (leaving less than `Clip.minimumDuration` on a side).
    @discardableResult
    mutating func splitClip(atSource t: Double, sourceDuration: Double) -> (left: String, right: String)? {
        materializeClips(sourceDuration: sourceDuration)
        guard let index = clips.firstIndex(where: { t > $0.sourceStart + Clip.minimumDuration && t < $0.sourceEnd - Clip.minimumDuration }) else { return nil }
        let clip = clips[index]
        let right = Clip(id: Self.newID("clip"), sourceStart: t, sourceEnd: clip.sourceEnd, speed: clip.speed)
        clips[index].sourceEnd = t
        clips.insert(right, at: index + 1)
        return (clip.id, right.id)
    }

    /// Removes a clip (a cut). The last remaining clip cannot be removed.
    @discardableResult
    mutating func deleteClip(id: String, sourceDuration: Double) -> Bool {
        materializeClips(sourceDuration: sourceDuration)
        guard clips.count > 1, let index = clips.firstIndex(where: { $0.id == id }) else { return false }
        clips.remove(at: index)
        return true
    }

    /// Moves a clip's in and/or out point, in source seconds. Edges never cross a neighbouring clip or the
    /// recording's bounds, and a clip keeps at least `Clip.minimumDuration`.
    mutating func trimClip(id: String, sourceStart: Double? = nil, sourceEnd: Double? = nil, sourceDuration: Double) {
        materializeClips(sourceDuration: sourceDuration)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? clips[index - 1].sourceEnd : 0
        let upper = index + 1 < clips.count ? clips[index + 1].sourceStart : max(sourceDuration, clips[index].sourceEnd)
        var clip = clips[index]
        if let sourceStart {
            clip.sourceStart = min(max(sourceStart, lower), clip.sourceEnd - Clip.minimumDuration)
        }
        if let sourceEnd {
            clip.sourceEnd = max(min(sourceEnd, upper), clip.sourceStart + Clip.minimumDuration)
        }
        clips[index] = clip
    }

    mutating func setClipSpeed(id: String, speed: Double, sourceDuration: Double) {
        materializeClips(sourceDuration: sourceDuration)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].speed = Clip.clampedSpeed(speed)
    }

    /// Merges a clip with the one after it when they are contiguous in the recording (undoing a split).
    @discardableResult
    mutating func joinClipWithNext(id: String, sourceDuration: Double) -> Bool {
        materializeClips(sourceDuration: sourceDuration)
        guard let index = clips.firstIndex(where: { $0.id == id }), index + 1 < clips.count else { return false }
        let next = clips[index + 1]
        guard abs(next.sourceStart - clips[index].sourceEnd) < 1e-6 else { return false }
        clips[index].sourceEnd = next.sourceEnd
        clips.remove(at: index + 1)
        return true
    }

    // MARK: - Zooms

    static let minimumZoomDuration = 0.4

    /// Adds a manual zoom. Manual zooms survive regeneration.
    @discardableResult
    mutating func addZoom(start: Double, duration: Double, target: SIMD2<Double>, scale: Double, easing: Easing = .easeInOutCubic) -> Zoom {
        let zoom = Zoom(
            id: Self.newID("zoom"),
            start: max(0, start),
            duration: max(Self.minimumZoomDuration, duration),
            target: SIMD2(min(max(target.x, 0), 1), min(max(target.y, 0), 1)),
            scale: min(max(scale, 1.05), 6),
            easing: easing,
            userModified: true
        )
        zooms.append(zoom)
        zooms.sort { $0.start < $1.start }
        return zoom
    }

    /// Edits a zoom in place and marks it user-modified.
    mutating func updateZoom(id: String, _ body: (inout Zoom) -> Void) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = zooms[index]
        body(&zoom)
        zoom.duration = max(Self.minimumZoomDuration, zoom.duration)
        zoom.scale = min(max(zoom.scale, 1.05), 6)
        zoom.target = SIMD2(min(max(zoom.target.x, 0), 1), min(max(zoom.target.y, 0), 1))
        zoom.userModified = true
        zooms[index] = zoom
        zooms.sort { $0.start < $1.start }
    }

    mutating func deleteZoom(id: String) {
        zooms.removeAll { $0.id == id }
    }

    /// Moves a zoom to a new start, keeping its duration and never crossing its neighbours or `limit`.
    mutating func moveZoom(id: String, toStart start: Double, limit: Double) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        let zoom = zooms[index]
        let lower = index > 0 ? zooms[index - 1].end : 0
        let upper = index + 1 < zooms.count ? zooms[index + 1].start : max(limit, zoom.end)
        var newStart = min(max(start, lower), upper - zoom.duration)
        if newStart < lower { newStart = lower } // slot narrower than the block: pin to its left edge
        updateZoom(id: id) { $0.start = max(0, newStart) }
    }

    /// Moves a zoom's edges, in source seconds, within its neighbours and `limit`.
    mutating func trimZoom(id: String, start: Double? = nil, end: Double? = nil, limit: Double) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? zooms[index - 1].end : 0
        let upper = index + 1 < zooms.count ? zooms[index + 1].start : max(limit, zooms[index].end)
        updateZoom(id: id) { zoom in
            var newStart = zoom.start
            var newEnd = zoom.end
            if let start { newStart = min(max(start, lower), newEnd - Self.minimumZoomDuration) }
            if let end { newEnd = max(min(end, upper), newStart + Self.minimumZoomDuration) }
            zoom.start = newStart
            zoom.duration = newEnd - newStart
        }
    }

    // MARK: - Masks

    @discardableResult
    mutating func addMask(kind: MaskKind, rect: CGRect, start: Double = 0, end: Double? = nil) -> Mask {
        let mask = Mask(id: Self.newID("mask"), kind: kind, rect: rect, start: start, end: end)
        masks.append(mask)
        return mask
    }

    mutating func updateMask(id: String, _ body: (inout Mask) -> Void) {
        guard let index = masks.firstIndex(where: { $0.id == id }) else { return }
        var mask = masks[index]
        body(&mask)
        mask.rect = Mask.sanitized(mask.rect)
        mask.start = max(0, mask.start)
        if let end = mask.end, end < mask.start + 0.1 { mask.end = mask.start + 0.1 }
        masks[index] = mask
    }

    mutating func deleteMask(id: String) {
        masks.removeAll { $0.id == id }
    }

    // MARK: - Canvas

    /// Applies an aspect preset. Vertical, square and portrait presets switch to `fill` framing so the
    /// recording fills the frame; 16:9 goes back to `fit`.
    mutating func applyCanvasPreset(_ name: String) {
        guard let preset = CanvasSpec.preset(name) else { return }
        canvas = preset
    }

    // MARK: - Ids

    static func newID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
