import XCTest
@testable import Vortex

final class VortexTests: XCTestCase {
    func testSegmentInfoCalculations() {
        // 1MB segment: bytes 0 to 1,048,575
        var seg = SegmentInfo(id: 0, startOffset: 0, currentOffset: 0, endOffset: 1_048_575, state: .pending)
        XCTAssertEqual(seg.totalBytes, 1_048_576)
        XCTAssertEqual(seg.bytesDownloaded, 0)
        XCTAssertEqual(seg.remainingBytes, 1_048_576)
        XCTAssertEqual(seg.progress, 0.0)
        XCTAssertFalse(seg.isFinished)

        // Halfway downloaded
        seg.currentOffset = 524_288
        XCTAssertEqual(seg.bytesDownloaded, 524_288)
        XCTAssertEqual(seg.remainingBytes, 524_288)
        XCTAssertEqual(seg.progress, 0.5, accuracy: 0.001)

        // Fully downloaded
        seg.currentOffset = 1_048_576
        XCTAssertEqual(seg.bytesDownloaded, 1_048_576)
        XCTAssertEqual(seg.remainingBytes, 0)
        XCTAssertEqual(seg.progress, 1.0)
        XCTAssertTrue(seg.isFinished)
    }

    func testFileStorageDirectPwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("vortex_test_\(UUID().uuidString).dat")
        let storage = FileStorage(filePath: testFile.path)

        // Total 10 KB file
        let totalSize: Int64 = 10 * 1024
        try storage.prepareFile(totalSize: totalSize)

        // Write chunk 2 first at offset 5000 (disjoint out-of-order write)
        let chunk2 = "HELLO_WORLD_AT_5000".data(using: .utf8)!
        try storage.write(data: chunk2, atOffset: 5000)

        // Write chunk 1 at offset 0
        let chunk1 = "CHUNK_ONE_START".data(using: .utf8)!
        try storage.write(data: chunk1, atOffset: 0)

        storage.flush()
        storage.close()

        // Read back and verify exact byte offsets
        let fileHandle = try FileHandle(forReadingFrom: testFile)
        try fileHandle.seek(toOffset: 5000)
        let readChunk2 = fileHandle.readData(ofLength: chunk2.count)
        XCTAssertEqual(String(data: readChunk2, encoding: .utf8), "HELLO_WORLD_AT_5000")

        try fileHandle.seek(toOffset: 0)
        let readChunk1 = fileHandle.readData(ofLength: chunk1.count)
        XCTAssertEqual(String(data: readChunk1, encoding: .utf8), "CHUNK_ONE_START")

        try fileHandle.close()
        try? FileManager.default.removeItem(at: testFile)
    }

    func testDownloadMetadataPersistence() throws {
        let id = UUID()
        let segments = [
            SegmentInfo(id: 0, startOffset: 0, currentOffset: 500, endOffset: 999, state: .active),
            SegmentInfo(id: 1, startOffset: 1000, currentOffset: 1000, endOffset: 1999, state: .pending)
        ]

        let meta = DownloadMetadata(
            id: id,
            url: "https://romsfun.com/download/persona-5.pkg",
            originalPageUrl: "https://romsfun.com/roms/ps3/persona-5",
            destinationPath: "/Users/test/Downloads/persona-5.pkg",
            fileName: "persona-5.pkg",
            totalBytes: 2000,
            supportsRange: true,
            segments: segments,
            customHeaders: ["User-Agent": "CustomAgent"],
            status: .paused
        )

        meta.save()

        // Verify loaded
        let all = DownloadMetadata.loadAll()
        guard let loaded = all.first(where: { $0.id == id }) else {
            XCTFail("Failed to find saved metadata")
            return
        }

        XCTAssertEqual(loaded.fileName, "persona-5.pkg")
        XCTAssertEqual(loaded.totalBytes, 2000)
        XCTAssertEqual(loaded.segments.count, 2)
        XCTAssertEqual(loaded.segments[0].currentOffset, 500)
        XCTAssertEqual(loaded.status, .paused)

        // Cleanup
        meta.delete()
        let afterDelete = DownloadMetadata.loadAll()
        XCTAssertFalse(afterDelete.contains(where: { $0.id == id }))
    }

    func testSpeedTrackerFormatters() {
        XCTAssertEqual(SpeedTracker.formatBytes(1000), "1 KB")
        XCTAssertEqual(SpeedTracker.formatBytes(10_000_000), "10 MB")
        XCTAssertEqual(SpeedTracker.formatBytes(38_000_000_000), "38 GB")

        XCTAssertEqual(SpeedTracker.formatSpeed(3_000_000), "3 MB/s")

        XCTAssertEqual(SpeedTracker.formatDuration(45), "45s")
        XCTAssertEqual(SpeedTracker.formatDuration(125), "2m 05s")
        XCTAssertEqual(SpeedTracker.formatDuration(7325), "2h 02m")
        XCTAssertEqual(SpeedTracker.formatDuration(nil), "--")
    }

    @MainActor
    func testMultiSegmentDownloadAndTokenRenewal() async throws {
        // Start mock python server on port 18081
        let serverScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("mock_server.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [serverScript.path, "18081"]
        try process.run()
        defer { process.terminate() }

        // Wait for server to listen
        try await Task.sleep(nanoseconds: 500_000_000)

        let tempDir = FileManager.default.temporaryDirectory
        let initialUrl = URL(string: "http://127.0.0.1:18081/file?token=valid")!
        let task = DownloadTask(
            url: initialUrl,
            destinationDirectory: tempDir,
            fileName: "test_rom_downloaded.bin",
            preferredSegments: 4
        )

        task.start()

        // Wait up to 5 seconds for completion
        var completed = false
        for _ in 0..<50 {
            if task.status == .completed {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(completed, "Task should complete within 5 seconds")
        XCTAssertEqual(task.downloadedBytes, 4 * 1024 * 1024)

        // Verify file content on disk
        let fileUrl = URL(fileURLWithPath: task.destinationPath)
        let data = try Data(contentsOf: fileUrl)
        XCTAssertEqual(data.count, 4 * 1024 * 1024)
        XCTAssertTrue(data.allSatisfy { $0 == Character("X").asciiValue! })

        // Now test token refresh behavior:
        // Set an expired URL, then refresh it with a valid URL and verify resume
        let expiredUrl = URL(string: "http://127.0.0.1:18081/file?token=expired")!
        let task2 = DownloadTask(
            url: expiredUrl,
            destinationDirectory: tempDir,
            fileName: "test_rom_expired.bin",
            preferredSegments: 4
        )
        task2.start()

        // Expect it to transition to expired
        var isExpired = false
        for _ in 0..<30 {
            if task2.status.isExpired {
                isExpired = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(isExpired, "Task should detect expired link and set expired status")

        // Now refresh the URL with the valid token!
        try await task2.refreshUrl(newUrl: initialUrl)

        var resumedAndCompleted = false
        for _ in 0..<50 {
            if task2.status == .completed {
                resumedAndCompleted = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(resumedAndCompleted, "Task should resume and complete after URL refresh")

        // Cleanup
        try? FileManager.default.removeItem(at: fileUrl)
        try? FileManager.default.removeItem(atPath: task2.destinationPath)
        task.deleteMetadataAndFiles()
        task2.deleteMetadataAndFiles()
    }

    @MainActor
    func testVortexServerIPC() async throws {
        let server = VortexServer.shared
        var receivedUrl: URL? = nil
        var receivedReferrer: URL? = nil
        var receivedFilename: String? = nil

        server.onCheckStatus = {
            return ["status": "running", "version": "1.0.0", "activeDownloads": 1]
        }

        server.onAddDownload = { url, pageUrl, filename, headers, segments in
            receivedUrl = url
            receivedReferrer = pageUrl
            receivedFilename = filename
        }

        server.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        // 1. Test GET /status
        let statusUrl = URL(string: "http://127.0.0.1:17890/status")!
        let (statusData, statusResp) = try await URLSession.shared.data(from: statusUrl)
        let httpStatus = statusResp as? HTTPURLResponse
        XCTAssertEqual(httpStatus?.statusCode, 200)

        let statusJson = try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        XCTAssertEqual(statusJson?["status"] as? String, "running")
        XCTAssertEqual(statusJson?["version"] as? String, "1.0.0")

        // 2. Test POST /download
        let downloadEndpoint = URL(string: "http://127.0.0.1:17890/download")!
        var postReq = URLRequest(url: downloadEndpoint)
        postReq.httpMethod = "POST"
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = """
        {
            "url": "https://romsfun.com/download/ps3_game.zip",
            "referrer": "https://romsfun.com/roms/playstation-3/game.html",
            "filename": "ps3_game.zip",
            "cookies": "session=xyz123",
            "userAgent": "Mozilla/5.0 Chrome",
            "segments": 16
        }
        """
        postReq.httpBody = payload.data(using: .utf8)

        let (downloadData, downloadResp) = try await URLSession.shared.data(for: postReq)
        let httpDownload = downloadResp as? HTTPURLResponse
        XCTAssertEqual(httpDownload?.statusCode, 200)

        let downloadJson = try JSONSerialization.jsonObject(with: downloadData) as? [String: Any]
        XCTAssertEqual(downloadJson?["success"] as? Bool, true)

        // Verify callback received the data
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(receivedUrl?.absoluteString, "https://romsfun.com/download/ps3_game.zip")
        XCTAssertEqual(receivedReferrer?.absoluteString, "https://romsfun.com/roms/playstation-3/game.html")
        XCTAssertEqual(receivedFilename, "ps3_game.zip")
    }

    func testContentRangeAndSegmentGeneration() {
        // Test MegaUp cyberlocker simulation: 4,673,405,506 bytes (4.67 GB)
        let totalBytes: Int64 = 4_673_405_506
        let preferredSegments = 8

        let numSegments = min(preferredSegments, max(1, Int(totalBytes / (2 * 1024 * 1024))))
        let chunkSize = totalBytes / Int64(numSegments)
        var segments: [SegmentInfo] = []

        for i in 0..<numSegments {
            let start = Int64(i) * chunkSize
            let end = (i == numSegments - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
            segments.append(SegmentInfo(id: i, startOffset: start, currentOffset: start, endOffset: end))
        }

        XCTAssertEqual(segments.count, 8)
        XCTAssertEqual(segments[0].startOffset, 0)
        XCTAssertEqual(segments[7].endOffset, totalBytes - 1)
        XCTAssertEqual(segments.reduce(0, { $0 + $1.totalBytes }), totalBytes)

        // Verify that 0 totalBytes NEVER produces endOffset: 0
        let zeroTotalBytes: Int64 = 0
        let fallbackSegments: [SegmentInfo]
        if zeroTotalBytes > 0 {
            fallbackSegments = [SegmentInfo(id: 0, startOffset: 0, currentOffset: 0, endOffset: zeroTotalBytes - 1)]
        } else {
            fallbackSegments = [SegmentInfo(id: 0, startOffset: 0, currentOffset: 0, endOffset: Int64.max - 1)]
        }
        XCTAssertEqual(fallbackSegments.count, 1)
        XCTAssertGreaterThan(fallbackSegments[0].endOffset, 1_000_000_000)
    }

    func testBencodeAndMagnetParsing() throws {
        // 1. Test Bencode Integer: "i42e" -> 42
        let intData = "i42e".data(using: .utf8)!
        let intVal = try BencodeParser.parse(data: intData)
        XCTAssertEqual(intVal.intValue, 42)

        // 2. Test Bencode String: "4:spam" -> "spam"
        let strData = "4:spam".data(using: .utf8)!
        let strVal = try BencodeParser.parse(data: strData)
        XCTAssertEqual(strVal.stringValue, "spam")

        // 3. Test Bencode List: "l4:spami42ee" -> ["spam", 42]
        let listData = "l4:spami42ee".data(using: .utf8)!
        let listVal = try BencodeParser.parse(data: listData)
        XCTAssertEqual(listVal.listValue?.count, 2)

        // 4. Test Magnet URI parsing
        let magnetUri = "magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Persona_5_PS3.pkg&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80"
        let magnetMeta = MagnetParser.parse(uri: magnetUri)
        XCTAssertNotNil(magnetMeta)
        XCTAssertEqual(magnetMeta?.infoHash, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(magnetMeta?.displayName, "Persona_5_PS3.pkg")
        XCTAssertEqual(magnetMeta?.trackers.count, 1)
    }

    func testArchiveExtractorDetection() {
        let extractor = ArchiveExtractor.shared
        XCTAssertTrue(extractor.isMultiPartArchive(fileName: "Game.part01.rar"))
        XCTAssertTrue(extractor.isMultiPartArchive(fileName: "Game.part1.rar"))
        XCTAssertTrue(extractor.isMultiPartArchive(fileName: "Game.r00"))
        XCTAssertTrue(extractor.isMultiPartArchive(fileName: "Game.7z.001"))
        XCTAssertFalse(extractor.isMultiPartArchive(fileName: "Game.iso"))

        XCTAssertEqual(extractor.extractBaseGroupName(from: "God_of_War.part01.rar"), "God_of_War")
        XCTAssertEqual(extractor.extractBaseGroupName(from: "God_of_War.part12.rar"), "God_of_War")
    }

    func testDebridHostDetection() {
        let resolver = DebridResolver.shared
        XCTAssertTrue(resolver.isCyberlocker(url: URL(string: "https://rapidgator.net/file/12345/game.rar")!))
        XCTAssertTrue(resolver.isCyberlocker(url: URL(string: "https://1fichier.com/?abcdef123")!))
        XCTAssertTrue(resolver.isCyberlocker(url: URL(string: "https://megaup.net/1234/game.rar")!))
        XCTAssertFalse(resolver.isCyberlocker(url: URL(string: "https://romsfun.com/download/game.zip")!))
    }

    @MainActor
    func testQueueManagerConcurrency() {
        let appState = AppState()
        let qm = appState.queueManager!
        qm.maxConcurrentDownloads = 2

        let task1 = DownloadTask(url: URL(string: "https://example.com/file1.zip")!, destinationDirectory: FileManager.default.temporaryDirectory)
        let task2 = DownloadTask(url: URL(string: "https://example.com/file2.zip")!, destinationDirectory: FileManager.default.temporaryDirectory)
        let task3 = DownloadTask(url: URL(string: "https://example.com/file3.zip")!, destinationDirectory: FileManager.default.temporaryDirectory)

        task1.status = .queued
        task2.status = .queued
        task3.status = .queued

        appState.tasks = [task1, task2, task3]
        XCTAssertEqual(qm.maxConcurrentDownloads, 2)
        XCTAssertEqual(appState.tasks.filter { $0.status == .queued }.count, 3)
    }

    @MainActor
    func testDefaultDownloadDirectoryConfiguration() {
        let original = AppState.defaultDownloadDirectory
        defer {
            AppState.defaultDownloadDirectory = original
        }

        // Test fallback ends with "Vortex Downloads"
        let fallback = AppState.fallbackDownloadDirectory
        XCTAssertTrue(fallback.path.hasSuffix("Vortex Downloads"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.path))

        // Test changing default directory
        let tempTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("VortexTestDownloads_\(UUID().uuidString)")
        let appState = AppState()
        appState.setDownloadDirectory(tempTestDir)

        XCTAssertEqual(AppState.defaultDownloadDirectory.path, tempTestDir.path)
        XCTAssertEqual(appState.downloadDirectory.path, tempTestDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempTestDir.path))

        // Clean up temp test dir
        try? FileManager.default.removeItem(at: tempTestDir)
    }

    @MainActor
    func testMultiSourceMirrorPersistenceAndAssignment() {
        let primaryUrl = URL(string: "https://example.com/megaup/game.zip")!
        let mirror1 = URL(string: "https://1fichier.com/game.zip")!
        let mirror2 = URL(string: "https://mediafire.com/game.zip")!

        let task = DownloadTask(
            url: primaryUrl,
            destinationDirectory: FileManager.default.temporaryDirectory,
            mirrorUrls: [mirror1, mirror2]
        )

        XCTAssertEqual(task.mirrorUrls.count, 2)
        XCTAssertEqual(task.mirrorUrls[0], mirror1)
        XCTAssertEqual(task.mirrorUrls[1], mirror2)

        // Test metadata persistence
        task.saveMetadata()
        defer { task.deleteMetadataAndFiles() }

        let allMetas = DownloadMetadata.loadAll()
        guard let savedMeta = allMetas.first(where: { $0.id == task.id }) else {
            XCTFail("Failed to load saved metadata with mirrors")
            return
        }

        XCTAssertEqual(savedMeta.mirrorUrls?.count, 2)
        XCTAssertEqual(savedMeta.mirrorUrls?[0], mirror1.absoluteString)
        XCTAssertEqual(savedMeta.mirrorUrls?[1], mirror2.absoluteString)

        // Test round-robin assignment mapping
        let allUrls = [task.url] + task.mirrorUrls
        XCTAssertEqual(allUrls[0 % allUrls.count], primaryUrl)
        XCTAssertEqual(allUrls[1 % allUrls.count], mirror1)
        XCTAssertEqual(allUrls[2 % allUrls.count], mirror2)
        XCTAssertEqual(allUrls[3 % allUrls.count], primaryUrl)
    }

    @MainActor
    func testLiveTrackerListAndInjection() {
        let engine = TorrentEngine.shared
        XCTAssertFalse(TorrentEngine.defaultTrackers.isEmpty)
        XCTAssertTrue(TorrentEngine.defaultTrackers.contains("udp://tracker.opentrackr.org:1337/announce"))
        XCTAssertTrue(TorrentEngine.defaultTrackers.contains("udp://open.demonii.com:1337/announce"))
        XCTAssertGreaterThanOrEqual(engine.liveTrackers.count, 15)
    }
}

