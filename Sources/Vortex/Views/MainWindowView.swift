import SwiftUI

public struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""

    public var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 14) {
                // Branding
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 32, height: 32)
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("VORTEX")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .tracking(1.5)
                        Text("Download Manager")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Divider()

                // Categories
                List(DownloadCategory.allCases, selection: $appState.selectedCategory) { category in
                    HStack {
                        Label(category.rawValue, systemImage: category.icon)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        let count = countFor(category)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeColorFor(category).opacity(0.15))
                                .foregroundColor(badgeColorFor(category))
                                .clipShape(Capsule())
                        }
                    }
                    .tag(category)
                }
                .listStyle(.sidebar)

                Spacer()

                // Global Speed & Sleep status
                VStack(spacing: 8) {
                    if appState.globalDownloadSpeed > 0 {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.cyan)
                            Text(SpeedTracker.formatSpeed(appState.globalDownloadSpeed))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.cyan.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(SleepPreventer.shared.isHoldingAssertion ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(SleepPreventer.shared.isHoldingAssertion ? "Mac Sleep Prevented" : "System Idle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
            .frame(minWidth: 220, idealWidth: 230)
        } detail: {
            // Main Content Area
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Text(appState.selectedCategory.rawValue)
                        .font(.system(size: 18, weight: .bold))

                    Spacer()

                    // Quick Global Actions
                    Button {
                        appState.resumeAll()
                    } label: {
                        Image(systemName: "play.circle")
                        Text("Resume All")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))

                    Button {
                        appState.pauseAll()
                    } label: {
                        Image(systemName: "pause.circle")
                        Text("Pause All")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))

                    // Add Button
                    Button {
                        appState.showNewDownloadSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text("New Download")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    // Batch Import Button
                    Button {
                        appState.showBatchImportSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Batch...")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Paste multiple links or multi-part game archives")

                    // Preferences Button
                    Button {
                        appState.showPreferencesSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Vortex Preferences & Debrid Settings")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.primary.opacity(0.02))

                Divider()

                // Downloads List
                let visibleTasks = filteredTasks

                if visibleTasks.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        Image(systemName: emptyStateIcon)
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text(emptyStateText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)

                        if appState.selectedCategory == .all {
                            Button("Add First Download") {
                                appState.showNewDownloadSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleTasks) { task in
                                DownloadRowView(task: task)
                                    .environmentObject(appState)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .sheet(isPresented: $appState.showNewDownloadSheet) {
            NewDownloadSheet(isPresented: $appState.showNewDownloadSheet)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showBatchImportSheet) {
            BatchImportSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showPreferencesSheet) {
            PreferencesView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showRefreshSheet) {
            if let task = appState.taskToRefresh {
                RefreshUrlSheet(task: task, isPresented: $appState.showRefreshSheet)
            }
        }
    }

    private var filteredTasks: [DownloadTask] {
        let base = appState.filteredTasks
        if searchText.isEmpty { return base }
        return base.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
    }

    private func countFor(_ category: DownloadCategory) -> Int {
        switch category {
        case .all: return appState.tasks.count
        case .downloading: return appState.tasks.filter { $0.isDownloading }.count
        case .completed: return appState.tasks.filter { $0.isComplete }.count
        case .paused: return appState.tasks.filter { $0.status == .paused }.count
        case .expired: return appState.tasks.filter { $0.status.isExpired }.count
        }
    }

    private func badgeColorFor(_ category: DownloadCategory) -> Color {
        switch category {
        case .all: return .secondary
        case .downloading: return .cyan
        case .completed: return .green
        case .paused: return .yellow
        case .expired: return .orange
        }
    }

    private var emptyStateIcon: String {
        switch appState.selectedCategory {
        case .all: return "arrow.down.circle"
        case .downloading: return "bolt.slash"
        case .completed: return "tray"
        case .paused: return "pause"
        case .expired: return "checkmark.shield"
        }
    }

    private var emptyStateText: String {
        switch appState.selectedCategory {
        case .all: return "No downloads yet"
        case .downloading: return "No active downloads"
        case .completed: return "No completed downloads"
        case .paused: return "No paused downloads"
        case .expired: return "No expired downloads"
        }
    }
}
