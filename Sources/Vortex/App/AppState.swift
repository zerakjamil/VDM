import Foundation
import SwiftUI
import AppKit

public enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "All Downloads"
    case downloading = "Downloading"
    case completed = "Completed"
    case paused = "Paused"
    case expired = "Expired / Needs Renewal"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .expired: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var tasks: [DownloadTask] = []
    @Published public var selectedCategory: DownloadCategory = .all
    @Published public var selectedTask: DownloadTask? = nil

    // Sheets
    @Published public var showNewDownloadSheet: Bool = false
    @Published public var showBatchImportSheet: Bool = false
    @Published public var showPreferencesSheet: Bool = false
    @Published public var showRefreshSheet: Bool = false
    @Published public var taskToRefresh: DownloadTask? = nil

    // Global Stats
    @Published public var globalDownloadSpeed: Double = 0.0
    @Published public var queueManager: QueueManager!

    // Download Directory
    nonisolated public static let defaultFolderKey = "vortex_download_dir"

    nonisolated public static var fallbackDownloadDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let vortexDir = downloads.appendingPathComponent("Vortex Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vortexDir.path) {
            try? FileManager.default.createDirectory(at: vortexDir, withIntermediateDirectories: true)
        }
        return vortexDir
    }

    nonisolated public static var defaultDownloadDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: defaultFolderKey), !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                    return url
                }
                if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                    return url
                }
            }
            return fallbackDownloadDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: defaultFolderKey)
        }
    }

    @Published public var downloadDirectory: URL = AppState.defaultDownloadDirectory

    public func setDownloadDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AppState.defaultDownloadDirectory = url
        self.downloadDirectory = url
    }

    private var dockTimer: Timer?
    private var lastClipboardString: String = ""

    public init() {
        self.queueManager = QueueManager(appState: self)
        loadSavedDownloads()
        startDockProgressTimer()
        setupIpcServer()
    }

    private func setupIpcServer() {
        VortexServer.shared.onCheckStatus = { [weak self] in
            guard let self = self else { return ["status": "ok"] }
            let active = self.tasks.filter { $0.isDownloading }.count
            let expiredList = self.tasks.filter { $0.status.isExpired }.map { t in
                [
                    "id": t.id.uuidString,
                    "fileName": t.fileName,
                    "originalPageUrl": t.originalPageUrl?.absoluteString ?? "",
                    "downloadedBytes": t.downloadedBytes,
                    "totalBytes": t.totalBytes,
                    "progress": t.progress
                ] as [String: Any]
            }
            return [
                "status": "running",
                "version": "1.0.0",
                "activeDownloads": active,
                "totalDownloads": self.tasks.count,
                "globalSpeed": self.globalDownloadSpeed,
                "expiredDownloads": expiredList
            ]
        }

        VortexServer.shared.onListDownloads = { [weak self] in
            guard let self = self else { return [] }
            return self.tasks.map { t in
                [
                    "id": t.id.uuidString,
                    "fileName": t.fileName,
                    "status": "\(t.status)",
                    "downloadedBytes": t.downloadedBytes,
                    "totalBytes": t.totalBytes,
                    "progress": t.progress,
                    "currentSpeed": t.currentSpeed,
                    "segments": t.segments.map { s in
                        [
                            "id": s.id,
                            "start": s.startOffset,
                            "current": s.currentOffset,
                            "end": s.endOffset,
                            "state": "\(s.state)"
                        ]
                    }
                ] as [String: Any]
            }
        }

        VortexServer.shared.onAddDownload = { [weak self] url, pageUrl, filename, headers, segments in
            guard let self = self else { return }
            let dest = self.downloadDirectory
            let cleanName = (filename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : filename
            self.addDownload(
                url: url,
                originalPageUrl: pageUrl,
                destinationDirectory: dest,
                fileName: cleanName,
                segments: segments,
                customHeaders: headers,
                startImmediately: true
            )
            NSApp.activate(ignoringOtherApps: true)
        }

        VortexServer.shared.onRefreshDownload = { [weak self] taskIdStr, origUrlStr, filenameStr, newUrl, newCookies in
            guard let self = self else { return nil }

            var matchedTask: DownloadTask? = nil
            if let tid = taskIdStr, let uuid = UUID(uuidString: tid) {
                matchedTask = self.tasks.first(where: { $0.id == uuid })
            }

            if matchedTask == nil, let origStr = origUrlStr, let origUrl = URL(string: origStr) {
                matchedTask = self.tasks.first(where: {
                    ($0.status.isExpired || $0.status == .paused) &&
                    ($0.originalPageUrl?.path == origUrl.path || $0.originalPageUrl?.host == origUrl.host)
                })
            }

            if matchedTask == nil {
                let expired = self.tasks.filter { $0.status.isExpired }
                if expired.count == 1 {
                    matchedTask = expired.first
                }
            }

            if matchedTask == nil, let fn = filenameStr, !fn.isEmpty {
                matchedTask = self.tasks.first(where: {
                    ($0.status.isExpired || $0.status == .paused) &&
                    ($0.fileName.localizedCaseInsensitiveContains(fn) || fn.localizedCaseInsensitiveContains($0.fileName))
                })
            }

            guard let task = matchedTask else { return nil }

            do {
                try await task.refreshUrl(newUrl: newUrl, newCookies: newCookies)
                let respObj: [String: Any] = [
                    "success": true,
                    "resumedFrom": task.downloadedBytes,
                    "totalBytes": task.totalBytes,
                    "fileName": task.fileName
                ]
                return try? JSONSerialization.data(withJSONObject: respObj)
            } catch {
                let errObj: [String: Any] = [
                    "success": false,
                    "error": error.localizedDescription
                ]
                return try? JSONSerialization.data(withJSONObject: errObj)
            }
        }

        VortexServer.shared.start()
    }

    public func handleDeepLink(_ url: URL) {
        // vortex://download?url=...&referer=...&filename=...
        guard url.scheme == "vortex", url.host == "download" || url.path.contains("download") else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        guard let targetUrlString = queryItems.first(where: { $0.name == "url" })?.value,
              let targetUrl = URL(string: targetUrlString) else { return }

        let referer = queryItems.first(where: { $0.name == "referer" })?.value
        let filename = queryItems.first(where: { $0.name == "filename" })?.value
        let cookies = queryItems.first(where: { $0.name == "cookies" })?.value
        let userAgent = queryItems.first(where: { $0.name == "userAgent" })?.value

        var headers: [String: String] = [:]
        if let r = referer { headers["Referer"] = r }
        if let c = cookies { headers["Cookie"] = c }
        if let ua = userAgent { headers["User-Agent"] = ua }

        let pageUrl = referer.flatMap { URL(string: $0) }
        let dest = self.downloadDirectory

        addDownload(
            url: targetUrl,
            originalPageUrl: pageUrl,
            destinationDirectory: dest,
            fileName: filename,
            segments: 8,
            customHeaders: headers,
            startImmediately: true
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    public func loadSavedDownloads() {
        let metas = DownloadMetadata.loadAll()
        self.tasks = metas.map { meta in
            let task = DownloadTask(metadata: meta)
            task.onStatusChanged = { [weak self] t in
                self?.queueManager?.onTaskStatusChanged(task: t)
            }
            return task
        }
    }

    public var filteredTasks: [DownloadTask] {
        switch selectedCategory {
        case .all:
            return tasks
        case .downloading:
            return tasks.filter { $0.isDownloading }
        case .completed:
            return tasks.filter { $0.isComplete }
        case .paused:
            return tasks.filter { $0.status == .paused }
        case .expired:
            return tasks.filter { $0.status.isExpired }
        }
    }

    public func addDownload(
        url: URL,
        originalPageUrl: URL? = nil,
        destinationDirectory: URL? = nil,
        fileName: String? = nil,
        segments: Int = 16,
        customHeaders: [String: String] = [:],
        startImmediately: Bool = true
    ) {
        let dest = destinationDirectory ?? self.downloadDirectory
        let task = DownloadTask(
            url: url,
            originalPageUrl: originalPageUrl,
            destinationDirectory: dest,
            fileName: fileName,
            preferredSegments: segments,
            customHeaders: customHeaders
        )

        task.onStatusChanged = { [weak self] t in
            self?.queueManager?.onTaskStatusChanged(task: t)
        }

        tasks.insert(task, at: 0)
        task.saveMetadata()

        if startImmediately {
            let activeCount = tasks.filter { $0.isDownloading }.count
            if activeCount < (queueManager?.maxConcurrentDownloads ?? 2) {
                task.start()
            } else {
                task.status = .queued
            }
        }
    }

    public func removeTask(_ task: DownloadTask, deleteFile: Bool = false) {
        task.deleteMetadataAndFiles(deleteDownloadedFile: deleteFile)
        tasks.removeAll(where: { $0.id == task.id })
        if selectedTask?.id == task.id {
            selectedTask = nil
        }
    }

    public func pauseAll() {
        for task in tasks where task.isDownloading {
            task.pause()
        }
    }

    public func resumeAll() {
        for task in tasks where task.status == .paused {
            task.resume()
        }
    }

    public func promptRefreshUrl(for task: DownloadTask) {
        self.taskToRefresh = task
        self.showRefreshSheet = true
    }

    // MARK: - Dock Progress Bar & Badge

    private func startDockProgressTimer() {
        dockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let active = self.tasks.filter { $0.isDownloading }
                self.globalDownloadSpeed = active.reduce(0) { $0 + $1.currentSpeed }

                let dockTile = NSApp.dockTile
                if active.isEmpty {
                    dockTile.badgeLabel = nil
                } else {
                    let totalBytes = active.reduce(0) { $0 + $1.totalBytes }
                    let downloaded = active.reduce(0) { $0 + $1.downloadedBytes }
                    if totalBytes > 0 {
                        let pct = Int((Double(downloaded) / Double(totalBytes)) * 100)
                        dockTile.badgeLabel = "\(pct)%"
                    } else {
                        dockTile.badgeLabel = "\(active.count)↓"
                    }
                }
            }
        }
    }
}
