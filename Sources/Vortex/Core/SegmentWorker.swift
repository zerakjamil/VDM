import Foundation

public enum SegmentError: LocalizedError, Sendable {
    case linkExpired(statusCode: Int, message: String)
    case serverDoesNotSupportRange
    case invalidResponse(statusCode: Int)
    case cancelled
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .linkExpired(let code, let msg):
            return "Download link expired (HTTP \(code)): \(msg). Renewal needed."
        case .serverDoesNotSupportRange:
            return "Server does not support partial content (Range requests)."
        case .invalidResponse(let code):
            return "Server returned HTTP \(code)."
        case .cancelled:
            return "Download cancelled."
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }
}

public struct ProxyConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let isSocks: Bool

    public init(host: String, port: Int, isSocks: Bool = true) {
        self.host = host
        self.port = port
        self.isSocks = isSocks
    }
}

/// Thread-safe gate ensuring a CheckedContinuation is resolved AT MOST ONCE.
private final class ContinuationGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var isResolved = false

    func setContinuation(_ cont: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isResolved {
            return false
        }
        self.continuation = cont
        return true
    }

    func resume() {
        lock.lock()
        guard !isResolved, let cont = continuation else {
            isResolved = true
            continuation = nil
            lock.unlock()
            return
        }
        isResolved = true
        continuation = nil
        lock.unlock()
        cont.resume()
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !isResolved, let cont = continuation else {
            isResolved = true
            continuation = nil
            lock.unlock()
            return
        }
        isResolved = true
        continuation = nil
        lock.unlock()
        cont.resume(throwing: error)
    }

    func cancel() {
        resume(throwing: SegmentError.cancelled)
    }
}

public final class SegmentWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let segmentId: Int
    public let startOffset: Int64
    public private(set) var currentOffset: Int64
    public let endOffset: Int64

    private let storage: FileStorage
    private var customHeaders: [String: String]
    private var proxyConfig: ProxyConfiguration?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var activeGate: ContinuationGate?
    private let stateLock = NSLock()

    private let onProgress: @Sendable (Int, Int64, Int64) -> Void // (segmentId, bytesDelta, newCurrentOffset)
    private var isCancelled = false
    private var pendingBytesDelta: Int64 = 0
    private var lastReportTime: CFAbsoluteTime = 0

    // High-Performance Batched Disk I/O Buffer (Eliminates lock contention while ensuring tight disk sync)
    private var writeBuffer = Data()
    private var writeBufferStartOffset: Int64 = -1
    private let writeBufferThreshold = 64 * 1024 // 64 KB fast-commit batch
    private let bufferLock = NSLock()

    public init(
        segmentId: Int,
        startOffset: Int64,
        currentOffset: Int64,
        endOffset: Int64,
        storage: FileStorage,
        customHeaders: [String: String] = [:],
        proxyConfig: ProxyConfiguration? = nil,
        onProgress: @escaping @Sendable (Int, Int64, Int64) -> Void
    ) {
        self.segmentId = segmentId
        self.startOffset = startOffset
        self.currentOffset = currentOffset
        self.endOffset = endOffset
        self.storage = storage
        self.customHeaders = customHeaders
        self.proxyConfig = proxyConfig
        self.onProgress = onProgress
        super.init()
    }

    public func execute(url: URL, maxRetries: Int = 3) async throws {
        if currentOffset > endOffset {
            return // Already completed
        }

        var attempt = 0
        while attempt < maxRetries {
            let cancelled = stateLock.withLock { isCancelled }
            if cancelled { throw SegmentError.cancelled }

            do {
                try await downloadAttempt(url: url)
                try? flushBuffer()
                return // Finished successfully
            } catch let err as SegmentError {
                if case .linkExpired = err {
                    throw err
                }
                if case .cancelled = err {
                    throw err
                }
                attempt += 1
                let nowCancelled = stateLock.withLock { isCancelled }
                if attempt >= maxRetries || nowCancelled {
                    throw err
                }
                // Exponential backoff
                let backoff = Double(attempt) * 1.5
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                let nowCancelled = stateLock.withLock { isCancelled }
                if nowCancelled { throw SegmentError.cancelled }
                attempt += 1
                if attempt >= maxRetries {
                    throw SegmentError.networkError(error.localizedDescription)
                }
                let backoff = Double(attempt) * 1.5
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private func downloadAttempt(url: URL) async throws {
        let gate = ContinuationGate()
        let cancelled = stateLock.withLock { () -> Bool in
            if isCancelled { return true }
            self.activeGate = gate
            return false
        }
        if cancelled { throw SegmentError.cancelled }

        defer {
            let sess = stateLock.withLock { () -> URLSession? in
                let s = self.session
                self.session = nil
                self.dataTask = nil
                if self.activeGate === gate {
                    self.activeGate = nil
                }
                return s
            }
            sess?.invalidateAndCancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if !gate.setContinuation(continuation) {
                    continuation.resume(throwing: SegmentError.cancelled)
                    return
                }

                let shouldCancel = stateLock.withLock { self.isCancelled }
                if shouldCancel {
                    gate.cancel()
                    return
                }

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30.0
                config.timeoutIntervalForResource = 3600.0
                config.httpMaximumConnectionsPerHost = 128
                config.httpShouldUsePipelining = false

                if let proxy = self.proxyConfig {
                    if proxy.isSocks {
                        config.connectionProxyDictionary = [
                            kCFNetworkProxiesSOCKSEnable as String: 1,
                            kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                            kCFNetworkProxiesSOCKSPort as String: proxy.port
                        ]
                    } else {
                        config.connectionProxyDictionary = [
                            kCFNetworkProxiesHTTPEnable as String: 1,
                            kCFNetworkProxiesHTTPProxy as String: proxy.host,
                            kCFNetworkProxiesHTTPPort as String: proxy.port
                        ]
                    }
                }

                let opQueue = OperationQueue()
                opQueue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

                // Set Range header for partial content
                let rangeHeader = (self.endOffset >= Int64.max - 1000) ? "bytes=\(self.currentOffset)-" : "bytes=\(self.currentOffset)-\(self.endOffset)"
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")

                // Default standard Chrome user-agent if not provided
                if self.customHeaders["User-Agent"] == nil {
                    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                }

                for (key, value) in self.customHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let task = session.dataTask(with: request)
                stateLock.withLock {
                    self.session = session
                    self.dataTask = task
                }

                task.resume()
            }
        } onCancel: {
            gate.cancel()
            self.cancel()
        }
    }

    public func flushBuffer() throws {
        bufferLock.lock()
        guard !writeBuffer.isEmpty, writeBufferStartOffset >= 0 else {
            bufferLock.unlock()
            return
        }
        let dataToWrite = writeBuffer
        let offset = writeBufferStartOffset
        writeBuffer.removeAll(keepingCapacity: true)
        writeBufferStartOffset = currentOffset
        bufferLock.unlock()

        try storage.write(data: dataToWrite, atOffset: offset)
    }

    public func cancel() {
        let (task, sess, gate) = stateLock.withLock { () -> (URLSessionDataTask?, URLSession?, ContinuationGate?) in
            self.isCancelled = true
            let t = self.dataTask
            let s = self.session
            let g = self.activeGate
            self.dataTask = nil
            self.session = nil
            return (t, s, g)
        }

        task?.cancel()
        sess?.invalidateAndCancel()
        try? flushBuffer()

        gate?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let (gate, isMatch) = stateLock.withLock { (self.activeGate, self.session == nil || session === self.session) }
        guard let gate = gate, isMatch else {
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            gate.resume(throwing: SegmentError.networkError("Invalid non-HTTP response"))
            completionHandler(.cancel)
            return
        }

        // Detect expired links / token timeout
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 410 {
            let msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            gate.resume(throwing: SegmentError.linkExpired(statusCode: http.statusCode, message: msg))
            completionHandler(.cancel)
            return
        }

        // 206 Partial Content is expected. 200 OK means server ignored range header.
        if http.statusCode == 200 && currentOffset > 0 {
            gate.resume(throwing: SegmentError.serverDoesNotSupportRange)
            completionHandler(.cancel)
            return
        }

        if http.statusCode != 206 && http.statusCode != 200 {
            gate.resume(throwing: SegmentError.invalidResponse(statusCode: http.statusCode))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancelled = stateLock.withLock { self.isCancelled }
        guard !cancelled else { return }

        // Strictly prevent writing past endOffset if server ignores range or streams beyond boundary
        var writeData = data
        if endOffset < Int64.max - 1000 {
            let maxAllowed = max(0, endOffset - currentOffset + 1)
            if maxAllowed <= 0 {
                dataTask.cancel()
                return
            }
            if Int64(writeData.count) > maxAllowed {
                writeData = writeData.prefix(Int(maxAllowed))
            }
        }

        do {
            let count = Int64(writeData.count)
            var shouldFlushDirect = false
            var flushPayload: Data? = nil
            var flushOffset: Int64 = -1

            bufferLock.lock()
            if writeBuffer.isEmpty {
                writeBufferStartOffset = currentOffset
            }
            writeBuffer.append(writeData)
            currentOffset += count
            pendingBytesDelta += count

            if writeBuffer.count >= writeBufferThreshold {
                flushPayload = writeBuffer
                flushOffset = writeBufferStartOffset
                writeBuffer.removeAll(keepingCapacity: true)
                writeBufferStartOffset = currentOffset
                shouldFlushDirect = true
            }
            bufferLock.unlock()

            if shouldFlushDirect, let data = flushPayload, flushOffset >= 0 {
                try storage.write(data: data, atOffset: flushOffset)
            }

            let now = CFAbsoluteTimeGetCurrent()
            if (now - lastReportTime > 0.05) || pendingBytesDelta >= 256 * 1024 {
                let delta = pendingBytesDelta
                pendingBytesDelta = 0
                lastReportTime = now
                onProgress(segmentId, delta, currentOffset)
            }
        } catch {
            let gate = stateLock.withLock { self.activeGate }
            gate?.resume(throwing: error)
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? flushBuffer()

        if pendingBytesDelta > 0 {
            let delta = pendingBytesDelta
            pendingBytesDelta = 0
            onProgress(segmentId, delta, currentOffset)
        }

        let (gate, isMatch, cancelled) = stateLock.withLock {
            (self.activeGate, self.session == nil || session === self.session, self.isCancelled)
        }
        guard let gate = gate, isMatch else {
            return
        }

        if cancelled {
            gate.cancel()
            return
        }

        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                gate.cancel()
            } else {
                gate.resume(throwing: error)
            }
        } else {
            // Normal EOF from server
            // Check if this segment had a fixed endOffset that was NOT reached:
            if endOffset < Int64.max - 1000 && currentOffset <= endOffset {
                let missing = (endOffset + 1) - currentOffset
                gate.resume(throwing: SegmentError.networkError("Connection closed prematurely by server (\(missing) bytes remaining)"))
            } else if currentOffset <= 1 && endOffset >= Int64.max - 1000 {
                gate.resume(throwing: SegmentError.networkError("Connection closed before any data was received"))
            } else {
                gate.resume()
            }
        }
    }
}
