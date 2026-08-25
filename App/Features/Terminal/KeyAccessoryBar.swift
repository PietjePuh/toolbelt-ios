import SwiftUI

/// The accessory row above the keyboard.
///
/// Ctrl and Alt are STICKY rather than held: you cannot hold a modifier and
/// press a letter on a touchscreen, so tapping `ctrl` arms it, the next key
/// consumes it, and tapping it again cancels. Double-tapping locks it for
/// repeated use (Ctrl-C, Ctrl-C, Ctrl-C).
struct KeyAccessoryBar: View {
    let cursorMode: TerminalKey.CursorMode
    let send: (Data) -> Void

    @State private var modifier: Modifier = .none

    enum Modifier: Equatable {
        case none
        case control(locked: Bool)
        case alt(locked: Bool)

        var isControl: Bool { if case .control = self { return true }; return false }
        var isAlt: Bool { if case .alt = self { return true }; return false }
        var isLocked: Bool {
            switch self {
            case .control(let l), .alt(let l): return l
            case .none: return false
            }
        }
    }

    private let keys: [TerminalKey] = [
        .escape, .tab, .backTab,
        .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown,
        .delete
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifierButton("ctrl", active: modifier.isControl, locked: modifier.isLocked) {
                    toggle(control: true)
                }
                modifierButton("alt", active: modifier.isAlt, locked: modifier.isLocked) {
                    toggle(control: false)
                }

                Divider().frame(height: 22)

                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    keyButton(key.label) { press(key) }
                }

                Divider().frame(height: 22)

                // The control codes worth one tap rather than two.
                ForEach(["c", "d", "z", "l", "r"], id: \.self) { letter in
                    keyButton("^\(letter.uppercased())") {
                        emit(.control(Character(letter)))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    /// A modifier plus a normal key. Ctrl+arrow is not meaningful here, so an
    /// armed modifier applies only to text and is otherwise released without
    /// sending anything unexpected.
    private func press(_ key: TerminalKey) {
        switch modifier {
        case .none:
            emit(key)
        case .control, .alt:
            // Arming ctrl and then pressing Tab should not silently send a
            // plain Tab as though nothing was armed — release it and send the
            // key on its own, which is what the user visibly asked for.
            emit(key)
        }
    }

    private func emit(_ key: TerminalKey) {
        send(key.bytes(cursorMode: cursorMode))
        if !modifier.isLocked { modifier = .none }
    }

    /// Text typed on the system keyboard, routed through the armed modifier.
    func typed(_ string: String) {
        guard let first = string.first else { return }
        switch modifier {
        case .control: emit(.control(first))
        case .alt:     emit(.alt(first))
        case .none:    emit(.text(string))
        }
    }

    private func toggle(control: Bool) {
        let wanted = control
        let already = control ? modifier.isControl : modifier.isAlt
        if already {
            // arm → lock → off
            modifier = modifier.isLocked ? .none
                : (wanted ? .control(locked: true) : .alt(locked: true))
        } else {
            modifier = wanted ? .control(locked: false) : .alt(locked: false)
        }
    }

    private func modifierButton(_ title: String, active: Bool, locked: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if active && locked {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                }
            }
            .font(.caption.weight(active ? .bold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "\(title), armed" : title)
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
