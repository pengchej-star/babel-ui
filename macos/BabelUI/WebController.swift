import AppKit
import Observation
import WebKit

/// Owns the panel's WKWebView. It outlives the window, so closing the window keeps the page —
/// and its terminal tabs — alive; only quitting the app (or restarting the server) drops them.
@Observable
final class WebController: NSObject {
    struct Banner: Equatable {
        let id = UUID()
        let text: String
        var file: URL?
        var isError = false
    }

    @ObservationIgnored let webView: WKWebView
    private(set) var loadError: String?
    private(set) var banner: Banner?
    private(set) var title = "Babel UI"

    /// Shows the window; JS dialogs and the file picker need it on screen.
    @ObservationIgnored var presentWindow: (() -> NSWindow?)?
    @ObservationIgnored var didFinishLoad: (() -> Void)?
    /// Answers JS dialogs without showing them (self-test only).
    @ObservationIgnored var dialogAutoReply: ((String) -> Void)?

    @ObservationIgnored private let config: Config
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var titleObservation: NSKeyValueObservation?

    init(config: Config) {
        self.config = config
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()   // keeps the page's localStorage between launches
        conf.preferences.isElementFullscreenEnabled = true
        conf.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: conf)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }   // right-click → Inspect Element
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let t = self.webView.title ?? ""
                self.title = t.isEmpty ? "Babel UI" : t
            }
        }
    }

    // MARK: - Loading

    func loadIfNeeded() {
        if !hasLoaded || loadError != nil { load() }
    }

    /// (Re)load the panel from "/". Used for ⌘R too: if a failed download ever replaced the page
    /// with an error, plain reload would just show that error again.
    func load() {
        hasLoaded = true
        loadError = nil
        // Revalidate: after a `git pull` of babel-ui the page must not come from WebKit's cache.
        webView.load(URLRequest(url: config.baseURL, cachePolicy: .reloadRevalidatingCacheData))
    }

    func dismissBanner() { banner = nil }

    private func show(_ b: Banner) {
        banner = b
        let id = b.id
        Task {
            try? await Task.sleep(for: .seconds(b.isError ? 12 : 8))
            if banner?.id == id { banner = nil }
        }
    }

    /// Our own pages: http(s)/ws on 127.0.0.1 or localhost at the panel's port.
    private func isPanel(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
              let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" else { return false }
        return (url.port ?? (scheme.hasSuffix("s") ? 443 : 80)) == config.port
    }

    private func window() -> NSWindow? {
        if let w = webView.window, w.isVisible { return w }
        return presentWindow?()
    }
}

// MARK: - Navigation, external links, downloads

extension WebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if isPanel(url) || ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            return action.shouldPerformDownload ? .download : .allow
        }
        if action.targetFrame?.isMainFrame == false && action.navigationType == .other {
            return .allow   // an embedded frame loading on its own; leave it be
        }
        NSWorkspace.shared.open(url)   // everything else goes to the default browser
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = response.response as? HTTPURLResponse {
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if disposition.hasPrefix("attachment") { return .download }
            // /api/download is opened with location.href; when it fails, a browser would swap the
            // whole panel for the error JSON. Keep the panel and say what went wrong instead.
            if response.isForMainFrame, http.statusCode >= 400, let url = http.url, url.path.hasPrefix("/api/") {
                reportFailedDownload(url, status: http.statusCode)
                return .cancel
            }
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadError = nil
        didFinishLoad?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
    }

    private func noteLoadFailure(_ error: Error) {
        let e = error as NSError
        // Cancelled, or turned into a download / cancelled by our own policy: not a failure.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        loadError = e.localizedDescription
    }

    private func reportFailedDownload(_ url: URL, status: Int) {
        Task {
            // Ask again to read the error text (a GET with no side effects; the page didn't get it).
            var message = "HTTP \(status)"
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String, !err.isEmpty {
                message = err
            }
            show(Banner(text: "Download failed: \(message)", isError: true))
        }
    }
}

extension WebController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dest = Self.uniqueURL(in: config.downloads, for: suggestedFilename)
        downloads[ObjectIdentifier(download)] = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Makes the Downloads stack in the Dock bounce, like Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                     object: dest.path)
        show(Banner(text: "Downloaded \(dest.lastPathComponent) to \(dest.deletingLastPathComponent().lastPathComponent)",
                    file: dest))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let dest = downloads.removeValue(forKey: ObjectIdentifier(download))
        show(Banner(text: "Download of \(dest?.lastPathComponent ?? "file") failed: \(error.localizedDescription)",
                    isError: true))
    }

    /// "name.ext", or "name (2).ext" … if that's taken (WKDownload won't overwrite).
    nonisolated static func uniqueURL(in dir: URL, for suggested: String) -> URL {
        var name = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name.hasPrefix(".") { name = "download" + name }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

// MARK: - New windows, alert/confirm/prompt, <input type=file>

extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open: open it in the default browser rather than a bare window.
        if let url = action.request.url, url.scheme != "about" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        if let reply = dialogAutoReply { reply("alert: " + message); return }
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        _ = await run(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        if let reply = dialogAutoReply { reply("confirm: " + message); return true }
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await run(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        if let reply = dialogAutoReply { reply("prompt: " + prompt); return defaultText }
        let alert = makeAlert(prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await run(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.prompt = "Upload"
        let response: NSApplication.ModalResponse
        if let w = window() {
            response = await panel.beginSheetModal(for: w)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    private func makeAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let w = window() { return await alert.beginSheetModal(for: w) }
        return alert.runModal()
    }
}
