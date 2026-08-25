import Foundation

/// The keys an iOS keyboard does not have, and the bytes they send.
///
/// A software keyboard has no Ctrl, no Esc, no Tab and no arrows, which means
/// no tab-completion, no Ctrl-C, and no way out of vim. An accessory row is not
/// a nicety here — without it the terminal is unusable.
///
/// The encodings are the fiddly part and are easy to get subtly wrong in ways
/// that only show up inside a full-screen program, so they are tested rather
/// than eyeballed.
public enum TerminalKey: Equatable, Sendable {

    case escape
    case tab
    /// Shift-Tab. `CSI Z`, not a modified Tab — reverse-completion in shells
    /// and back-field in TUIs.
    case backTab
    case enter
    case backspace
    case delete

    case up, down, left, right
    case home, end, pageUp, pageDown

    /// Ctrl + a character. `Ctrl+C`, `Ctrl+D`, `Ctrl+[`…
    case control(Character)
    /// Alt/Meta + a character, sent as ESC followed by the character —
    /// `Alt+B` / `Alt+F` for word movement, and Meta in emacs.
    case alt(Character)

    case function(Int)
    /// Ordinary text, so the bar and the keyboard share one path to the wire.
    case text(String)

    /// Cursor keys have TWO encodings, and which one is correct depends on a
    /// mode the remote program sets.
    ///
    /// DECCKM (application cursor keys) is enabled by vim, less, htop and most
    /// full-screen programs. In that mode arrows are `ESC O A`; outside it they
    /// are `ESC [ A`. Sending the wrong form is the classic bug where arrow
    /// keys type letters inside vim instead of moving the cursor.
    public enum CursorMode: Sendable, Equatable {
        case normal
        case application
    }

    public func bytes(cursorMode: CursorMode = .normal) -> Data {
        switch self {
        case .escape:    return Data([0x1B])
        case .tab:       return Data([0x09])
        case .backTab:   return Data([0x1B, 0x5B, 0x5A])            // CSI Z
        case .enter:     return Data([0x0D])                        // CR, not LF
        // DEL (0x7F), not BS (0x08). Nearly every modern stty maps erase to
        // DEL, and sending BS produces `^H` in the shell instead of deleting.
        case .backspace: return Data([0x7F])
        case .delete:    return Data([0x1B, 0x5B, 0x33, 0x7E])      // CSI 3~

        case .up:    return cursor("A", cursorMode)
        case .down:  return cursor("B", cursorMode)
        case .right: return cursor("C", cursorMode)
        case .left:  return cursor("D", cursorMode)
        case .home:  return cursor("H", cursorMode)
        case .end:   return cursor("F", cursorMode)

        case .pageUp:   return Data([0x1B, 0x5B, 0x35, 0x7E])       // CSI 5~
        case .pageDown: return Data([0x1B, 0x5B, 0x36, 0x7E])       // CSI 6~

        case .control(let c):
            return Self.controlByte(c).map { Data([$0]) } ?? Data()

        case .alt(let c):
            return Data([0x1B]) + Data(String(c).utf8)

        case .function(let n):
            return Self.functionBytes(n)

        case .text(let s):
            return Data(s.utf8)
        }
    }

    private func cursor(_ final: Character, _ mode: CursorMode) -> Data {
        // ESC O <x> in application mode, ESC [ <x> otherwise.
        let introducer: UInt8 = mode == .application ? 0x4F : 0x5B
        return Data([0x1B, introducer, final.asciiValue ?? 0x41])
    }

    /// Ctrl strips the top bits: Ctrl+A is 0x01, Ctrl+C is 0x03, Ctrl+Z 0x1A.
    /// The punctuation cases are not decoration — Ctrl+[ IS escape, and
    /// Ctrl+? is DEL, both of which people use.
    static func controlByte(_ raw: Character) -> UInt8? {
        let c = Character(raw.uppercased())
        switch c {
        case "A"..."Z":
            guard let ascii = c.asciiValue else { return nil }
            return ascii - 64                    // A → 1 … Z → 26
        case "@", " ":  return 0x00              // NUL
        case "[":       return 0x1B              // ESC
        case "\\":      return 0x1C              // FS
        case "]":       return 0x1D              // GS
        case "^":       return 0x1E              // RS
        case "_":       return 0x1F              // US
        case "?":       return 0x7F              // DEL
        default:        return nil
        }
    }

    /// xterm's function-key encodings. F1–F4 use SS3; F5 upward use CSI with a
    /// number, and the numbering deliberately skips 16, 22, 27, 30 and 35 —
    /// historical gaps that are part of the standard, not an error.
    static func functionBytes(_ n: Int) -> Data {
        switch n {
        case 1:  return Data([0x1B, 0x4F, 0x50])                    // SS3 P
        case 2:  return Data([0x1B, 0x4F, 0x51])
        case 3:  return Data([0x1B, 0x4F, 0x52])
        case 4:  return Data([0x1B, 0x4F, 0x53])
        case 5:  return csiTilde(15)
        case 6:  return csiTilde(17)
        case 7:  return csiTilde(18)
        case 8:  return csiTilde(19)
        case 9:  return csiTilde(20)
        case 10: return csiTilde(21)
        case 11: return csiTilde(23)
        case 12: return csiTilde(24)
        default: return Data()
        }
    }

    private static func csiTilde(_ n: Int) -> Data {
        Data([0x1B, 0x5B]) + Data(String(n).utf8) + Data([0x7E])
    }

    /// What the accessory row shows.
    public var label: String {
        switch self {
        case .escape:    return "esc"
        case .tab:       return "tab"
        case .backTab:   return "⇤"
        case .enter:     return "⏎"
        case .backspace: return "⌫"
        case .delete:    return "⌦"
        case .up:        return "↑"
        case .down:      return "↓"
        case .left:      return "←"
        case .right:     return "→"
        case .home:      return "home"
        case .end:       return "end"
        case .pageUp:    return "pgup"
        case .pageDown:  return "pgdn"
        case .control(let c): return "^\(c.uppercased())"
        case .alt(let c):     return "⌥\(c.uppercased())"
        case .function(let n): return "F\(n)"
        case .text(let s):     return s
        }
    }
}
