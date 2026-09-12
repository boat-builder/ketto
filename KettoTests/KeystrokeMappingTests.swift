import XCTest
@testable import Ketto

final class KeystrokeMappingTests: XCTestCase {
    func testSpecialKeysAndCharactersMapToDisplayStrings() {
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 36, characters: "\r"), "⏎")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 53, characters: "\u{1B}"), "⎋")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 123, characters: "\u{F702}"), "←")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 96, characters: "\u{F708}"), "F5")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 49, characters: " "), "space")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 1, characters: "s"), "S")
        XCTAssertEqual(KeystrokeMapping.displayString(keyCode: 18, characters: "1"), "1")
        XCTAssertNil(KeystrokeMapping.displayString(keyCode: 200, characters: "\u{F7FF}"), "unknown function keys have no display form")
        XCTAssertNil(KeystrokeMapping.displayString(keyCode: 200, characters: ""))
        XCTAssertNil(KeystrokeMapping.displayString(keyCode: 200, characters: nil))
    }

    func testModifiersAreNamedInCanonicalOrder() {
        let flags: KeystrokeMapping.Modifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(KeystrokeMapping.modifierNames(flags, keyCode: 1), ["ctrl", "opt", "shift", "cmd"])
        XCTAssertEqual(KeystrokeMapping.modifierNames([.function], keyCode: 1), ["fn"])
        XCTAssertEqual(KeystrokeMapping.modifierNames([.function], keyCode: 123), [], "arrow keys carry the function flag on their own")
    }

    func testShortcutsModeKeepsOnlyShortcuts() {
        let plain = KeystrokeMapping.keyEvent(t: 1, keyCode: 0, characters: "a", flags: [], mode: .shortcuts)
        XCTAssertNil(plain)
        let shifted = KeystrokeMapping.keyEvent(t: 1, keyCode: 0, characters: "A", flags: [.shift], mode: .shortcuts)
        XCTAssertNil(shifted, "shift-letters are typing, not shortcuts")
        let save = try! XCTUnwrap(KeystrokeMapping.keyEvent(t: 1, keyCode: 1, characters: "s", flags: [.command], mode: .shortcuts))
        XCTAssertEqual(save.label, "⌘S")
        let enter = try! XCTUnwrap(KeystrokeMapping.keyEvent(t: 1, keyCode: 36, characters: "\r", flags: [], mode: .shortcuts))
        XCTAssertEqual(enter.chars, "⏎")
        let everything = try! XCTUnwrap(KeystrokeMapping.keyEvent(t: 2, keyCode: 0, characters: "a", flags: [], mode: .everything))
        XCTAssertEqual(everything.label, "A")
        XCTAssertEqual(everything.t, 2)
        XCTAssertNil(KeystrokeMapping.keyEvent(t: 1, keyCode: 1, characters: "s", flags: [.command], mode: .off))
    }
}
