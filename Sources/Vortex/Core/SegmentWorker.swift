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
    private var continuation: CheckedContinuation<Void, Error>?

    private let onProgress: @Sendable (Int, Int64, Int64) -> Void // (segmentId, bytesDelta, newCurrentOffset)
    private var isCancelled = false

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
            if isCancelled { throw SegmentError.cancelled }
            do {
                try await downloadAttempt(url: url)
                return // Finished successfully
            } catch let err as SegmentError {
                // If link expired, do not retry blindly: throw immediately to trigger Link Renewal!
                if case .linkExpired = err {
                    throw err
                }
                attempt += 1
                if attempt >= maxRetries || isCancelled {
                    throw err
                }
                // Exponential backoff
                let backoff = Double(attempt) * 1.5
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                if isCancelled { throw SegmentError.cancelled }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30.0
            config.timeoutIntervalForResource = 3600.0
            config.httpMaximumConnectionsPerHost = 64
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
            self.session = session

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            // Set Range header for partial content
            let rangeHeader = (endOffset >= Int64.max - 1000) ? "bytes=\(currentOffset)-" : "bytes=\(currentOffset)-\(endOffset)"
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")

            // Default standard Chrome user-agent if not provided
            if customHeaders["User-Agent"] == nil {
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            }

            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let task = session.dataTask(with: request)
            self.dataTask = task
            task.resume()
        }
    }

    public func cancel() {
        isCancelled = true
        dataTask?.cancel()
        session?.invalidateAndCancel()
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: SegmentError.cancelled)
        }
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            continuation?.resume(throwing: SegmentError.networkError("Invalid non-HTTP response"))
            continuation = nil
            completionHandler(.cancel)
            return
        }

        // Detect expired links / token timeout
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 410 {
            let msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            continuation?.resume(throwing: SegmentError.linkExpired(statusCode: http.statusCode, message: msg))
            continuation = nil
            completionHandler(.cancel)
            return
        }

        // 206 Partial Content is expected. 200 OK means server ignored range header.
        if http.statusCode == 200 && currentOffset > 0 {
            continuation?.resume(throwing: SegmentError.serverDoesNotSupportRange)
            continuation = nil
            completionHandler(.cancel)
            return
        }

        if http.statusCode != 206 && http.statusCode != 200 {
            continuation?.resume(throwing: SegmentError.invalidResponse(statusCode: http.statusCode))
            continuation = nil
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled else { return }

        do {
            try storage.write(data: data, atOffset: currentOffset)
            let count = Int64(data.count)
            currentOffset += count
            onProgress(segmentId, count, currentOffset)
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let cont = continuation else { return }
        self.continuation = nil

        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                cont.resume(throwing: SegmentError.cancelled)
            } else {
                cont.resume(throwing: error)
            }
        } else {
            // Normal EOF from server
            // Check if this segment had a fixed endOffset that was NOT reached:
            if endOffset < Int64.max - 1000 && currentOffset <= endOffset {
                let missing = (endOffset + 1) - currentOffset
                cont.resume(throwing: SegmentError.networkError("Connection closed prematurely by server (\(missing) bytes remaining)"))
            } else if currentOffset <= 1 && endOffset >= Int64.max - 1000 {
                cont.resume(throwing: SegmentError.networkError("Connection closed before any data was received"))
            } else {
                cont.resume()
            }
        }
    }
}
