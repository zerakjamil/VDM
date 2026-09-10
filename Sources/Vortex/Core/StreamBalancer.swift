import Foundation

public struct StreamMetrics: Sendable {
    public let segmentId: Int
    public let bytesPerSecond: Double
    public let lastProgressTime: Date
    public let remainingBytes: Int64
}

@MainActor
public final class StreamBalancer {
    private weak var task: DownloadTask?
    private var timer: Timer?
    private var previousOffsets: [Int: (offset: Int64, timestamp: Date)] = [:]
    private var stalledSeconds: [Int: Int] = [:]

    public init(task: DownloadTask) {
        self.task = task
    }

    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAndBalance()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        previousOffsets.removeAll()
        stalledSeconds.removeAll()
    }

    private func evaluateAndBalance() {
        guard let task = task, task.isDownloading, task.supportsRange else { return }

        let now = Date()
        let activeSegments = task.segments.filter { !$0.isFinished && $0.state == .active }
        guard activeSegments.count >= 2 else { return }

        var speeds: [Int: Double] = [:]
        for seg in activeSegments {
            if let prev = previousOffsets[seg.id] {
                let dt = now.timeIntervalSince(prev.timestamp)
                if dt > 0.5 {
                    let bytesDelta = max(0, seg.currentOffset - prev.offset)
                    let speed = Double(bytesDelta) / dt
                    speeds[seg.id] = speed
                }
            }
            previousOffsets[seg.id] = (seg.currentOffset, now)
        }

        guard !speeds.isEmpty else { return }
        let totalSpeed = speeds.values.reduce(0, +)
        let avgSpeed = totalSpeed / Double(speeds.count)

        // Detect choking: speed < 25% of average or stalled
        for seg in activeSegments {
            let speed = speeds[seg.id] ?? 0
            if speed < (avgSpeed * 0.25) && seg.remainingBytes > 10 * 1024 * 1024 {
                stalledSeconds[seg.id, default: 0] += 2
            } else {
                stalledSeconds[seg.id] = 0
            }

            // If choked for 4+ seconds and has significant bytes left, trigger dynamic boost/split
            if (stalledSeconds[seg.id] ?? 0) >= 4 {
                stalledSeconds[seg.id] = 0
                if task.segments.count < 32 {
                    task.boostStreams(targetCount: min(32, task.segments.count + 2))
                    break
                }
            }
        }
    }
}
