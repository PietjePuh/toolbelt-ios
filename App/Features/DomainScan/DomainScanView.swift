import SwiftUI

@MainActor
final class DomainScanModel: ObservableObject {
    @Published var input: String = ""
    @Published private(set) var report: DomainScanner.Report?
    @Published private(set) var isScanning = false

    private let scanner: DomainScanner
    init(scanner: DomainScanner) { self.scanner = scanner }

    var canScan: Bool { DomainScanner.normalise(input) != nil && !isScanning }

    func scan() async {
        guard canScan else { return }
        isScanning = true
        defer { isScanning = false }
        report = await scanner.scan(input)
    }
}

struct DomainScanView: View {
    @StateObject private var model: DomainScanModel

    init(scanner: DomainScanner) {
        _model = StateObject(wrappedValue: DomainScanModel(scanner: scanner))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("example.com", text: $model.input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { Task { await model.scan() } }
                        if model.isScanning { ProgressView() }
                    }
                    Button("Scan") { Task { await model.scan() } }
                        .disabled(!model.canScan)
                } footer: {
                    // Said plainly, in the place it matters. Scans leave from
                    // this device and this connection.
                    Text("Scans run from your device, over your connection, and are attributable to you. Only scan hosts you own or are authorised to test.")
                }

                if let report = model.report {
                    resultSection(report)
                }
            }
            .navigationTitle("Domain scan")
        }
    }

    @ViewBuilder
    private func resultSection(_ report: DomainScanner.Report) -> some View {
        Section {
            ForEach(report.checks) { check in
                HStack(alignment: .firstTextBaseline) {
                    icon(for: check.outcome)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.body)
                        Text(detail(check.outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(report.domain)
        } footer: {
            // The load-bearing sentence. A partial scan must never read as a
            // clean bill of health — the unknowns are stated, not swallowed.
            if report.isComplete {
                Text("All checks completed.")
            } else {
                Text("^[\(report.unknowns.count) check](inflect: true) could not be completed — those are shown as unknown, not as passing.")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// @ViewBuilder, not a plain `some View`: each branch returns a
    /// differently-typed `Image` once a distinct `foregroundStyle` is applied,
    /// and an opaque return type requires one concrete type. The builder wraps
    /// them for us.
    @ViewBuilder
    private func icon(for outcome: DomainScanner.Outcome) -> some View {
        switch outcome {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .finding:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unknown:
            // Deliberately NOT a green tick and not an error red — it is
            // neither. A question mark is the honest glyph for "we could not
            // find out".
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private func detail(_ outcome: DomainScanner.Outcome) -> String {
        switch outcome {
        case .ok(let s): return s
        case .finding(let s): return s
        case .unknown(let s): return "unknown — \(s)"
        }
    }
}
