import Foundation

/// Which keystroke label is on screen at a given source time: the most recent key, joined with the keys
/// pressed just before it, fading in quickly and out after a hold.
enum KeystrokeDisplay {
    /// Seconds a label stays up after its last key.
    static let hold = 1.5
    static let fadeIn = 0.08
    static let fadeOut = 0.3
    /// Keys closer together than this share one label.
    static let groupGap = 0.5
    static let maxKeysPerLabel = 4

    struct Label: Equatable, Sendable {
        var text: String
        var opacity: Double
    }

    /// `keys` must be sorted by time.
    static func label(keys: [KeyEvent], at t: Double) -> Label? {
        guard let lastIndex = lastIndex(in: keys, atOrBefore: t) else { return nil }
        let last = keys[lastIndex]
        let age = t - last.t
        guard age >= 0, age < hold else { return nil }
        var parts = [last.label]
        var i = lastIndex
        while i > 0, parts.count < maxKeysPerLabel, keys[i].t - keys[i - 1].t < groupGap {
            i -= 1
            parts.insert(keys[i].label, at: 0)
        }
        let fadeInAlpha = min(1, age / fadeIn)
        let fadeOutAlpha = min(1, (hold - age) / fadeOut)
        return Label(text: parts.joined(separator: "  "), opacity: max(0, min(fadeInAlpha, fadeOutAlpha)))
    }

    /// Index of the last key at or before `t` (binary search).
    static func lastIndex(in keys: [KeyEvent], atOrBefore t: Double) -> Int? {
        guard let first = keys.first, first.t <= t else { return nil }
        var lo = 0
        var hi = keys.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keys[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
