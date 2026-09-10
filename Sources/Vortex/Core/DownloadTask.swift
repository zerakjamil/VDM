import Foundation
import SwiftUI

@MainActor
public final class DownloadTask: ObservableObject, Identifiable {
    public let id: UUID

    @Published public var url: URL
    @Published public var originalPageUrl: URL?
    @Published public var destinationPath: String
    @Published public var fileName: String
    @Published public var totalBytes: Int64
    @Published public var downloadedBytes: Int64
    @Published public var supportsRange: Bool
    @Published public var segments: [SegmentInfo]
    @Published public var status: DownloadStatus {
        didSet {
            onStatusChanged?(self)
        }
    }
    public var onStatusChanged: (@MainActor (DownloadTask) -> Void)?
    @Published public var currentSpeed: Double = 0.0
    @Published public var eta: TimeInterval? = nil
    @Published public var progress: Double = 0.0

    public var preferredSegments: Int
    public var customHeaders: [String: String]
    public let dateAdded: Date

    private lazy var streamBalancer = StreamBalancer(task: self)
    private var storage: FileStorage?
    private var workers: [Int: SegmentWorker] = [:]
    private var coordinatorTask: Task<Void, Never>?
    private let speedTracker = SpeedTracker()
    private var progressTimer: Timer?

    public init(
        id: UUID = UUID(),
        url: URL,
        originalPageUrl: URL? = nil,
        destinationDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!,
        fileName: String? = nil,
        preferredSegments: Int = 16,
        customHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.url = url
        self.originalPageUrl = originalPageUrl
        self.preferredSegments = preferredSegments
        self.customHeaders = customHeaders
        self.dateAdded = Date()

        let initialName = DownloadTask.resolveInitialFileName(fileName: fileName, url: url, originalPageUrl: originalPageUrl)
        self.fileName = initialName
        self.destinationPath = destinationDirectory.appendingPathComponent(initialName).path
        self.totalBytes = 0
        self.downloadedBytes = 0
        self.supportsRange = false
        self.segments = []
        self.status = .queued
    }

    public init(metadata: DownloadMetadata) {
        self.id = metadata.id
        self.url = URL(string: metadata.url)!
        if let original = metadata.originalPageUrl {
            self.originalPageUrl = URL(string: original)
        }
        self.destinationPath = metadata.destinationPath
        self.fileName = metadata.fileName
        self.totalBytes = metadata.totalBytes
        self.supportsRange = metadata.supportsRange
        self.segments = metadata.segments
        self.customHeaders = metadata.customHeaders
        self.dateAdded = metadata.dateAdded
        self.preferredSegments = max(1, metadata.segments.count)
        self.status = metadata.status == .downloading ? .paused : metadata.status

        let downloaded = metadata.segments.reduce(0) { $0 + $1.bytesDownloaded }
        self.downloadedBytes = downloaded
        if metadata.totalBytes > 0 {
            self.progress = Double(downloaded) / Double(metadata.totalBytes)
        }
    }

    public var isComplete: Bool {
        return status == .completed
    }

    public var isDownloading: Bool {
        return status == .downloading || status == .connecting
    }

    public var isTorrent: Bool {
        return url.scheme?.lowercased() == "magnet" || url.pathExtension.lowercased() == "torrent"
    }

    // MARK: - Download Lifecycle

    public func start() {
        guard !isDownloading else { return }

        if isTorrent {
            status = .connecting
            TorrentEngine.shared.startTorrent(
                task: self,
                magnetUri: url.absoluteString,
                destinationDirectory: URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
            )
            return
        }

        status = .connecting
        streamBalancer.start()
        SleepPreventer.shared.retainSleepAssertion(reason: "Vortex downloading \(fileName)")
        startProgressTimer()

        coordinatorTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                if self.totalBytes <= 0 || self.segments.isEmpty {
                    try await self.probeAndInitialize()
                }

                try await self.runDownloadSegments()
            } catch let error as SegmentError {
                await MainActor.run {
                    self.handleSegmentError(error)
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(error: error.localizedDescription)
                    self.cleanupAfterStop()
                }
            }
        }
    }

    public func pause() {
        guard isDownloading else { return }

        if isTorrent {
            TorrentEngine.shared.pause(task: self)
            saveMetadata()
            return
        }

        status = .paused
        coordinatorTask?.cancel()
        coordinatorTask = nil

        for (_, worker) in workers {
            worker.cancel()
        }
        workers.removeAll()

        storage?.flush()
        cleanupAfterStop()
        saveMetadata()
    }

    public func resume() {
        guard status == .paused || status.isExpired else { return }
        start()
    }

    public func cancel() {
        pause()
        status = .failed(error: "Cancelled by user")
        cleanupAfterStop()
    }

    /// Key feature: Refresh Download Address for expired temporary tokens (romsfun, etc.)
    public func refreshUrl(newUrl: URL, newCookies: String? = nil) async throws {
        if let c = newCookies, !c.isEmpty {
            self.customHeaders["Cookie"] = c
        }

        // Validate new URL
        var request = URLRequest(url: newUrl)
        request.httpMethod = "HEAD"
        if customHeaders["User-Agent"] == nil {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        }
        for (k, v) in customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Vortex", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw NSError(domain: "Vortex", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode) for renewed link"])
        }

        // Verify content length matches the original file if known
        let newLength = http.expectedContentLength
        if totalBytes > 0 && newLength > 0 && newLength != totalBytes {
            throw NSError(domain: "Vortex", code: -2, userInfo: [NSLocalizedDescriptionKey: "File size mismatch! Expected \(SpeedTracker.formatBytes(totalBytes)) but new link has \(SpeedTracker.formatBytes(newLength)). Make sure you copied the exact same file."])
        }

        self.url = newUrl
        saveMetadata()

        // Resume download with new URL from exact current byte offsets!
        resume()
    }

    // MARK: - Internal Engine

    private func getHeader(_ name: String, from response: HTTPURLResponse) -> String? {
        if let val = response.value(forHTTPHeaderField: name), !val.trimmingCharacters(in: .whitespaces).isEmpty {
            return val
        }
        for (k, v) in response.allHeaderFields {
            if let keyStr = k as? String, keyStr.caseInsensitiveCompare(name) == .orderedSame {
                if let strVal = v as? String, !strVal.trimmingCharacters(in: .whitespaces).isEmpty {
                    return strVal
                }
            }
        }
        return nil
    }

    private func probeAndInitialize() async throws {
        // Step 1: Probe with Range: bytes=0-0 to discover true Content-Range and total size
        // (Cyberlockers like MegaUp/megadl.boats omit Content-Length on HEAD, but return 206 with Content-Range on Range GET)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        if customHeaders["User-Agent"] == nil {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        }
        for (k, v) in customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Use bytes(for:) to inspect response headers without buffering large bodies into RAM if Range is ignored
        let (_, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Vortex", code: -1, userInfo: [NSLocalizedDescriptionKey: "Probe failed: not an HTTP response"])
        }

        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 410 {
            throw SegmentError.linkExpired(statusCode: http.statusCode, message: "Initial link is already invalid or expired")
        }

        // Extract filename from Content-Disposition or final URL if present
        var finalName: String? = nil
        if let disposition = getHeader("Content-Disposition", from: http) {
            finalName = extractFilename(from: disposition)
        }
        if finalName == nil, let respUrl = http.url {
            let last = respUrl.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !last.isEmpty && last != "/" && Int(last) == nil && last.contains(".") {
                finalName = last.removingPercentEncoding ?? last
            }
        }

        if let name = finalName, !name.isEmpty, Int(name) == nil {
            self.fileName = name
            let dir = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
            self.destinationPath = dir.appendingPathComponent(name).path
        }

        // Guarantee destinationPath is a file, never a directory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: self.destinationPath, isDirectory: &isDir), isDir.boolValue {
            let safeName = self.fileName.isEmpty ? "download.bin" : self.fileName
            self.destinationPath = (self.destinationPath as NSString).appendingPathComponent(safeName)
        }

        var detectedTotalBytes: Int64 = 0
        var rangeSupported = false

        // Check Content-Range header (e.g. "bytes 0-0/4673405506")
        if let contentRange = getHeader("Content-Range", from: http),
           let size = extractTotalSizeFromContentRange(contentRange) {
            detectedTotalBytes = size
            rangeSupported = true
        } else if http.statusCode == 206 {
            rangeSupported = true
            let cl = http.expectedContentLength
            if cl > 1 {
                detectedTotalBytes = cl
            }
        } else if http.statusCode == 200 {
            let accept = (getHeader("Accept-Ranges", from: http) ?? "").lowercased().contains("bytes")
            let len = http.expectedContentLength
            if len > 1 {
                detectedTotalBytes = len
                rangeSupported = accept
            }
        }

        self.totalBytes = detectedTotalBytes
        self.supportsRange = rangeSupported && detectedTotalBytes > 0

        // Build segments with adaptive scaling (bypasses per-connection host throttles)
        if supportsRange && totalBytes > 5 * 1024 * 1024 {
            var targetSegments = preferredSegments
            if targetSegments <= 16 {
                if totalBytes > 2 * 1024 * 1024 * 1024 {
                    targetSegments = 24 // 24 streams for games > 2GB (MegaUp / FitGirl / ROMs)
                } else if totalBytes > 500 * 1024 * 1024 {
                    targetSegments = 16
                }
            }
            let numSegments = min(targetSegments, max(1, Int(totalBytes / (2 * 1024 * 1024))))
            let chunkSize = totalBytes / Int64(numSegments)
            var newSegments: [SegmentInfo] = []

            for i in 0..<numSegments {
                let start = Int64(i) * chunkSize
                let end = (i == numSegments - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
                newSegments.append(SegmentInfo(id: i, startOffset: start, currentOffset: start, endOffset: end))
            }
            self.segments = newSegments
        } else if totalBytes > 0 {
            // Single segment with known length
            self.segments = [SegmentInfo(id: 0, startOffset: 0, currentOffset: 0, endOffset: totalBytes - 1)]
        } else {
            // Unknown length: stream to EOF (never end at 0 bytes!)
            self.segments = [SegmentInfo(id: 0, startOffset: 0, currentOffset: 0, endOffset: Int64.max - 1)]
        }

        saveMetadata()
    }

    private func extractTotalSizeFromContentRange(_ header: String) -> Int64? {
        // e.g. "bytes 0-0/4673405506" or "bytes 0-10/4673405506"
        guard let slashIndex = header.lastIndex(of: "/") else { return nil }
        let sizeStr = header[header.index(after: slashIndex)...].trimmingCharacters(in: .whitespaces)
        return Int64(sizeStr)
    }

    private func runDownloadSegments() async throws {
        // Prepare storage with direct write
        let fileStorage = FileStorage(filePath: destinationPath)
        try fileStorage.prepareFile(totalSize: totalBytes)
        self.storage = fileStorage

        self.status = .downloading

        try await withThrowingTaskGroup(of: (Int, Error?).self) { group in
            for segment in self.segments where !segment.isFinished {
                let worker = SegmentWorker(
                    segmentId: segment.id,
                    startOffset: segment.startOffset,
                    currentOffset: segment.currentOffset,
                    endOffset: segment.endOffset,
                    storage: fileStorage,
                    customHeaders: self.customHeaders
                ) { [weak self] (segId, bytesDelta, newOffset) in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(segmentId: segId, bytesDelta: bytesDelta, newOffset: newOffset)
                    }
                }

                self.workers[segment.id] = worker
                let workerUrl = self.url

                group.addTask {
                    do {
                        try await worker.execute(url: workerUrl)
                        return (segment.id, nil)
                    } catch {
                        return (segment.id, error)
                    }
                }
            }

            for try await (segId, error) in group {
                if let error = error {
                    throw error
                }
                await MainActor.run {
                    if let index = self.segments.firstIndex(where: { $0.id == segId }) {
                        if self.segments[index].currentOffset > self.segments[index].endOffset || self.segments[index].endOffset >= Int64.max - 1000 {
                            self.segments[index].state = .completed
                        }
                    }
                    self.workers.removeValue(forKey: segId)
                    self.checkDynamicSplit()
                }
            }
        }

        // Verify all segments are truly completed
        let allFinished = segments.allSatisfy { $0.isFinished }
        guard allFinished else {
            throw SegmentError.networkError("Download ended prematurely: not all segments finished")
        }

        // All segments finished!
        storage?.flush()
        storage?.close()
        storage = nil

        if totalBytes <= 0 {
            totalBytes = downloadedBytes
        }

        status = .completed
        cleanupAfterStop()
        saveMetadata()
    }

    /// Dynamic splitting: if a worker finished early and another has > 40MB remaining, split it!
    private func checkDynamicSplit() {
        guard supportsRange, status == .downloading else { return }

        // Find largest remaining segment that is active
        guard let largestIndex = segments.enumerated()
            .filter({ !$0.element.isFinished && $0.element.remainingBytes > 40 * 1024 * 1024 })
            .max(by: { $0.element.remainingBytes < $1.element.remainingBytes })?.offset else {
            return
        }

        let largest = segments[largestIndex]
        let mid = largest.currentOffset + (largest.remainingBytes / 2)
        guard mid < largest.endOffset - (5 * 1024 * 1024) else { return }

        // Stop current worker for largest, split into two
        if let worker = workers[largest.id] {
            worker.cancel()
            workers.removeValue(forKey: largest.id)
        }

        let newId = (segments.map(\.id).max() ?? 0) + 1
        let updatedOriginal = SegmentInfo(id: largest.id, startOffset: largest.startOffset, currentOffset: largest.currentOffset, endOffset: mid, state: .pending)
        let newSegment = SegmentInfo(id: newId, startOffset: mid + 1, currentOffset: mid + 1, endOffset: largest.endOffset, state: .pending)

        segments[largestIndex] = updatedOriginal
        segments.append(newSegment)

        // Launch workers for both halves
        guard let fileStorage = storage else { return }

        for seg in [updatedOriginal, newSegment] {
            let worker = SegmentWorker(
                segmentId: seg.id,
                startOffset: seg.startOffset,
                currentOffset: seg.currentOffset,
                endOffset: seg.endOffset,
                storage: fileStorage,
                customHeaders: self.customHeaders
            ) { [weak self] (segId, bytesDelta, newOffset) in
                Task { @MainActor [weak self] in
                    self?.updateProgress(segmentId: segId, bytesDelta: bytesDelta, newOffset: newOffset)
                }
            }
            workers[seg.id] = worker
            let workerUrl = self.url
            Task {
                try? await worker.execute(url: workerUrl)
            }
        }
    }

    /// On-the-fly stream booster: multiply active connections up to targetCount (16x / 24x / 32x)
    public func boostStreams(targetCount: Int = 24) {
        guard supportsRange, totalBytes > 10 * 1024 * 1024, isDownloading else { return }

        var iterations = 0
        while segments.filter({ !$0.isFinished }).count < targetCount && iterations < 32 {
            iterations += 1
            guard let largestIndex = segments.enumerated()
                .filter({ !$0.element.isFinished && $0.element.remainingBytes > 10 * 1024 * 1024 })
                .max(by: { $0.element.remainingBytes < $1.element.remainingBytes })?.offset else {
                break
            }

            let largest = segments[largestIndex]
            let mid = largest.currentOffset + (largest.remainingBytes / 2)
            guard mid < largest.endOffset - (2 * 1024 * 1024) else { break }

            if let worker = workers[largest.id] {
                worker.cancel()
                workers.removeValue(forKey: largest.id)
            }

            let newId = (segments.map(\.id).max() ?? 0) + 1
            let updatedOriginal = SegmentInfo(id: largest.id, startOffset: largest.startOffset, currentOffset: largest.currentOffset, endOffset: mid, state: .pending)
            let newSegment = SegmentInfo(id: newId, startOffset: mid + 1, currentOffset: mid + 1, endOffset: largest.endOffset, state: .pending)

            segments[largestIndex] = updatedOriginal
            segments.append(newSegment)

            guard let fileStorage = storage else { continue }
            for seg in [updatedOriginal, newSegment] {
                let worker = SegmentWorker(
                    segmentId: seg.id,
                    startOffset: seg.startOffset,
                    currentOffset: seg.currentOffset,
                    endOffset: seg.endOffset,
                    storage: fileStorage,
                    customHeaders: self.customHeaders
                ) { [weak self] (segId, bytesDelta, newOffset) in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(segmentId: segId, bytesDelta: bytesDelta, newOffset: newOffset)
                    }
                }
                workers[seg.id] = worker
                let workerUrl = self.url
                Task {
                    try? await worker.execute(url: workerUrl)
                }
            }
        }
        preferredSegments = segments.count
        saveMetadata()
    }

    private func updateProgress(segmentId: Int, bytesDelta: Int64, newOffset: Int64) {
        if let idx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[idx].currentOffset = newOffset
            if segments[idx].isFinished {
                segments[idx].state = .completed
            } else {
                segments[idx].state = .active
            }
        }

        downloadedBytes += bytesDelta
        speedTracker.record(downloadedBytes: downloadedBytes)

        if totalBytes > 0 {
            progress = min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }
    }

    private func handleSegmentError(_ error: SegmentError) {
        switch error {
        case .linkExpired(let code, let msg):
            status = .expired(reason: "HTTP \(code): \(msg)")
        case .cancelled:
            status = .paused
        default:
            status = .failed(error: error.localizedDescription)
        }
        cleanupAfterStop()
        saveMetadata()
    }

    private var metaSaveCounter: Int = 0

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isDownloading {
                    self.currentSpeed = self.speedTracker.currentSpeedBytesPerSec
                    let remaining = max(0, self.totalBytes - self.downloadedBytes)
                    self.eta = self.speedTracker.estimateRemainingTime(remainingBytes: remaining)

                    self.metaSaveCounter += 1
                    if self.metaSaveCounter % 6 == 0 {
                        self.saveMetadata()
                    }
                } else {
                    self.currentSpeed = 0
                    self.eta = nil
                }
            }
        }
    }

    func cleanupAfterStop() {
        streamBalancer.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        currentSpeed = 0
        eta = nil
        SleepPreventer.shared.releaseSleepAssertion()
    }

    public func saveMetadata() {
        let meta = DownloadMetadata(
            id: id,
            url: url.absoluteString,
            originalPageUrl: originalPageUrl?.absoluteString,
            destinationPath: destinationPath,
            fileName: fileName,
            totalBytes: totalBytes,
            supportsRange: supportsRange,
            segments: segments,
            customHeaders: customHeaders,
            dateAdded: dateAdded,
            status: status
        )
        meta.save()
    }

    public func deleteMetadataAndFiles(deleteDownloadedFile: Bool = false) {
        pause()
        let meta = DownloadMetadata(
            id: id,
            url: url.absoluteString,
            originalPageUrl: originalPageUrl?.absoluteString,
            destinationPath: destinationPath,
            fileName: fileName,
            totalBytes: totalBytes,
            supportsRange: supportsRange,
            segments: segments,
            customHeaders: customHeaders,
            dateAdded: dateAdded,
            status: status
        )
        meta.delete()

        if isTorrent {
            TorrentEngine.shared.cancel(taskId: id)
        }

        if deleteDownloadedFile {
            try? FileManager.default.removeItem(atPath: destinationPath)
        }
    }

    private func extractFilename(from disposition: String) -> String? {
        // 1. filename*=UTF-8''...
        if let range = disposition.range(of: "filename\\*=UTF-8''([^;]+)", options: .regularExpression) {
            let match = String(disposition[range])
            return match.replacingOccurrences(of: "filename*=UTF-8''", with: "").removingPercentEncoding
        }
        // 2. filename="..."
        if let range = disposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
            let match = String(disposition[range])
            return match.replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        // 3. filename=unquoted
        if let range = disposition.range(of: "filename=([^;\\s]+)", options: .regularExpression) {
            let match = String(disposition[range])
            return match.replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'; "))
        }
        return nil
    }

    public static func resolveInitialFileName(fileName: String?, url: URL, originalPageUrl: URL?) -> String {
        let raw = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty && raw != "/" && Int(raw) == nil {
            let clean = (raw as NSString).lastPathComponent.removingPercentEncoding ?? raw
            return clean.isEmpty ? "download.bin" : clean
        }

        // Check if magnet link
        if url.scheme?.lowercased() == "magnet" {
            if let meta = MagnetParser.parse(uri: url.absoluteString) {
                return meta.displayName
            }
            return "Torrent_\(UUID().uuidString.prefix(6))"
        }

        let urlLast = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlLast.isEmpty && urlLast != "/" && Int(urlLast) == nil && urlLast.contains(".") {
            let clean = urlLast.removingPercentEncoding ?? urlLast
            return clean.isEmpty ? "download.bin" : clean
        }

        if let page = originalPageUrl {
            let segments = page.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            for seg in segments.reversed() {
                if Int(seg) == nil && seg != "download" && seg != "roms" && seg != "rom" {
                    var cleaned = seg.removingPercentEncoding ?? seg
                    if let regex = try? NSRegularExpression(pattern: "-\\d+$") {
                        cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "")
                    }
                    let formatted = cleaned.replacingOccurrences(of: "-", with: " ").capitalized
                    if !formatted.isEmpty {
                        return "\(formatted).bin"
                    }
                }
            }
        }

        return "download_\(UUID().uuidString.prefix(6)).bin"
    }
}
