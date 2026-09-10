import Foundation
import SwiftUI

public enum DownloadStatus: Equatable, Codable, Sendable {
    case queued
    case connecting
    case downloading
    case reconnecting(retryIn: Int, attempt: Int)
    case paused
    case expired(reason: String)
    case completed
    case failed(error: String)

    public var title: String {
        switch self {
        case .queued: return "Queued"
        case .connecting: return "Connecting..."
        case .downloading: return "Downloading"
        case .reconnecting(let retryIn, let attempt):
            if retryIn > 0 {
                return "Reconnecting in \(retryIn)s (Attempt \(attempt))..."
            } else {
                return "Reconnecting (Attempt \(attempt))..."
            }
        case .paused: return "Paused"
        case .expired: return "Link Expired (Renewal Needed)"
        case .completed: return "Completed"
        case .failed(let err): return "Failed: \(err)"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .connecting, .downloading, .reconnecting: return true
        default: return false
        }
    }

    public var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }

    public var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }

    public var statusColor: Color {
        switch self {
        case .queued: return .gray
        case .connecting: return .orange
        case .downloading: return .cyan
        case .reconnecting: return .orange
        case .paused: return .yellow
        case .expired: return .red
        case .completed: return .green
        case .failed: return .red
        }
    }

    public var iconName: String {
        switch self {
        case .queued: return "clock"
        case .connecting: return "network"
        case .downloading: return "arrow.down.circle.fill"
        case .reconnecting: return "antenna.radiowaves.left.and.right"
        case .paused: return "pause.circle.fill"
        case .expired: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}
