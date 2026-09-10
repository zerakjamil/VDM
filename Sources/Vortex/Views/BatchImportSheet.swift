import SwiftUI

public struct BatchImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var rawText: String = ""
    @State private var destinationDirectory: URL = AppState.defaultDownloadDirectory
    @State private var segments: Int = 16
    @State private var startImmediately: Bool = true

    private var parsedUrls: [URL] {
        rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") || $0.lowercased().hasPrefix("magnet:")) }
            .compactMap { URL(string: $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch Link Importer")
                        .font(.system(size: 18, weight: .bold))
                    Text("Paste multi-part archive links or a list of download URLs")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Textarea
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("URLs (one per line):")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(parsedUrls.count) valid links detected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(parsedUrls.isEmpty ? .secondary : .cyan)
                }

                TextEditor(text: $rawText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }

            // Settings
            HStack(spacing: 20) {
                // Streams picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Streams per Download:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $segments) {
                        Text("8 streams (Standard)").tag(8)
                        Text("16 streams (Turbo)").tag(16)
                        Text("24 streams (High Speed)").tag(24)
                        Text("32 streams (Max Throttle Bypass)").tag(32)
                    }
                    .labelsHidden()
                }

                // Destination Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save to:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = destinationDirectory
                        if panel.runModal() == .OK, let url = panel.url {
                            destinationDirectory = url
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(destinationDirectory.lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Toggle("Auto-start with Smart Queue (respects max concurrent downloads)", isOn: $startImmediately)
                .font(.system(size: 12))

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import & Queue \(parsedUrls.count) Downloads") {
                    for url in parsedUrls {
                        appState.addDownload(
                            url: url,
                            destinationDirectory: destinationDirectory,
                            segments: segments,
                            startImmediately: startImmediately
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(parsedUrls.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
        .onAppear {
            destinationDirectory = appState.downloadDirectory
        }
    }
}
