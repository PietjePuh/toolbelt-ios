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

    /// Movement, editing and the keys iOS simply does not have.
    private let navigation: [TerminalKey] = [
        .escape, .tab, .backTab,
        .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown,
        .backspace, .delete, .enter
    ]

    /// The characters iOS buries two taps deep, all of which are constant
    /// traffic in a shell.
    private let symbols = ["|", "~", "/", "\\", "-", "_", "*", "$", "#", "&",
                           ";", ":", "'", "\"", "`", "{", "}", "[", "]",
                           "(", ")", "<", ">", "!", "?", "=", "+", "%", "@", "^"]

    /// The control codes worth one tap. Any OTHER Ctrl combination is reachable
    /// by arming ctrl and typing the letter — which is why there are not
    /// twenty-six buttons here.
    private let quickControls = ["c", "d", "z", "l", "r", "a", "e", "k", "u", "w"]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                modifierButton("ctrl", active: input.modifier.isControl,
                               locked: input.modifier.isLocked) { input.toggleControl() }
                modifierButton("alt", active: input.modifier.isAlt,
                               locked: input.modifier.isLocked) { input.toggleAlt() }

                Divider().frame(height: 22)

                Picker("Row", selection: $row) {
                    ForEach(Row.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    switch row {
                    case .navigation:
                        ForEach(Array(navigation.enumerated()), id: \.offset) { _, key in
                            keyButton(key.label) { input.press(key) }
                        }
                        Divider().frame(height: 22)
                        ForEach(quickControls, id: \.self) { letter in
                            keyButton("^\(letter.uppercased())") {
                                input.press(.control(Character(letter)))
                            }
                        }

                    case .symbols:
                        ForEach(symbols, id: \.self) { symbol in
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
