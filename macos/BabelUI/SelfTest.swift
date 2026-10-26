#if DEBUG
import AppKit
import WebKit

/// Debug-build smoke test, run with BABEL_UI_SELFTEST=<output dir> (see README → Testing).
/// Opens the panel, checks the page, a terminal WebSocket, JS dialogs and (optionally) a
/// download, writes results.json plus screenshots, and quits when BABEL_UI_SELFTEST_QUIT=1.
enum SelfTest {
    static var outDir: URL? {
        ProcessInfo.processInfo.environment["BABEL_UI_SELFTEST"].map { URL(fileURLWithPath: $0) }
    }
    static var isEnabled: Bool { outDir != nil }

    static func run(app: AppDelegate) {
        Task { await runAsync(app: app) }
    }

    private static func runAsync(app: AppDelegate) async {
        let env = ProcessInfo.processInfo.environment
        guard let out = outDir else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var r: [String: Any] = [:]
        var dialogs: [String] = []
        var loaded = false
        app.web.didFinishLoad = { loaded = true }
        app.web.dialogAutoReply = { dialogs.append($0) }

        app.showPanel()
        r["port"] = app.config.port
        r["activationPolicyWhileOpen"] = NSApp.activationPolicy() == .regular ? "regular" : "accessory"

        for _ in 0..<120 {
            if [.running, .unresponsive, .stopped].contains(app.server.phase) { break }
            if case .failed = app.server.phase { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        r["phase"] = String(describing: app.server.phase)
        r["ownsServer"] = app.server.ownsServer
        r["ownedPID"] = app.server.ownedPID.map { Int($0) } ?? NSNull()

        if app.server.phase == .running {
            for _ in 0..<60 where !loaded { try? await Task.sleep(for: .milliseconds(250)) }
            r["pageLoaded"] = loaded
            try? await Task.sleep(for: .seconds(2))
            r["title"] = app.web.webView.title ?? ""

            let js = """
            const r = { secure: window.isSecureContext,
                        clipboardAPI: !!(navigator.clipboard && navigator.clipboard.writeText) };
            r.ws = await new Promise((done) => {
              let got = "", opened = false;
              const ws = new WebSocket(`ws://${location.host}/ws/term`);
              ws.binaryType = "arraybuffer";
              const finish = (why) => { clearTimeout(t); try { ws.close(); } catch (e) {} ;
                                        done({ opened, why, got: got.slice(0, 300) }); };
              const t = setTimeout(() => finish("timeout"), 10000);
              ws.onopen = () => { opened = true; };
              ws.onmessage = (e) => { got += typeof e.data === "string" ? e.data : new TextDecoder().decode(e.data);
                                      if (got.length > 40) finish("data"); };
              ws.onerror = () => finish("error");
              ws.onclose = () => finish("closed");
            });
            r.confirm = confirm("selftest confirm");
            r.prompt = prompt("selftest prompt", "default-text");
            return r;
            """
            do {
                let value = try await app.web.webView.callAsyncJavaScript(js, contentWorld: .page)
                r["js"] = value ?? NSNull()
            } catch {
                r["jsError"] = "\(error)"
            }
            r["dialogs"] = dialogs

            if let path = env["BABEL_UI_SELFTEST_DOWNLOAD"] {
                _ = try? await app.web.webView.evaluateJavaScript("location.href = \(jsString(path)); 0")
                for _ in 0..<60 where app.web.banner == nil { try? await Task.sleep(for: .milliseconds(250)) }
                r["downloadBanner"] = app.web.banner?.text ?? NSNull()
                r["downloadFile"] = app.web.banner?.file?.path ?? NSNull()
                r["downloadFileExists"] = app.web.banner?.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                try? await Task.sleep(for: .milliseconds(500))
                r["urlAfterDownload"] = app.web.webView.url?.absoluteString ?? NSNull()
            }

            if env["BABEL_UI_SELFTEST_RESTART"] == "1" {
                let before = app.server.ownedPID
                await app.server.restart(includingExternal: false)
                r["restart"] = ["pidBefore": before.map { Int($0) } ?? -1,
                                "pidAfter": app.server.ownedPID.map { Int($0) } ?? -1,
                                "oldPidGone": before.map { kill($0, 0) != 0 } ?? true,
                                "phase": String(describing: app.server.phase)] as [String: Any]
            }

            await app.queue.refresh(server: app.server)
            r["queueSummary"] = app.queue.summary ?? NSNull()
            r["queueDetail"] = app.queue.detail ?? NSNull()

            if let image = try? await app.web.webView.takeSnapshot(configuration: nil) {
                save(image, to: out.appendingPathComponent("web.png"))
            }
        }

        try? await Task.sleep(for: .milliseconds(500))
        if let view = app.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("window.png"))
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        app.buildMenu(menu)
        r["menu"] = menu.items.map { item in
            item.isSeparatorItem ? "---"
                : item.title + (item.isEnabled ? "" : " [disabled]") + (item.state == .on ? " [on]" : "")
        }

        app.window?.performClose(nil)
        try? await Task.sleep(for: .milliseconds(300))
        r["activationPolicyAfterClose"] = NSApp.activationPolicy() == .accessory ? "accessory" : "regular"

        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("results.json"))
        }
        if env["BABEL_UI_SELFTEST_QUIT"] == "1" { NSApp.terminate(nil) }
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private static func save(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
