import SwiftUI
import AppKit

@main
struct VortexApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 840, minHeight: 520)
                .background(VisualEffectView().ignoresSafeArea())
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download...") {
                    appState.showNewDownloadSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Batch Importer...") {
                    appState.showBatchImportSheet = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandMenu("Downloads") {
                Button("Resume All") {
                    appState.resumeAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Pause All") {
                    appState.pauseAll()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: appState.globalDownloadSpeed > 0 ? "bolt.fill" : "tornado")
                if appState.globalDownloadSpeed > 0 {
                    Text(SpeedTracker.formatSpeed(appState.globalDownloadSpeed))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// Background blur effect for macOS frosted glass look
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .sidebar
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
