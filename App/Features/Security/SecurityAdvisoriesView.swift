import SwiftUI

/// CISA's Known Exploited Vulnerabilities, searchable.
///
/// This screen deliberately never says whether YOU are affected. It has no
/// inventory of what you run, so any such claim would be invented — and an
/// invented "you're fine" is the worst output a security tool can produce.
/// It lists what is being exploited and links to the authoritative record.
public struct SecurityAdvisoriesView: View {
    @StateObject private var model: AdvisoriesViewModel
    @State private var search = ""
    @State private var ransomwareOnly = false
    @State private var opened: URL?

    public init(gateway: Gateway) {
        _model = StateObject(wrappedValue: AdvisoriesViewModel(gateway: gateway))
    }

    private var visible: [KEVEntry] {
        model.catalogue?.entries.filter { entry in
            (!ransomwareOnly || entry.ransomware == .known) &&
            (search.isEmpty
             || entry.cveID.localizedCaseInsensitiveContains(search)
             || entry.vendorAndProduct.localizedCaseInsensitiveContains(search)
             || entry.name.localizedCaseInsensitiveContains(search))
        } ?? []
    }

    public var body: some View {
        Group {
            if model.loading && model.catalogue == nil {
                ProgressView("Loading catalogue…")
            } else if let error = model.error, model.catalogue == nil {
                ContentUnavailableView {
                    Label(error.summary, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.detail)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                list
            }
        }
        .navigationTitle("Exploited in the wild")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.catalogue == nil { await model.load() } }
        .refreshable { await model.load() }
        .sheet(item: $opened) { url in BrowserView(url: url) }
    }

    private var list: some View {
        List {
            header

            if visible.isEmpty {
                Text(search.isEmpty
                     ? "No entries match this filter."
                     : "Nothing in the catalogue matches “\(search)”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(visible) { entry in
                Button { opened = entry.nvdURL } label: { row(entry) }
                    .disabled(entry.nvdURL == nil)
            }
        }
        .searchable(text: $search, prompt: "CVE, vendor or product")
    }

    @ViewBuilder
    private var header: some View {
        if let catalogue = model.catalogue {
            Section {
                Toggle("Only those used in ransomware", isOn: $ransomwareOnly)
                    .font(.footnote)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // Age of the DATA, not of the request. A security list is
                    // only as good as its publication date.
                    if let age = catalogue.ageInDays(now: model.now) {
                        Text(age <= 1
                             ? "CISA catalogue \(catalogue.version), published today."
                             : "CISA catalogue \(catalogue.version), published \(age) days ago.")
                    } else {
                        Text("CISA catalogue \(catalogue.version) — publication date unknown.")
                    }

                    Text("\(catalogue.entries.count) vulnerabilities known to be exploited.")

                    if catalogue.skipped > 0 {
                        Text("\(catalogue.skipped) entries could not be read and are not shown.")
                            .foregroundStyle(.orange)
                    }

                    if model.error != nil {
                        Text("Could not refresh — showing the last catalogue that loaded.")
                            .foregroundStyle(.orange)
                    }

                    Text("This list is what is being exploited generally. It does not know what you run, and makes no claim about whether you are affected.")
                        .padding(.top, 2)
                }
                .font(.caption2)
            }
        }
    }

    private func row(_ entry: KEVEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.cveID)
                    .font(.caption.monospaced().weight(.semibold))
                if entry.ransomware == .known {
                    Text("RANSOMWARE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if let added = entry.dateAdded {
                    Text(added, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(entry.vendorAndProduct).font(.body)
            Text(entry.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class AdvisoriesViewModel: ObservableObject {
    @Published private(set) var catalogue: KEVCatalogue?
    @Published private(set) var error: KEVService.ServiceError?
    @Published private(set) var loading = false
    @Published private(set) var now = Date()

    private let service: KEVService

    init(gateway: Gateway) { service = KEVService(gateway: gateway) }

    func load() async {
        loading = true
        defer { loading = false }
        now = Date()
        do {
            catalogue = try await service.fetch()
            error = nil
        } catch let e as KEVService.ServiceError {
            // The previous catalogue is KEPT and its age keeps counting up, so
            // a failed refresh degrades into visibly stale data rather than
            // into an empty screen that reads as "nothing is being exploited".
            error = e
        } catch {
            self.error = .unreachable(error.localizedDescription)
        }
    }
}
