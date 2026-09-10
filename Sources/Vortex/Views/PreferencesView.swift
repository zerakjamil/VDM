import SwiftUI

public struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("vortex_auto_extract") private var autoExtract: Bool = true
    @AppStorage("vortex_trash_after_extract") private var trashAfterExtract: Bool = false
    @AppStorage("vortex_default_segments") private var defaultSegments: Int = 16
    @AppStorage("vortex_auto_inject_trackers") private var autoInjectTrackers: Bool = true
    @AppStorage("vortex_proxy_enabled") private var proxyEnabled: Bool = false
    @AppStorage("vortex_proxy_host") private var proxyHost: String = "127.0.0.1"
    @AppStorage("vortex_proxy_port") private var proxyPort: Int = 40000
    @AppStorage("vortex_proxy_is_socks") private var proxyIsSocks: Bool = true

    @State private var debridService: DebridService = .realDebrid
    @State private var debridApiKey: String = ""
    @State private var maxConcurrent: Int = 2
    @ObservedObject private var autoTurbo = AutoTurboSupervisor.shared

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

            // Network & Speed Multipliers
            Form {
                Section("Dual-IP / Proxy Rate-Limit Bypass") {
                    Text("Bypasses single-IP download limits (e.g. MegaUp 3.5 MB/s cap) by alternating odd and even segments between your direct connection and a secondary proxy tunnel (like Cloudflare WARP SOCKS5 or a local proxy).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Toggle("Enable Secondary Proxy Segment Alternation", isOn: $proxyEnabled)

                    if proxyEnabled {
                        Picker("Proxy Protocol:", selection: $proxyIsSocks) {
                            Text("SOCKS5 (e.g. Cloudflare WARP / Tor)").tag(true)
                            Text("HTTP Proxy").tag(false)
                        }

                        HStack {
                            TextField("Host (e.g. 127.0.0.1)", text: $proxyHost)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                            TextField("Port", value: $proxyPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        Text("Tip: If you use Cloudflare WARP in proxy mode ('warp-cli set-mode proxy'), WARP listens on 127.0.0.1:40000.")
                            .font(.system(size: 10))
                            .foregroundColor(.cyan)
                    }
                }

                Section("BitTorrent Peer Discovery Acceleration") {
                    Toggle("Automatically inject live verified public trackers into magnet links", isOn: $autoInjectTrackers)
                    Text("Auto-fetches top 25 high-speed public seed trackers from GitHub so torrents find active peers immediately without stalling at 'connecting'.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.green)
                        Text("\(TorrentEngine.shared.liveTrackers.count) active public trackers ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                        Spacer()
                        Button("Refresh Trackers Now") {
                            TorrentEngine.shared.refreshLiveTrackers()
                        }
                        .font(.system(size: 11))
                    }
                }

                Section("⚡ Auto-Turbo ISP Burst Recovery (ZTE Smart Gateway)") {
                    Text("Kurdistan Net / FTTH allocates a 2GB–4GB burst quota at 15 MB/s before throttling down to 3.x MB/s. Auto-Turbo automatically commands your local ZTE MT-0011 Smart Gateway to soft-restart the PPPoE session, resetting your IP and instantly unlocking a fresh 15 MB/s burst without user intervention.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Toggle("Enable Automated ISP Burst Quota Recovery", isOn: $autoTurbo.isEnabled)

                    if autoTurbo.isEnabled {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Router IP Gateway:")
                                    .font(.system(size: 11, weight: .medium))
                                TextField("192.168.1.1", text: $autoTurbo.routerHost)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account:")
                                    .font(.system(size: 11, weight: .medium))
                                TextField("user", text: $autoTurbo.routerUser)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Router Password:")
                                    .font(.system(size: 11, weight: .medium))
                                SecureField("User-xxxx", text: $autoTurbo.routerPass)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Trigger When Speed Drops Below:")
                                    .font(.system(size: 11, weight: .medium))
                                HStack {
                                    TextField("3.8", value: $autoTurbo.speedThresholdMBs, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("MB/s")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Minimum Cooldown Between Reboots:")
                                    .font(.system(size: 11, weight: .medium))
                                HStack {
                                    TextField("5", value: $autoTurbo.cooldownMinutes, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 50)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("minutes")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        HStack {
                            Circle()
                                .fill(autoTurbo.isRebooting ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text("Guardian Status: \(autoTurbo.statusMessage)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            Spacer()

                            Button {
                                Task {
                                    await autoTurbo.triggerManualReboot()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                    Text("Test Reboot Now")
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .disabled(autoTurbo.isRebooting)
                        }
                    }
                }
            }
            .tabItem {
                Label("Network & Turbo", systemImage: "network")
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
        .frame(width: 580, height: 480)
        .onAppear {
            self.debridService = DebridResolver.shared.selectedService
            self.debridApiKey = DebridResolver.shared.apiKey
            self.maxConcurrent = appState.queueManager.maxConcurrentDownloads
        }
    }
}
