import SwiftUI

@main
struct BabelUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The panel window and the menu-bar item are AppKit (see AppDelegate); this scene only
        // exists to give the app its main menu — Edit (copy/paste in the terminals), View, Window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {
                    Button("Open Panel") { delegate.showPanel() }
                        .keyboardShortcut("o")
                }
                CommandGroup(before: .toolbar) {
                    Button("Reload Panel") { delegate.reloadPanel() }
                        .keyboardShortcut("r")
                    Button("Open in Browser") { delegate.openInBrowser() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Divider()
                }
                CommandGroup(after: .appInfo) {
                    Button("Restart Server…") { delegate.restartServer() }
                    Button("Show Server Log") { delegate.showLog() }
                }
            }
    }
}
