import AppKit
import ServiceManagement
import SwiftUI

/// Menu-bar item + the panel window. The app runs as a menu-bar accessory and shows a Dock icon
/// only while the panel window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.load()
    private(set) lazy var server = ServerManager(config: config)
    private(set) lazy var web = WebController(config: config)
    let queue = QueueMonitor()

    private var statusItem: NSStatusItem!
    private(set) var window: NSWindow?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        let launchedAtLogin = Self.launchedAsLoginItem()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        server.onChange = { [weak self] in self?.updateStatusIcon() }

        web.presentWindow = { [weak self] in
            self?.showPanel()
            return self?.window
        }

        // `kill <pid>` / logout: quit the normal way, so a server we started gets stopped too.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src

        Task { await server.ensureRunning() }
        queue.start(server: server)

        #if DEBUG
        if SelfTest.isEnabled {
            SelfTest.run(app: self)
            return
        }
        #endif
        if !launchedAtLogin { showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        server.stopOwnedNow()   // only a server this app started
        return .terminateNow
    }

    // MARK: - Panel window

    @objc func showPanel() {
        if window == nil { window = makeWindow() }
        if let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if server.phase == .running { web.loadIfNeeded() }
    }

    private func makeWindow() -> NSWindow {
        let root = PanelView(server: server, web: web,
                             restart: { [weak self] in self?.restartServer() },
                             showLog: { [weak self] in self?.showLog() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.title = "Babel UI"
        w.isReleasedWhenClosed = false   // keep the web view (and its terminals) when closed
        w.tabbingMode = .disallowed
        // Open in whatever Space you're in (even over a full-screen app) instead of jumping to the
        // Space it was last on; never become a full-screen Space of its own (green button = zoom).
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("BabelUIPanel")
        titleTracking()
        return w
    }

    /// Mirror the page title into the window title.
    private func titleTracking() {
        withObservationTracking { _ = web.title } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.window?.title = self.web.title
                self.titleTracking()
            }
        }
        window?.title = web.title
    }

    @objc func reloadPanel() {
        web.load()
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(config.baseURL)
    }

    @objc func showLog() {
        if FileManager.default.fileExists(atPath: config.log.path) {
            NSWorkspace.shared.open(config.log)   // Console.app by default
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([config.log.deletingLastPathComponent()])
        }
    }

    // MARK: - Server

    @objc func restartServer() {
        switch server.phase {
        case .stopped, .failed:
            Task { await server.ensureRunning() }
            return
        case .checking, .starting:
            return
        case .running, .unresponsive:
            break
        }
        let external = !server.ownsServer
        let alert = NSAlert()
        alert.messageText = "Restart the babel-ui server?"
        var info = "Terminal tabs open in the panel will be disconnected. The shared ssh connection to the cluster stays up."
        if external {
            info += "\n\nThis server wasn't started by Babel UI (probably by the babel-ui command). "
                + "It will be stopped and Babel UI will start a new one on port \(config.port)."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await server.restart(includingExternal: external)
            if server.phase == .running { web.load() }
        }
    }

    // MARK: - Launch at login

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change “Launch at Login”"
            alert.informativeText = error.localizedDescription
                + "\n\nIf this copy of the app isn't in Applications, move it there and try again."
            NSApp.activate()
            alert.runModal()
        }
    }

    /// True when macOS opened us as a login item (then we stay in the menu bar without a window).
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else { return false }
        return prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: - Status item

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Babel UI")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = server.phase != .running
        button.toolTip = "Babel UI — " + phaseText
    }

    var phaseText: String {
        let port = String(config.port)
        switch server.phase {
        case .checking: return "checking…"
        case .starting: return "starting server…"
        case .running:
            return server.ownsServer ? "server running on port \(port)"
                                     : "using the server already running on port \(port)"
        case .unresponsive: return "port \(port) is taken but not answering"
        case .stopped: return "server stopped"
        case .failed: return "server failed to start"
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app; the web view lives on.
        NSApp.setActivationPolicy(.accessory)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        queue.refreshIfStale(server: server)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(menu)
    }

    func buildMenu(_ menu: NSMenu) {
        menu.addItem(disabled: "Babel UI — " + phaseText)
        if server.phase == .running, let summary = queue.summary {
            let item = menu.addItem(disabled: summary)
            item.toolTip = queue.detail
        }
        menu.addItem(.separator())

        menu.addItem(action: "Open Panel", #selector(showPanel), self, key: "o")
        menu.addItem(action: "Open in Browser", #selector(openInBrowser), self)
        let restartTitle: String
        switch server.phase {
        case .stopped, .failed: restartTitle = "Start Server"
        default: restartTitle = "Restart Server…"
        }
        let restart = menu.addItem(action: restartTitle, #selector(restartServer), self)
        restart.isEnabled = server.phase != .checking && server.phase != .starting
        menu.addItem(action: "Show Server Log", #selector(showLog), self)
        menu.addItem(.separator())

        let login = menu.addItem(action: "Launch at Login", #selector(toggleLaunchAtLogin), self)
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval:
            login.state = .mixed
            login.toolTip = "Waiting for approval in System Settings → General → Login Items"
        default: login.state = .off
        }
        menu.addItem(.separator())
        let quitTitle = server.ownsServer ? "Quit Babel UI (stops the server)" : "Quit Babel UI"
        menu.addItem(action: quitTitle, #selector(NSApplication.terminate(_:)), NSApp, key: "q")
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(disabled title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }

    @discardableResult
    func addItem(action title: String, _ selector: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        addItem(item)
        return item
    }
}
