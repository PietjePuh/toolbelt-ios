import SwiftUI

/// Read-only watchlist. No orders, no targets, no advice.
public struct FinanceView: View {
    @StateObject private var model: FinanceViewModel
    @State private var adding = false
    @State private var symbol = ""

    public init(gateway: Gateway) {
        _model = StateObject(wrappedValue: FinanceViewModel(gateway: gateway))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.rows.isEmpty && !model.loading {
                    ContentUnavailableView {
                        Label("No symbols yet", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Add a ticker to watch it. Prices only — this app cannot place orders.")
                    } actions: {
                        Button("Add a symbol") { adding = true }
                    }
                } else {
                    List {
                        ForEach(model.rows) { row in
                            FinanceRow(row: row, now: model.now)
                        }
                        .onDelete { model.remove($0) }
                    }
                    .refreshable { await model.refresh() }
                }
            }
            .navigationTitle("Finance")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Add symbol", isPresented: $adding) {
                TextField("AAPL, ASML.AS, ^AEX", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { symbol = "" }
                Button("Add") {
                    let entry = symbol
                    symbol = ""
                    Task { await model.add(entry) }
                }
            } message: {
                Text("The symbol is checked with the provider before it is saved.")
            }
            .task { await model.refresh() }
        }
    }
}

struct FinanceRow: View {
    let row: FinanceViewModel.Row
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.symbol).font(.body.weight(.medium))
                    if let name = row.quote?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let quote = row.quote {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(format(quote.price, currency: quote.currency))
                            .font(.body.monospacedDigit())
                        changeLabel(quote)
                    }
                }
            }

            if let quote = row.quote {
                staleness(quote)
            } else if let error = row.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func changeLabel(_ quote: Quote) -> some View {
        if let change = quote.change, let percent = quote.changePercent {
            Text(String(format: "%+.2f (%+.2f%%)", change, percent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(change >= 0 ? Color.green : Color.red)
        } else {
            // No previous close: "flat" and "unknown" are different claims.
            Text("change unknown").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The label that stops a stale number reading as a live one.
    @ViewBuilder
    private func staleness(_ quote: Quote) -> some View {
        switch quote.staleness(now: now) {
        case .live:
            Text("\(quote.marketState.label) · \(quote.asOf, style: .time)")
                .font(.caption2).foregroundStyle(.secondary)
        case .lastClose:
            Text("Previous close · \(quote.asOf, style: .date)")
                .font(.caption2).foregroundStyle(.secondary)
        case .stale(let minutes):
            Label("No update for \(minutes) min — feed may be delayed",
                  systemImage: "clock.badge.exclamationmark")
                .font(.caption2).foregroundStyle(.orange)
        case .unknownAge:
            Label("Price age unknown", systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    private func format(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = currency.isEmpty ? .decimal : .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

@MainActor
final class FinanceViewModel: ObservableObject {

    struct Row: Identifiable {
        var id: String { symbol }
        let symbol: String
        var quote: Quote?
        var error: String?
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loading = false
    /// Held rather than read per-render, so every row judges staleness against
    /// the same instant.
    @Published private(set) var now = Date()

    private let service: QuoteService
    private let store: KeyValueStore
    private let key = "toolbelt.watchlist.v1"

    init(gateway: Gateway, store: KeyValueStore = UserDefaults.standard) {
        service = QuoteService(gateway: gateway)
        self.store = store
        rows = savedSymbols().map { Row(symbol: $0) }
    }

    private func savedSymbols() -> [String] {
        guard let data = store.data(forKey: key),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rows.map(\.symbol)) else { return }
        store.set(data, forKey: key)
    }

    func add(_ raw: String) async {
        let symbol = QuoteService.normalise(raw)
        guard !symbol.isEmpty, !rows.contains(where: { $0.symbol == symbol }) else { return }

        // Checked before it is saved, so a typo fails now rather than sitting
        // in the list showing an error forever.
        do {
            let quote = try await service.quote(for: symbol)
            rows.append(Row(symbol: symbol, quote: quote))
            save()
        } catch let e as QuoteService.ServiceError {
            rows.append(Row(symbol: symbol, error: e.summary))
        } catch {
            rows.append(Row(symbol: symbol, error: error.localizedDescription))
        }
    }

    func remove(_ offsets: IndexSet) {
        rows.remove(atOffsets: offsets)
        save()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        now = Date()

        for index in rows.indices {
            do {
                rows[index].quote = try await service.quote(for: rows[index].symbol)
                rows[index].error = nil
            } catch let e as QuoteService.ServiceError {
                // The PREVIOUS quote is kept and will now show as stale rather
                // than being replaced by a blank row — but the failure is said
                // out loud, so nothing looks fresher than it is.
                rows[index].error = e.summary
            } catch {
                rows[index].error = error.localizedDescription
            }
        }
    }
}
