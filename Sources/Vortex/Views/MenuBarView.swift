import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "tornado")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.cyan)
                Text("Vortex")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                if appState.globalDownloadSpeed > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(SpeedTracker.formatSpeed(appState.globalDownloadSpeed))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Divider()

            // Active tasks preview
            let activeTasks = appState.tasks.filter { $0.isDownloading }
            if activeTasks.isEmpty {
                VStack(spacing: 4) {
                    Text("No Active Downloads")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                ForEach(activeTasks.prefix(4)) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(task.fileName)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(SpeedTracker.formatSpeed(task.currentSpeed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.cyan)
                        }

                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .tint(.cyan)

                        HStack {
                            Text("\(SpeedTracker.formatBytes(task.downloadedBytes)) / \(SpeedTracker.formatBytes(task.totalBytes))")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let eta = task.eta {
                                Text("ETA: \(SpeedTracker.formatDuration(eta))")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Quick actions
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    appState.resumeAll()
                } label: {
                    Label("Resume All Downloads", systemImage: "play.fill")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                Button {
                    appState.pauseAll()
                } label: {
                    Label("Pause All Downloads", systemImage: "pause.fill")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                Divider()

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    Label("Open Vortex Window", systemImage: "macwindow")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Vortex", systemImage: "power")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 280)
    }
}
