import XCTest
@testable import Recordito

final class DocumentTests: XCTestCase {
    func testEditDocumentDecodesEmptyObjectToDefaults() throws {
        let doc = try EditDocument.decode(Data("{}".utf8))
        XCTAssertEqual(doc, .default)
        XCTAssertEqual(doc.style.padding, 64)
        XCTAssertEqual(doc.cursor.scale, 1.6)
        XCTAssertNil(doc.captions)
    }

    func testEditDocumentDecodesSpecExample() throws {
        let json = """
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
        """
        let doc = try EditDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.zooms.count, 1)
        XCTAssertEqual(doc.zooms[0].id, "z1")
        XCTAssertEqual(doc.zooms[0].target, SIMD2(0.42, 0.61))
        XCTAssertEqual(doc.zooms[0].easing, .easeInOutCubic)
        XCTAssertEqual(doc.style.background.colors.map(\.hex), ["#1e3a8a", "#9333ea"])
        XCTAssertFalse(doc.zooms[0].userModified)
    }

    func testEditDocumentRoundTrip() throws {
        var doc = EditDocument.default
        doc.zooms = [Zoom(id: "z1", start: 1, duration: 2, target: SIMD2(0.3, 0.7), scale: 2.5, easing: .easeOutCubic, userModified: true)]
        doc.style.background = BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#112233")!], angle: 90)
        let data = try doc.encodedData()
        let decoded = try EditDocument.decode(data)
        XCTAssertEqual(decoded, doc)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"captions\" : null"))
        XCTAssertTrue(text.contains("\"target\" : [") || text.contains("\"target\":["))
    }

    func testUnknownEasingAndCursorTypeFallBack() throws {
        let json = """
        { "zooms": [ { "id": "a", "start": 0, "duration": 1, "target": [0.5, 0.5], "easing": "bouncy" } ] }
        """
        let doc = try EditDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.zooms[0].easing, .easeInOutCubic)
        let events = try EventsDocument.decode(Data("{ \"cursor\": [ { \"t\": 0, \"x\": 1, \"y\": 2, \"type\": \"laser\" } ] }".utf8))
        XCTAssertEqual(events.cursor[0].type, .arrow)
    }

    func testEventsDocumentDecodesSpecExampleAndRoundTrips() throws {
        let json = """
        {
          "version": 1,
          "recordingStart": 1757606400.123,
          "display": { "id": 1, "width": 3456, "height": 2234, "scale": 2.0 },
          "cursor": [ { "t": 0.016, "x": 1200, "y": 800, "type": "arrow" } ],
          "clicks": [ { "t": 1.242, "x": 1200, "y": 800, "button": "left", "phase": "down" } ],
          "keys":   [ { "t": 2.100, "chars": "⌘S", "modifiers": ["cmd"] } ],
          "focus":  [ { "t": 0.0, "bundleId": "com.apple.Safari", "frame": [0, 0, 1440, 900] } ]
        }
        """
        let doc = try EventsDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.display.width, 3456)
        XCTAssertEqual(doc.cursor.first?.type, .arrow)
        XCTAssertEqual(doc.clicks.first?.phase, .down)
        XCTAssertEqual(doc.keys.first?.chars, "⌘S")
        XCTAssertEqual(doc.focus.first?.rect, CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(doc.duration, 2.1, accuracy: 1e-9) // derived from the last event when missing
        let decoded = try EventsDocument.decode(doc.encodedData())
        XCTAssertEqual(decoded, doc)
    }

    func testColorHexParsing() {
        XCTAssertEqual(RGBAColor(hex: "#ff8000")?.hex, "#ff8000")
        XCTAssertEqual(RGBAColor(hex: "ff800080")?.alpha ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBAColor(hex: "#12"))
    }

    func testBundleReadWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecorditoTests-\(UUID().uuidString)")
        let bundle = try RecordingBundle.create(at: dir.appendingPathComponent("Demo.recordito"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(bundle.readEdit(), .default)
        let events = Fixtures.demoEvents()
        try bundle.write(events: events)
        var edit = EditDocument.default
        edit.style.padding = 32
        try bundle.write(edit: edit)
        XCTAssertEqual(try bundle.readEvents(), events)
        XCTAssertEqual(bundle.readEdit().style.padding, 32)
        XCTAssertEqual(bundle.name, "Demo")
        XCTAssertFalse(bundle.hasMicTrack)
    }
}
