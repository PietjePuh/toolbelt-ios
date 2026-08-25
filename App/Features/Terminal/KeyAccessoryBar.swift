import SwiftUI

/// The accessory rows above the keyboard.
///
/// Three rows, switchable, because everything on one row means scrolling past
/// what you need. The modifier state lives in `TerminalInput` rather than here,
/// so arming Ctrl also applies to letters typed on the system keyboard — which
/// is the whole point of it.
struct KeyAccessoryBar: View {
    @ObservedObject var input: TerminalInput
    @State private var row: Row = .navigation

    enum Row: String, CaseIterable {
        case navigation = "nav"
        case symbols = "sym"
        case function = "F"
    }

    /// Never scrolls away. These are the keys you reach for constantly and
    /// cannot afford to hunt for: esc is the way out of every mode in vim, and
    /// tab is completion. They used to sit in the scrolling row, which meant
    /// scrolling right for ^C pushed escape off screen — exactly backwards for
    /// the two most-pressed keys on the bar.
    static let pinned: [TerminalKey] = [.escape, .tab]

    /// Movement, editing and the rest of what iOS does not have.
    static let navigation: [TerminalKey] = [
        .backTab,
        .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown,
        .backspace, .delete, .enter
    ]

    /// The characters iOS buries two taps deep, all of which are constant
    /// traffic in a shell.
    static let symbols = ["|", "~", "/", "\\", "-", "_", "*", "$", "#", "&",
                           ";", ":", "'", "\"", "`", "{", "}", "[", "]",
                           "(", ")", "<", ">", "!", "?", "=", "+", "%", "@", "^"]

    /// The control codes worth one tap. Any OTHER Ctrl combination is reachable
    /// by arming ctrl and typing the letter — which is why there are not
    /// twenty-six buttons here.
    static let quickControls = ["c", "d", "z", "l", "r", "a", "e", "k", "u", "w"]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                modifierButton("ctrl", active: input.modifier.isControl,
                               locked: input.modifier.isLocked) { input.toggleControl() }
                modifierButton("alt", active: input.modifier.isAlt,
                               locked: input.modifier.isLocked) { input.toggleAlt() }

                ForEach(Array(Self.pinned.enumerated()), id: \.offset) { _, key in
                    keyButton(key.label) { input.press(key) }
                }

                Spacer(minLength: 4)

                Picker("Row", selection: $row) {
                    ForEach(Row.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    switch row {
                    case .navigation:
                        ForEach(Array(Self.navigation.enumerated()), id: \.offset) { _, key in
                            keyButton(key.label) { input.press(key) }
                        }
                        Divider().frame(height: 22)
                        ForEach(Self.quickControls, id: \.self) { letter in
                            keyButton("^\(letter.uppercased())") {
                                input.press(.control(Character(letter)))
                            }
                        }

                    case .symbols:
                        ForEach(Self.symbols, id: \.self) { symbol in
                            // Routed through `type` so an armed modifier
                            // applies here too.
                            keyButton(symbol) { input.type(symbol) }
                        }

                    case .function:
                        ForEach(1...12, id: \.self) { n in
                            keyButton("F\(n)") { input.press(.function(n)) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(.thinMaterial)
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
        .accessibilityLabel(active ? (locked ? "\(title), locked" : "\(title), armed") : title)
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced())
                .frame(minWidth: 26)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
