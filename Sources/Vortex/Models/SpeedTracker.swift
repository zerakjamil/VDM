import Foundation

public final class SpeedTracker: @unchecked Sendable {
    private struct Sample {
        let timestamp: Date
        let bytes: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let windowDuration: TimeInterval
    private var lastBytes: Int64 = 0

    public init(windowDuration: TimeInterval = 3.0) {
        self.windowDuration = windowDuration
    }

    public func record(downloadedBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        samples.append(Sample(timestamp: now, bytes: downloadedBytes))
        lastBytes = downloadedBytes

        // Purge old samples outside window
        let cutoff = now.addingTimeInterval(-windowDuration)
        samples.removeAll(where: { $0.timestamp < cutoff })
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        lastBytes = 0
    }

    public var currentSpeedBytesPerSec: Double {
        lock.lock()
        defer { lock.unlock() }

        guard samples.count >= 2 else { return 0.0 }
        guard let first = samples.first, let last = samples.last else { return 0.0 }

        let timeDiff = last.timestamp.timeIntervalSince(first.timestamp)
        guard timeDiff > 0.1 else { return 0.0 }

        let bytesDiff = last.bytes - first.bytes
        guard bytesDiff >= 0 else { return 0.0 }

        return Double(bytesDiff) / timeDiff
    }

    public func estimateRemainingTime(remainingBytes: Int64) -> TimeInterval? {
        let speed = currentSpeedBytesPerSec
        guard speed > 1024, remainingBytes > 0 else { return nil }
        return Double(remainingBytes) / speed
    }

    // Static formatters
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec <= 0 { return "0 B/s" }
        let formatted = formatBytes(Int64(bytesPerSec))
        return "\(formatted)/s"
    }

    public static func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let sec = seconds, sec.isFinite, sec > 0 else { return "--" }
        let intSec = Int(sec)
        let hours = intSec / 3600
        let minutes = (intSec % 3600) / 60
        let remainingSec = intSec % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, remainingSec)
        } else {
            return String(format: "%ds", remainingSec)
        }
    }
}
