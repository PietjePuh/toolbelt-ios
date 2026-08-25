import XCTest
@testable import Toolbelt

final class TerminalKeyTests: XCTestCase {

    private func bytes(_ key: TerminalKey,
                       _ mode: TerminalKey.CursorMode = .normal) -> [UInt8] {
        Array(key.bytes(cursorMode: mode))
    }

    // MARK: - the keys iOS does not have

    func testTabAndEscape() {
        XCTAssertEqual(bytes(.tab), [0x09])
        XCTAssertEqual(bytes(.escape), [0x1B])
    }

    func testShiftTabIsCSIZNotAModifiedTab() {
        // Reverse-completion in shells and back-field in TUIs. It is its own
        // sequence — sending Tab with a modifier flag does nothing.
        XCTAssertEqual(bytes(.backTab), [0x1B, 0x5B, 0x5A])
    }

    func testEnterSendsCarriageReturnNotLineFeed() {
        // A line-feed leaves most shells waiting for the rest of the line.
        XCTAssertEqual(bytes(.enter), [0x0D])
    }

    func testBackspaceSendsDELNotBS() {
        // Nearly every modern stty maps erase to DEL. Sending BS (0x08) shows
        // "^H" in the shell instead of deleting a character.
        XCTAssertEqual(bytes(.backspace), [0x7F])
    }

    func testDeleteIsDistinctFromBackspace() {
        XCTAssertEqual(bytes(.delete), [0x1B, 0x5B, 0x33, 0x7E])
        XCTAssertNotEqual(bytes(.delete), bytes(.backspace))
    }

    // MARK: - control

    func testCommonControlCodes() {
        XCTAssertEqual(bytes(.control("c")), [0x03])   // interrupt
        XCTAssertEqual(bytes(.control("d")), [0x04])   // EOF
        XCTAssertEqual(bytes(.control("z")), [0x1A])   // suspend
        XCTAssertEqual(bytes(.control("a")), [0x01])   // start of line
        XCTAssertEqual(bytes(.control("l")), [0x0C])   // clear
    }

    func testControlIsCaseInsensitive() {
        XCTAssertEqual(bytes(.control("C")), bytes(.control("c")))
    }

    func testControlPunctuation() {
        // Not decoration: Ctrl+[ IS escape, and people genuinely use it.
        XCTAssertEqual(bytes(.control("[")), [0x1B])
        XCTAssertEqual(bytes(.control("\\")), [0x1C])  // quit
        XCTAssertEqual(bytes(.control("?")), [0x7F])
        XCTAssertEqual(bytes(.control("@")), [0x00])   // NUL
        XCTAssertEqual(bytes(.control(" ")), [0x00])
        XCTAssertEqual(bytes(.control("_")), [0x1F])
    }

    func testUnmappableControlSendsNothingRatherThanGarbage() {
        // Sending a wrong byte into a live shell is worse than sending none.
        XCTAssertEqual(bytes(.control("€")), [])
        XCTAssertEqual(bytes(.control("1")), [])
    }

    // MARK: - the mode that breaks arrows in vim

    func testArrowsInNormalMode() {
        XCTAssertEqual(bytes(.up), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(bytes(.down), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(bytes(.right), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(bytes(.left), [0x1B, 0x5B, 0x44])
    }

    func testArrowsInApplicationCursorMode() {
        // DECCKM is set by vim, less and htop. Sending the CSI form there is
        // the classic bug where arrow keys type letters instead of moving.
        XCTAssertEqual(bytes(.up, .application), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(bytes(.down, .application), [0x1B, 0x4F, 0x42])
        XCTAssertEqual(bytes(.right, .application), [0x1B, 0x4F, 0x43])
        XCTAssertEqual(bytes(.left, .application), [0x1B, 0x4F, 0x44])
    }

    func testTheTwoCursorModesActuallyDiffer() {
        for key in [TerminalKey.up, .down, .left, .right, .home, .end] {
            XCTAssertNotEqual(bytes(key, .normal), bytes(key, .application),
                              "\(key.label) should differ between cursor modes")
        }
    }

    func testPagingKeysAreNotAffectedByCursorMode() {
        // Only cursor keys switch on DECCKM; paging keys do not.
        XCTAssertEqual(bytes(.pageUp, .normal), bytes(.pageUp, .application))
        XCTAssertEqual(bytes(.pageUp), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(bytes(.pageDown), [0x1B, 0x5B, 0x36, 0x7E])
    }

    // MARK: - alt / meta

    func testAltPrefixesWithEscape() {
        // Alt+B / Alt+F are word-movement in readline; Meta in emacs.
        XCTAssertEqual(bytes(.alt("b")), [0x1B, 0x62])
        XCTAssertEqual(bytes(.alt("f")), [0x1B, 0x66])
    }

    // MARK: - function keys

    func testFunctionKeysUseSS3ThenCSI() {
        XCTAssertEqual(bytes(.function(1)), [0x1B, 0x4F, 0x50])
        XCTAssertEqual(bytes(.function(4)), [0x1B, 0x4F, 0x53])
        XCTAssertEqual(bytes(.function(5)), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(bytes(.function(12)), Array("\u{1B}[24~".utf8))
    }

    func testFunctionKeyNumberingSkipsTheHistoricalGaps() {
        // 16, 22, 27, 30 and 35 are unused in xterm's scheme. Filling them in
        // would look tidier and send the wrong key.
        XCTAssertEqual(bytes(.function(6)), Array("\u{1B}[17~".utf8))
        XCTAssertEqual(bytes(.function(11)), Array("\u{1B}[23~".utf8))
    }

    func testUnknownFunctionKeySendsNothing() {
        XCTAssertEqual(bytes(.function(0)), [])
        XCTAssertEqual(bytes(.function(13)), [])
    }

    // MARK: - text

    func testTextGoesThroughAsUTF8() {
        XCTAssertEqual(bytes(.text("ls -la\n")), Array("ls -la\n".utf8))
        XCTAssertEqual(bytes(.text("é")), Array("é".utf8))
    }

    func testEveryKeyHasALabel() {
        let keys: [TerminalKey] = [.escape, .tab, .backTab, .enter, .backspace, .delete,
                                   .up, .down, .left, .right, .home, .end,
                                   .pageUp, .pageDown, .control("c"), .alt("b"),
                                   .function(1), .text("x")]
        for key in keys {
            XCTAssertFalse(key.label.isEmpty, "\(key) has no label")
        }
    }
}

/// Structural checks on the accessory bar's key sets.
///
/// These are not layout tests — they pin the DECISIONS about which keys are
/// always reachable and that nothing is missing or duplicated. Layout is
/// checked by eye; "escape is always on screen" should not be.
final class KeyAccessoryLayoutTests: XCTestCase {

    func testEscapeAndTabNeverScrollAway() {
        // Escape is the way out of every mode in vim and tab is completion.
        // They previously sat in the scrolling row, so reaching ^C pushed
        // escape off screen — backwards for the two most-pressed keys.
        XCTAssertTrue(KeyAccessoryBar.pinned.contains(.escape))
        XCTAssertTrue(KeyAccessoryBar.pinned.contains(.tab))
    }

    func testPinnedKeysAreNotDuplicatedInTheScrollingRow() {
        for key in KeyAccessoryBar.pinned {
            XCTAssertFalse(KeyAccessoryBar.navigation.contains(key),
                           "\(key.label) appears both pinned and in the scrolling row")
        }
    }

    func testThePinnedRowStaysSmallEnoughToFit() {
        // It shares a fixed-width row with two modifier buttons and the row
        // picker. Adding a third or fourth key here would push the picker off
        // a small iPhone, which is how "always visible" quietly stops being
        // true.
        XCTAssertLessThanOrEqual(KeyAccessoryBar.pinned.count, 2)
    }

    func testEveryKeyTheTerminalNeedsIsReachable() {
        let reachable = Set(
            (KeyAccessoryBar.pinned + KeyAccessoryBar.navigation).map(\.label)
        )
        // Nothing here can be typed on an iOS keyboard, so if one is missing it
        // is simply unavailable to the user.
        for required in ["esc", "tab", "⇤", "↑", "↓", "←", "→",
                         "home", "end", "pgup", "pgdn", "⌫", "⌦", "⏎"] {
            XCTAssertTrue(reachable.contains(required), "\(required) is not reachable")
        }
    }

    func testTheCommonControlCodesAreOneTap() {
        // Every other Ctrl combination is reachable by arming ctrl and typing
        // the letter; these are the ones frequent enough to deserve a button.
        for letter in ["c", "d", "z"] {
            XCTAssertTrue(KeyAccessoryBar.quickControls.contains(letter),
                          "^\(letter.uppercased()) should be one tap")
        }
    }

    func testSymbolsCoverWhatAShellActuallyUses() {
        let symbols = Set(KeyAccessoryBar.symbols)
        for required in ["|", "~", "/", "-", "_", "$", "*", "&", ";", "'", "\""] {
            XCTAssertTrue(symbols.contains(required), "\(required) is buried on the iOS keyboard")
        }
    }

    func testNoSymbolIsListedTwice() {
        XCTAssertEqual(Set(KeyAccessoryBar.symbols).count, KeyAccessoryBar.symbols.count)
    }
}
