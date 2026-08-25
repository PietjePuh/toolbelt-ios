import Foundation

/// Everything typed at the terminal, from either source: the accessory row and
/// the system keyboard.
///
/// It exists because the modifier cannot live inside the accessory row. Sticky
/// Ctrl is for `Ctrl+A`, `Ctrl+K`, `Ctrl+W` — letters typed on the SYSTEM
/// keyboard — so if the row owns the state privately, arming Ctrl can only
/// ever modify the row's own buttons, which is close to useless. The state is
/// shared here and both inputs go through one path.
@MainActor
public final class TerminalInput: ObservableObject {

    /// Held rather than pressed: a touchscreen cannot hold a modifier while
    /// pressing a letter.
    public enum Modifier: Equatable, Sendable {
        case none
        case control(locked: Bool)
        case alt(locked: Bool)

        public var isControl: Bool { if case .control = self { return true }; return false }
        public var isAlt: Bool { if case .alt = self { return true }; return false }
        public var isLocked: Bool {
            switch self {
            case .control(let locked), .alt(let locked): return locked
            case .none: return false
            }
        }
    }

    @Published public private(set) var modifier: Modifier = .none
    /// Set by the remote program via DECCKM. Arrows encode differently
    /// depending on it.
    @Published public var cursorMode: TerminalKey.CursorMode = .normal

    /// Where bytes go. Replaced by the connection; a buffer in tests.
    public var onSend: (Data) -> Void

    public init(onSend: @escaping (Data) -> Void = { _ in }) {
        self.onSend = onSend
    }

    // MARK: - input

    /// A key from the accessory row.
    public func press(_ key: TerminalKey) {
        emit(key)
    }

    /// Text from the system keyboard. If a modifier is armed it applies to the
    /// FIRST character — `Ctrl` then `a` is Ctrl-A — and the rest is sent
    /// plainly, because a modifier applies to one keystroke, not to a word.
    public func type(_ string: String) {
        guard !string.isEmpty else { return }

        switch modifier {
        case .none:
            emit(.text(string))

        case .control, .alt:
            let first = string.first!
            let rest = String(string.dropFirst())
            let modified: TerminalKey = modifier.isControl ? .control(first) : .alt(first)

            let bytes = modified.bytes(cursorMode: cursorMode)
            if bytes.isEmpty {
                // No control code exists for this character. Send it plainly
                // rather than dropping the keystroke — silently swallowing what
                // someone typed is worse than ignoring the modifier.
                onSend(TerminalKey.text(string).bytes())
            } else {
                onSend(bytes)
                if !rest.isEmpty { onSend(TerminalKey.text(rest).bytes()) }
            }
            releaseIfUnlocked()
        }
    }

    private func emit(_ key: TerminalKey) {
        onSend(key.bytes(cursorMode: cursorMode))
        releaseIfUnlocked()
    }

    private func releaseIfUnlocked() {
        if !modifier.isLocked { modifier = .none }
    }

    // MARK: - modifiers

    /// Tap once to arm, again to lock, again to clear. Locking matters for
    /// repeated use — Ctrl-C, Ctrl-C, Ctrl-C — where re-arming every time is
    /// three taps too many.
    public func toggleControl() {
        switch modifier {
        case .control(locked: false): modifier = .control(locked: true)
        case .control(locked: true):  modifier = .none
        default:                      modifier = .control(locked: false)
        }
    }

    public func toggleAlt() {
        switch modifier {
        case .alt(locked: false): modifier = .alt(locked: true)
        case .alt(locked: true):  modifier = .none
        default:                  modifier = .alt(locked: false)
        }
    }

    public func clearModifier() { modifier = .none }
}
