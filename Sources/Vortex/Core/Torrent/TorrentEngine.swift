import Foundation
import Combine

@MainActor
public final class TorrentEngine: ObservableObject {
    public static let shared = TorrentEngine()

    private var activeProcesses: [UUID: Process] = [:]
    private var processPipes: [UUID: Pipe] = [:]

    public static var aria2Path: String? {
        var candidates: [String] = []
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("aria2c").path)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aria2c").path)
        candidates.append("/opt/homebrew/bin/aria2c")
        candidates.append("/usr/local/bin/aria2c")
        candidates.append("/usr/bin/aria2c")
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public static let defaultTrackers: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.therarbg.to:6969/announce",
        "udp://tracker.publictracker.xyz:6969/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker.peerfect.org:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://p4p.arenabg.com:1337/announce",
        "udp://tracker.filemail.com:6969/announce",
        "udp://tracker.dump.cl:6969/announce",
        "udp://retracker.lanta-net.ru:2710/announce",
        "udp://leet-tracker.moe:1337/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "https://tracker.tamersunion.org:443/announce",
        "http://tracker.renfei.net:8080/announce"
    ]

    public private(set) var liveTrackers: [String] = TorrentEngine.defaultTrackers

    private init() {
        refreshLiveTrackers()
    }

    public func refreshLiveTrackers() {
        guard let url = URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt") else { return }
        Task.detached(priority: .background) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.starts(with: "udp://") || $0.starts(with: "http://") || $0.starts(with: "https://") }
                if !lines.isEmpty {
                    await MainActor.run {
                        TorrentEngine.shared.liveTrackers = Array(Set(TorrentEngine.defaultTrackers + lines))
                    }
                }
            } catch {
                // Silently fallback to built-in verified defaultTrackers
            }
        }
    }

    public func startTorrent(
        task: DownloadTask,
        magnetUri: String,
        destinationDirectory: URL
    ) {
        guard let aria2 = Self.aria2Path else {
            task.status = .failed(error: "aria2c engine not found. Please install aria2 via 'brew install aria2'.")
            return
        }

        cancel(taskId: task.id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: aria2)

        var args: [String] = [
            "--dir=\(destinationDirectory.path)",
            "--seed-time=0",
            "--summary-interval=1",
            "--max-connection-per-server=16",
            "--split=16",
            "--bt-max-peers=128",
            "--bt-request-peer-speed-limit=100M",
            "--dht-entry-point=router.bittorrent.com:6881",
            "--dht-entry-point=dht.transmissionbt.com:6881",
            "--dht-entry-point=router.utorrent.com:6881",
            "--bt-tracker-connect-timeout=4",
            "--bt-tracker-timeout=4",
            "--enable-dht=true",
            "--enable-dht6=true",
            "--enable-peer-exchange=true",
            "--bt-enable-lpd=true",
            "--bt-stop-timeout=300",
            "--file-allocation=none"
        ]

        let autoInject = UserDefaults.standard.object(forKey: "vortex_auto_inject_trackers") as? Bool ?? true
        if autoInject {
            let activeTrackers = liveTrackers.isEmpty ? Self.defaultTrackers : liveTrackers
            args.append("--bt-tracker=" + activeTrackers.joined(separator: ","))
        }

        args.append(magnetUri)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        activeProcesses[task.id] = process
        processPipes[task.id] = outPipe
        task.status = .connecting

        SleepPreventer.shared.retainSleepAssertion(reason: "Vortex torrenting \(task.fileName)")

        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor in
                self?.parseOutput(text, task: task)
            }
        }

        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor in
                self?.parseOutput(text, task: task)
            }
        }

        process.terminationHandler = { [weak self, weak task] proc in
            Task { @MainActor in
                self?.activeProcesses.removeValue(forKey: task?.id ?? UUID())
                self?.processPipes.removeValue(forKey: task?.id ?? UUID())

                if proc.terminationStatus == 0 {
                    task?.downloadedBytes = task?.totalBytes ?? task?.downloadedBytes ?? 0
                    task?.progress = 1.0
                    task?.status = .completed
                    task?.cleanupAfterStop()

                    if let t = task {
                        let fileUrl = URL(fileURLWithPath: t.destinationPath)
                        if UserDefaults.standard.bool(forKey: "vortex_auto_extract") {
                            Task {
                                try? await ArchiveExtractor.shared.extract(fileUrl: fileUrl, to: fileUrl.deletingLastPathComponent())
                            }
                        }
                    }
                } else if task?.status == .downloading || task?.status == .connecting {
                    task?.status = .paused
                    task?.cleanupAfterStop()
                }
            }
        }

        do {
            try process.run()
        } catch {
            task.status = .failed(error: "Failed to launch torrent engine: \(error.localizedDescription)")
            task.cleanupAfterStop()
        }
    }

    public func pause(task: DownloadTask) {
        if let proc = activeProcesses[task.id] {
            proc.terminate()
            activeProcesses.removeValue(forKey: task.id)
            processPipes.removeValue(forKey: task.id)
        }
        task.status = .paused
        task.cleanupAfterStop()
    }

    public func cancel(taskId: UUID) {
        if let proc = activeProcesses[taskId] {
            proc.terminate()
            activeProcesses.removeValue(forKey: taskId)
            processPipes.removeValue(forKey: taskId)
        }
    }

    /// Parses aria2 progress output
    private func parseOutput(_ text: String, task: DownloadTask?) {
        guard let task = task else { return }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            // Real completion: must not be metadata completion
            if (line.contains("(OK):download completed.") || line.contains("download completed")) && !line.contains("[METADATA]") {
                task.status = .completed
                return
            }

            // Detect actual filename if reported by aria2:
            // FILE: /path/to/LA.Streets.of.Sorcery.rar
            if line.contains("FILE:") {
                let parts = line.components(separatedBy: "FILE:")
                if parts.count >= 2 {
                    let fn = parts[1].trimmingCharacters(in: .whitespaces)
                    let clean = (fn as NSString).lastPathComponent
                    if !clean.isEmpty && !clean.contains("[METADATA]") {
                        task.fileName = clean
                        task.destinationPath = URL(fileURLWithPath: task.destinationPath)
                            .deletingLastPathComponent()
                            .appendingPathComponent(clean)
                            .path
                    }
                }
            }

            // Handle metadata fetching phase
            if line.contains("[METADATA]") {
                if task.status != .connecting {
                    task.status = .connecting
                }
            }

            // Regex for progress line:
            // [#e49689 120MiB/4.3GiB(2%) CN:16 SD:4 DL:11.5MiB/s ETA:5m]
            let pattern = #"(?i)\[#([a-f0-9]+)\s+([0-9.]+[A-Za-z]+)\/([0-9.]+[A-Za-z]+)\((\d+)%\)\s+(?:CN:(\d+))?\s*(?:SD:\d+)?\s*(?:DL:([0-9.]+[A-Za-z]+(?:\/s)?))?\s*(?:ETA:([0-9a-z]+))?\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: line.utf16.count))
            if let match = matches.first {
                let downloadedStr = match.range(at: 2).location != NSNotFound ? nsLine.substring(with: match.range(at: 2)) : ""
                let totalStr = match.range(at: 3).location != NSNotFound ? nsLine.substring(with: match.range(at: 3)) : ""
                let pctStr = match.range(at: 4).location != NSNotFound ? nsLine.substring(with: match.range(at: 4)) : ""
                let cnStr = match.range(at: 5).location != NSNotFound ? nsLine.substring(with: match.range(at: 5)) : ""
                let speedStr = match.range(at: 6).location != NSNotFound ? nsLine.substring(with: match.range(at: 6)) : ""

                // Only transition to downloading when real data is flowing or file allocated
                if !totalStr.isEmpty && totalStr != "0B" && !line.contains("[METADATA]") {
                    if task.status != .downloading {
                        task.status = .downloading
                    }
                }

                if let pct = Double(pctStr) {
                    task.progress = pct / 100.0
                }

                let downBytes = parseBytes(downloadedStr)
                let totalBytes = parseBytes(totalStr)
                if totalBytes > 0 {
                    task.totalBytes = totalBytes
                }
                if downBytes > 0 {
                    task.downloadedBytes = downBytes
                }

                if !speedStr.isEmpty {
                    task.currentSpeed = parseSpeed(speedStr)
                }

                // Synthesize chunk segments for the visualizer
                let connCount = max(4, min(32, Int(cnStr) ?? 16))
                if task.segments.count != connCount {
                    task.segments = (0..<connCount).map { i in
                        SegmentInfo(
                            id: i,
                            startOffset: Int64(i) * 1000,
                            currentOffset: Int64(i) * 1000,
                            endOffset: Int64(i + 1) * 1000,
                            state: .pending
                        )
                    }
                }

                let filledSegments = Int(Double(connCount) * task.progress)
                for i in 0..<connCount {
                    if i < filledSegments {
                        task.segments[i].state = .completed
                        task.segments[i].currentOffset = task.segments[i].endOffset
                    } else if i == filledSegments {
                        task.segments[i].state = .active
                    } else {
                        task.segments[i].state = .pending
                    }
                }
            }
        }
    }

    private func parseBytes(_ str: String) -> Int64 {
        let upper = str.uppercased()
        let numStr = upper.filter { "0123456789.".contains($0) }
        guard let num = Double(numStr) else { return 0 }

        if upper.contains("GIB") || upper.contains("GB") {
            return Int64(num * 1024 * 1024 * 1024)
        } else if upper.contains("MIB") || upper.contains("MB") {
            return Int64(num * 1024 * 1024)
        } else if upper.contains("KIB") || upper.contains("KB") {
            return Int64(num * 1024)
        } else {
            return Int64(num)
        }
    }

    private func parseSpeed(_ str: String) -> Double {
        let upper = str.uppercased().replacingOccurrences(of: "/S", with: "")
        let numStr = upper.filter { "0123456789.".contains($0) }
        guard let num = Double(numStr) else { return 0 }

        if upper.contains("GIB") || upper.contains("GB") {
            return num * 1024 * 1024 * 1024
        } else if upper.contains("MIB") || upper.contains("MB") {
            return num * 1024 * 1024
        } else if upper.contains("KIB") || upper.contains("KB") {
            return num * 1024
        } else {
            return num
        }
    }
}
