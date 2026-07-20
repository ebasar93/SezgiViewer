import SwiftUI

@main
struct SezgiViewerApp: App {
    @StateObject private var manager = ProjectManager()

    init() {
        NotificationManager.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add PDFs…") {
                    NotificationCenter.default.post(name: .sezgiAddFiles, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(manager.activeStore == nil)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .sezgiRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(manager.activeStore == nil)

                Button("Export Summary…") {
                    NotificationCenter.default.post(name: .sezgiExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(manager.activeStore == nil)

                Divider()

                Button("Close Project") {
                    manager.closeProject()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(manager.activeStore == nil)
            }
        }
    }
}

/// Shows the welcome screen until a project is opened, then the main UI.
private struct RootView: View {
    @EnvironmentObject private var manager: ProjectManager

    var body: some View {
        if let store = manager.activeStore {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
                // New identity per project so all view state resets on switch.
                .id(manager.activeProject?.id)
        } else {
            WelcomeView()
                .frame(minWidth: 680, minHeight: 440)
        }
    }
}

extension Notification.Name {
    static let sezgiAddFiles = Notification.Name("sezgiAddFiles")
    static let sezgiRefresh = Notification.Name("sezgiRefresh")
    static let sezgiExport = Notification.Name("sezgiExport")
}
