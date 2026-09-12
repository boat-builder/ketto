import Foundation
@testable import Ketto

enum Fixtures {
    static let display = DisplayInfo(id: 1, width: 3456, height: 2234, scale: 2)

    /// A synthetic "app demo" event track: cursor drifts, clicks in two areas, one focus record.
    static func demoEvents(duration: Double = 20) -> EventsDocument {
        var cursor: [CursorSample] = []
        var t = 0.0
        var position = SIMD2<Double>(400, 300)
        let stops: [(Double, SIMD2<Double>)] = [(2.0, SIMD2(1200, 800)), (6.0, SIMD2(1300, 850)), (10.0, SIMD2(2600, 1700)), (14.0, SIMD2(2650, 1750)), (18.0, SIMD2(900, 500))]
        for (stopTime, target) in stops {
            let steps = Int((stopTime - t) * 60)
            let startPosition = position
            for i in 0..<max(steps, 1) {
                let u = Double(i + 1) / Double(max(steps, 1))
                position = startPosition + (target - startPosition) * u
                cursor.append(CursorSample(t: t + Double(i + 1) / 60, x: position.x, y: position.y, type: .arrow))
            }
            t = stopTime
        }
        let clicks: [ClickEvent] = [
            ClickEvent(t: 2.2, x: 1200, y: 800, button: .left, phase: .down),
            ClickEvent(t: 2.3, x: 1200, y: 800, button: .left, phase: .up),
            ClickEvent(t: 6.1, x: 1300, y: 850, button: .left, phase: .down),
            ClickEvent(t: 6.2, x: 1300, y: 850, button: .left, phase: .up),
            ClickEvent(t: 10.4, x: 2600, y: 1700, button: .left, phase: .down),
            ClickEvent(t: 10.5, x: 2600, y: 1700, button: .left, phase: .up),
            ClickEvent(t: 14.1, x: 2650, y: 1750, button: .left, phase: .down),
            ClickEvent(t: 14.2, x: 2650, y: 1750, button: .left, phase: .up),
        ]
        let focus = [FocusEvent(t: 0, bundleId: "com.example.demo", frame: CGRect(x: 200, y: 100, width: 3000, height: 2000))]
        return EventsDocument(recordingStart: 1_757_606_400.123, duration: duration, display: display, cursor: cursor, clicks: clicks, keys: [], focus: focus)
    }
}
