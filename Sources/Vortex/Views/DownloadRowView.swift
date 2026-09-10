import SwiftUI
import AppKit

public struct DownloadRowView: View {
    @ObservedObject var task: DownloadTask
    @EnvironmentObject var appState: AppState

    @State private var isHovered = false
    @State private var showAddMirrorSheet = false
    @State private var newMirrorInput = ""
    @State private var mirrorError: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Icon, Name, and Status Badge
            HStack(spacing: 12) {
                // File Type Icon
                Image(systemName: fileIconName(for: task.fileName))
                    .font(.system(size: 24))
                    .foregroundColor(iconColor(for: task.fileName))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        // Status pill
                        HStack(spacing: 4) {
                            Image(systemName: task.status.iconName)
                                .font(.system(size: 9))
                            Text(task.status.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(task.status.statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(task.status.statusColor.opacity(0.12))
                        .clipShape(Capsule())

                        if !task.mirrorUrls.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                    .font(.system(size: 8))
                                Text("\(task.mirrorUrls.count + 1) Mirrors")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .clipShape(Capsule())
                        }

                        if task.totalBytes > 0 {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text("\(SpeedTracker.formatBytes(task.downloadedBytes)) of \(SpeedTracker.formatBytes(task.totalBytes))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            Text("(\(Int(task.progress * 100))%)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.8))
                        }
                    }
                }

                Spacer()

                // Actions toolbar
                HStack(spacing: 8) {
                    // Critical action: If link expired, show Auto-Renew in Browser button!
                    if task.status.isExpired {
                        if let pageUrl = task.originalPageUrl {
                            Button {
                                NSWorkspace.shared.open(pageUrl)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "safari.fill")
                                    Text("Auto-Renew in Browser")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help("Opens Chrome: clicking download on the site will automatically renew and resume this download from exact byte position!")
                        }

                        Button {
                            appState.promptRefreshUrl(for: task)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Manual...")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Manually paste renewed URL")
                    } else if task.isDownloading {
                        Button {
                            task.pause()
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 12))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Pause Download")
                    } else if !task.isComplete {
                        Button {
                            task.resume()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                                .frame(width: 28, height: 28)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Resume Download")
                    }

                    // Reveal in Finder
                    Button {
                        let url = URL(fileURLWithPath: task.destinationPath)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")

                    // Context Menu Trigger
                    Menu {
                        if task.isDownloading && task.supportsRange {
                            Section("Throttle Bypass") {
                                Button("⚡ Boost to 16 Streams") {
                                    task.boostStreams(targetCount: 16)
                                }
                                Button("🚀 Turbo Boost to 24 Streams") {
                                    task.boostStreams(targetCount: 24)
                                }
                                Button("🔥 Maximum Boost to 32 Streams") {
                                    task.boostStreams(targetCount: 32)
                                }
                            }
                            Divider()
                        }

                        if task.status.isExpired || !task.isComplete {
                            Button("Refresh Download Address...") {
                                appState.promptRefreshUrl(for: task)
                            }
                        }

                        if !task.isComplete && task.supportsRange {
                            Button("⚡ Add Mirror Link to Multiply Speed...") {
                                newMirrorInput = ""
                                mirrorError = nil
                                showAddMirrorSheet = true
                            }
                        }

                        if let original = task.originalPageUrl {
                            Button("Open Source Page in Browser") {
                                NSWorkspace.shared.open(original)
                            }
                        }

                        Button("Copy Download Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(task.url.absoluteString, forType: .string)
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.removeTask(task, deleteFile: false)
                        } label: {
                            Text("Remove from List")
                        }

                        Button(role: .destructive) {
                            appState.removeTask(task, deleteFile: true)
                        } label: {
                            Text("Delete File & Remove")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 28)
                }
            }

            // Real-Time Segmented Chunk Visualizer (like IDM)
            if !task.segments.isEmpty {
                SegmentBarView(segments: task.segments, totalBytes: task.totalBytes)
            }

            // Bottom stats bar: Speed & ETA
            HStack {
                if task.isDownloading {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.cyan)
                        Text(SpeedTracker.formatSpeed(task.currentSpeed))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }

                    if task.supportsRange && task.segments.filter({ !$0.isFinished }).count < 24 {
                        Button {
                            task.boostStreams(targetCount: 24)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "bolt.fill")
                                Text("Boost Speed (24x)")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Multiply streams to 24 to bypass cyberlocker speed throttling")
                    }

                    Spacer()

                    if let eta = task.eta {
                        HStack(spacing: 4) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 10))
                            Text("ETA: \(SpeedTracker.formatDuration(eta))")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                    }
                } else if task.isComplete {
                    Text("Saved to: \(task.destinationPath)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                } else if case .expired(let reason) = task.status {
                    Text("⚠️ \(reason) - Click 'Refresh URL' to resume")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                    Spacer()
                } else {
                    Text("Saved to: \(task.destinationPath)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(task.status.isExpired ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            if task.status.isExpired || !task.isComplete {
                Button("Refresh Download Address...") {
                    appState.promptRefreshUrl(for: task)
                }
            }

            if !task.isComplete && task.supportsRange {
                Button("⚡ Add Mirror Link to Multiply Speed...") {
                    newMirrorInput = ""
                    mirrorError = nil
                    showAddMirrorSheet = true
                }
            }

            if let original = task.originalPageUrl {
                Button("Open Source Page in Browser") {
                    NSWorkspace.shared.open(original)
                }
            }

            Button("Copy Download Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.url.absoluteString, forType: .string)
            }

            Divider()

            Button(role: .destructive) {
                appState.removeTask(task, deleteFile: false)
            } label: {
                Text("Remove from List")
            }

            Button(role: .destructive) {
                appState.removeTask(task, deleteFile: true)
            } label: {
                Text("Delete File & Remove")
            }
        }
        .sheet(isPresented: $showAddMirrorSheet) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.fill")
                        .foregroundColor(.purple)
                        .font(.system(size: 20))
                    Text("Add Mirror Link")
                        .font(.system(size: 16, weight: .bold))
                }

                Text("Paste an alternative mirror link (1fichier, Mediafire, Qiwi, etc.) for \(task.fileName). Vortex will download chunks from both mirrors simultaneously, combining their speeds:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("https://...", text: $newMirrorInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                if let err = mirrorError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                HStack {
                    Button("Cancel") {
                        showAddMirrorSheet = false
                    }
                    Spacer()
                    Button("Add & Accelerate") {
                        let cleaned = newMirrorInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: cleaned), url.scheme != nil else {
                            mirrorError = "Please enter a valid HTTP/HTTPS URL."
                            return
                        }
                        Task {
                            do {
                                try await task.addMirror(url: url)
                                showAddMirrorSheet = false
                            } catch {
                                mirrorError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(newMirrorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func fileIconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "pkg", "dmg": return "shippingbox.fill"
        case "iso", "bin", "cue": return "opticaldisc.fill"
        case "mp4", "mkv", "mov", "avi": return "film.fill"
        case "mp3", "flac", "wav": return "music.note"
        default: return "doc.fill"
        }
    }

    private func iconColor(for filename: String) -> Color {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": return .orange
        case "pkg", "dmg": return .blue
        case "iso", "bin", "cue": return .purple
        case "mp4", "mkv", "mov": return .pink
        default: return .cyan
        }
    }
}
