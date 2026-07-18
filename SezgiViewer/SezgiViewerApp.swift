import SwiftUI

@main
struct SezgiViewerApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        NotificationManager.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add PDFs…") {
                    NotificationCenter.default.post(name: .sezgiAddFiles, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .sezgiRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Export Summary…") {
                    NotificationCenter.default.post(name: .sezgiExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let sezgiAddFiles = Notification.Name("sezgiAddFiles")
    static let sezgiRefresh = Notification.Name("sezgiRefresh")
    static let sezgiExport = Notification.Name("sezgiExport")
}
