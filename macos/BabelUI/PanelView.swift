import AppKit
import SwiftUI
import WebKit

/// The window's content: the web panel, with a status card on top while the server isn't ready
/// and a banner at the bottom for finished downloads.
struct PanelView: View {
    let server: ServerManager
    let web: WebController
    let restart: () -> Void
    let showLog: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            WebViewHost(webView: web.webView)
                .opacity(showsWeb ? 1 : 0)
            if !showsWeb {
                StatusCard(server: server, web: web, restart: restart, showLog: showLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
            if let banner = web.banner {
                BannerView(banner: banner, dismiss: web.dismissBanner)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: web.banner)
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: server.phase, initial: true) { _, phase in
            if phase == .running { web.loadIfNeeded() }
        }
    }

    private var showsWeb: Bool { server.phase == .running && web.loadError == nil }
}

private struct StatusCard: View {
    let server: ServerManager
    let web: WebController
    let restart: () -> Void
    let showLog: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch server.phase {
            case .checking, .starting:
                ProgressView()
                Text(server.phase == .checking ? "Looking for the babel-ui server…" : "Starting the babel-ui server…")
                    .foregroundStyle(.secondary)
            case .running:
                icon("exclamationmark.triangle")
                Text("Couldn't load the panel").font(.headline)
                Text(web.loadError ?? "").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Reload") { web.load() }.keyboardShortcut(.defaultAction)
            case .unresponsive:
                icon("hourglass")
                Text("Port \(String(server.config.port)) is taken but not answering").font(.headline)
                Text("A babel-ui server may be frozen. Restarting it will stop that process and start a new one.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                buttons(primary: "Restart Server…")
            case .stopped:
                icon("stop.circle")
                Text("The babel-ui server isn't running").font(.headline)
                buttons(primary: "Start Server")
            case .failed(let message):
                icon("exclamationmark.triangle")
                Text("The babel-ui server didn't start").font(.headline)
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: 640, maxHeight: 260)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                buttons(primary: "Try Again")
            }
        }
        .padding(32)
        .frame(maxWidth: 700)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 34)).foregroundStyle(.secondary)
    }

    private func buttons(primary: String) -> some View {
        HStack {
            Button("Show Log", action: showLog)
            Button(primary, action: restart).keyboardShortcut(.defaultAction)
        }
    }
}

private struct BannerView: View {
    let banner: WebController.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .accentColor)
            Text(banner.text).lineLimit(3)
            if let file = banner.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6, y: 2)
    }
}

/// Hosts the long-lived WKWebView (owned by WebController, not recreated by SwiftUI).
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
