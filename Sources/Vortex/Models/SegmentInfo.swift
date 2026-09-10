import Foundation

public enum SegmentState: String, Codable, Sendable {
    case pending
    case active
    case completed
    case failed
}

public struct SegmentInfo: Identifiable, Codable, Sendable {
    public let id: Int
    public let startOffset: Int64
    public var currentOffset: Int64
    public let endOffset: Int64 // inclusive
    public var state: SegmentState

    public init(id: Int, startOffset: Int64, currentOffset: Int64? = nil, endOffset: Int64, state: SegmentState = .pending) {
        self.id = id
        self.startOffset = startOffset
        self.currentOffset = currentOffset ?? startOffset
        self.endOffset = endOffset
        self.state = state
    }

    public var bytesDownloaded: Int64 {
        max(0, min(endOffset - startOffset + 1, currentOffset - startOffset))
    }

    public var totalBytes: Int64 {
        max(1, endOffset - startOffset + 1)
    }

    public var remainingBytes: Int64 {
        max(0, endOffset - currentOffset + 1)
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(bytesDownloaded) / Double(totalBytes)))
    }

    public var isFinished: Bool {
        if endOffset >= Int64.max - 1000 {
            return state == .completed
        }
        return currentOffset > endOffset
    }
}
