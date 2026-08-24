import SwiftUI
import WebKit

/// Minimal in-app browser: open a scan result, a feed item or an IMDb link
/// without leaving the app.
///
/// Two deliberate properties, both from the roadmap rather than added later:
///
///  - **The address is always visible.** A chrome-less web view that renders
///    third-party content is a phishing aid; the host stays on screen.
///  - **No persistent website data.** A `.nonPersistent()` store means cookies
///    and local storage live for the life of the view only. This browser exists
///    to open links from untrusted feeds, so it deliberately does not become a
///    logged-in session that other pages can ride.
public struct BrowserView: View {
    @StateObject private var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    public init(url: URL) {
        _model = StateObject(wrappedValue: BrowserModel(initial: url))
    }

    public var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            WebViewContainer(model: model)
            Divider()
            toolbar
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.isSecure ? .secondary : .orange)
                .accessibilityLabel(model.isSecure ? "Encrypted connection" : "Not encrypted")

            Text(model.host)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Address: \(model.host)")

            Spacer(minLength: 4)

            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Done") { dismiss() }.font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolbar: some View {
        HStack {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Spacer()
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Spacer()
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
            Spacer()
            ShareLink(item: model.currentURL) { Image(systemName: "square.and.arrow.up") }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject {
    @Published var host: String
    @Published var isSecure: Bool
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published private(set) var currentURL: URL

    let webView: WKWebView

    init(initial: URL) {
        let config = WKWebViewConfiguration()
        // Ephemeral: this browser opens links from untrusted feeds and must not
        // accumulate a session those pages could ride.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        let shown = BrowserAddress.display(initial)
        host = shown.host
        isSecure = shown.isSecure
        currentURL = initial
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: initial))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    private func sync() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url {
            currentURL = url
            let shown = BrowserAddress.display(url)
            host = shown.host
            isSecure = shown.isSecure
        }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        sync()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        sync()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
        sync()
    }

    /// The same allow-list as the address bar, enforced on every navigation —
    /// including ones a page starts itself. Refused schemes are dropped rather
    /// than passed to `UIApplication.open`: a page from an untrusted feed does
    /// not get to launch other apps because the user tapped a link.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(),
              BrowserAddress.allowedSchemes.contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
