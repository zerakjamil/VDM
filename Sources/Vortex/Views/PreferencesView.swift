import SwiftUI

public struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("vortex_auto_extract") private var autoExtract: Bool = true
    @AppStorage("vortex_trash_after_extract") private var trashAfterExtract: Bool = false
    @AppStorage("vortex_default_segments") private var defaultSegments: Int = 16

    @State private var debridService: DebridService = .realDebrid
    @State private var debridApiKey: String = ""
    @State private var maxConcurrent: Int = 2

    public var body: some View {
        TabView {
            // General & Queue
            Form {
                Section("Default Download Location") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default folder where completed and active downloads will be saved:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)

                            Text(appState.downloadDirectory.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )

                            Button("Change...") {
                                let panel = NSOpenPanel()
                                panel.title = "Select Default Download Directory"
                                panel.prompt = "Choose"
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.directoryURL = appState.downloadDirectory
                                if panel.runModal() == .OK, let selectedUrl = panel.url {
                                    appState.setDownloadDirectory(selectedUrl)
                                }
                            }
                            .font(.system(size: 12))

                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appState.downloadDirectory.path)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .help("Reveal in Finder")

                            if appState.downloadDirectory.path != AppState.fallbackDownloadDirectory.path {
                                Button("Reset") {
                                    appState.setDownloadDirectory(AppState.fallbackDownloadDirectory)
                                }
                                .font(.system(size: 11))
                                .help("Reset to Vortex Downloads")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Smart Queue & Concurrency") {
                    Picker("Max Active Downloads:", selection: $maxConcurrent) {
                        Text("1 download (Strictly Sequential)").tag(1)
                        Text("2 downloads (Recommended for games)").tag(2)
                        Text("3 downloads").tag(3)
                        Text("5 downloads").tag(5)
                    }
                    .onChange(of: maxConcurrent) { newVal in
                        appState.queueManager.maxConcurrentDownloads = newVal
                    }

                    Picker("Default Connection Streams:", selection: $defaultSegments) {
                        Text("8 streams (Standard)").tag(8)
                        Text("16 streams (Turbo - Fast)").tag(16)
                        Text("24 streams (High Speed)").tag(24)
                        Text("32 streams (Max Throttle Bypass)").tag(32)
                    }
                }

                Section("Archive Extraction") {
                    Toggle("Automatically extract multi-part archives (RAR / 7z / ZIP) when complete", isOn: $autoExtract)
                    Toggle("Move archive parts to Trash after successful extraction (save SSD space)", isOn: $trashAfterExtract)
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .padding(20)

            // Debrid Cloud Uncapper
            Form {
                Section("Debrid Cloud Account") {
                    Text("Debrid services unrestrict slow cyberlockers (Rapidgator, 1fichier, Mega, Nitroflare) and convert them to unthrottled 10 Gbps direct CDN streams.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Picker("Service Provider:", selection: $debridService) {
                        ForEach(DebridService.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .onChange(of: debridService) { newVal in
                        DebridResolver.shared.selectedService = newVal
                    }

                    SecureField("API Token / Key:", text: $debridApiKey)
                        .onChange(of: debridApiKey) { newVal in
                            DebridResolver.shared.apiKey = newVal
                        }

                    if DebridResolver.shared.isConfigured {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Active: Cyberlocker links will automatically be uncapped!")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                    } else {
                        Text("No API key entered. Links will be downloaded directly.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .tabItem {
                Label("Debrid Uncapper", systemImage: "bolt.shield")
            }
            .padding(20)
        }
        .frame(width: 560, height: 440)
        .onAppear {
            self.debridService = DebridResolver.shared.selectedService
            self.debridApiKey = DebridResolver.shared.apiKey
            self.maxConcurrent = appState.queueManager.maxConcurrentDownloads
        }
    }
}
