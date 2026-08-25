import XCTest
@testable import Toolbelt

@MainActor
final class TerminalInputTests: XCTestCase {

    private func makeInput() -> (TerminalInput, () -> [UInt8]) {
        var sent: [UInt8] = []
        let input = TerminalInput { data in sent.append(contentsOf: data) }
        return (input, { sent })
    }

    // MARK: - the bug this type exists to fix

    func testArmedControlAppliesToALetterTypedOnTheSystemKeyboard() {
        // THE REGRESSION: the modifier used to live inside the accessory row,
        // so arming Ctrl could only ever modify the row's own buttons. Ctrl+A,
        // Ctrl+K and Ctrl+W — the reason sticky Ctrl exists — were unreachable.
        let (input, sent) = makeInput()
        input.toggleControl()
        input.type("a")
        XCTAssertEqual(sent(), [0x01])
    }

    func testArmedAltPrefixesTypedText() {
        let (input, sent) = makeInput()
        input.toggleAlt()
        input.type("b")
        XCTAssertEqual(sent(), [0x1B, 0x62])
    }

    func testWithoutAModifierTextGoesThroughUnchanged() {
        let (input, sent) = makeInput()
        input.type("ls -la")
        XCTAssertEqual(sent(), Array("ls -la".utf8))
    }

    // MARK: - modifier lifecycle

    func testArmingIsOneShot() {
        let (input, sent) = makeInput()
        input.toggleControl()
        input.type("c")
        input.type("c")
        // First is Ctrl-C, second is a plain "c" — a modifier applies to one
        // keystroke unless locked.
        XCTAssertEqual(sent(), [0x03] + Array("c".utf8))
        XCTAssertEqual(input.modifier, .none)
    }

    func testTapTwiceToLockForRepeatedUse() {
        // Ctrl-C, Ctrl-C, Ctrl-C without re-arming each time.
        let (input, sent) = makeInput()
        input.toggleControl()
        input.toggleControl()
        XCTAssertTrue(input.modifier.isLocked)

        input.type("c")
        input.type("c")
        input.type("c")
        XCTAssertEqual(sent(), [0x03, 0x03, 0x03])
        XCTAssertTrue(input.modifier.isLocked, "lock must survive use")
    }

    func testThirdTapClearsTheLock() {
        let (input, _) = makeInput()
        input.toggleControl()
        input.toggleControl()
        input.toggleControl()
        XCTAssertEqual(input.modifier, .none)
    }

    func testSwitchingModifierReplacesRatherThanCombines() {
        // There is no Ctrl+Alt in this UI, and pretending otherwise would send
        // something the user did not ask for.
        let (input, sent) = makeInput()
        input.toggleControl()
        input.toggleAlt()
        XCTAssertTrue(input.modifier.isAlt)
        XCTAssertFalse(input.modifier.isControl)

        input.type("b")
        XCTAssertEqual(sent(), [0x1B, 0x62])
    }

    func testPressingASpecialKeyAlsoConsumesTheModifier() {
        let (input, _) = makeInput()
        input.toggleControl()
        input.press(.tab)
        XCTAssertEqual(input.modifier, .none, "an armed modifier must not linger")
    }

    // MARK: - refusing to lose keystrokes

    func testAnImpossibleControlComboSendsTheCharacterPlainly() {
        // There is no Ctrl+1. Dropping the keystroke would silently swallow
        // what someone typed, which is worse than ignoring the modifier.
        let (input, sent) = makeInput()
        input.toggleControl()
        input.type("1")
        XCTAssertEqual(sent(), Array("1".utf8))
    }

    func testAModifierAppliesToTheFirstCharacterOnlyNotTheWholeWord() {
        // Autocorrect and paste deliver several characters at once. A modifier
        // is one keystroke, so the remainder must still arrive.
        let (input, sent) = makeInput()
        input.toggleControl()
        input.type("abc")
        XCTAssertEqual(sent(), [0x01] + Array("bc".utf8))
    }

    func testEmptyInputSendsNothing() {
        let (input, sent) = makeInput()
        input.type("")
        XCTAssertTrue(sent().isEmpty)
    }

    // MARK: - cursor mode

    func testCursorModeIsAppliedToKeysFromTheRow() {
        let (input, sent) = makeInput()
        input.cursorMode = .application
        input.press(.up)
        XCTAssertEqual(sent(), [0x1B, 0x4F, 0x41], "must follow the mode the remote program set")
    }

    func testChangingCursorModeChangesSubsequentArrows() {
        let (input, sent) = makeInput()
        input.press(.up)
        input.cursorMode = .application
        input.press(.up)
        XCTAssertEqual(sent(), [0x1B, 0x5B, 0x41, 0x1B, 0x4F, 0x41])
    }
}
