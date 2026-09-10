import Foundation
import Combine

@MainActor
public final class QueueManager: ObservableObject {
    @Published public var maxConcurrentDownloads: Int = 2 {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads, forKey: "vortex_max_concurrent")
            processQueue()
        }
    }

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    public init(appState: AppState) {
        self.appState = appState
        let saved = UserDefaults.standard.integer(forKey: "vortex_max_concurrent")
        self.maxConcurrentDownloads = saved > 0 ? saved : 2
    }

    /// Process queue and launch next pending downloads if slots are available
    public func processQueue() {
        guard let appState = appState else { return }

        let activeCount = appState.tasks.filter { $0.isDownloading }.count
        let availableSlots = max(0, maxConcurrentDownloads - activeCount)

        guard availableSlots > 0 else { return }

        // Find queued tasks in order
        let queuedTasks = appState.tasks.filter { $0.status == .queued }
        let tasksToStart = queuedTasks.prefix(availableSlots)

        for task in tasksToStart {
            task.start()
        }
    }

    /// Called when any task status transitions (e.g. to .completed, .paused, or .failed)
    public func onTaskStatusChanged(task: DownloadTask) {
        if !task.isDownloading {
            processQueue()
        }
    }
}
