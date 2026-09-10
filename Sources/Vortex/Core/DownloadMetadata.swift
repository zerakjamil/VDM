import Foundation

public struct DownloadMetadata: Codable, Sendable {
    public let id: UUID
    public var url: String
    public var originalPageUrl: String?
    public var destinationPath: String
    public var fileName: String
    public var totalBytes: Int64
    public var supportsRange: Bool
    public var segments: [SegmentInfo]
    public var customHeaders: [String: String]
    public var dateAdded: Date
    public var status: DownloadStatus
    public var mirrorUrls: [String]?

    public init(
        id: UUID = UUID(),
        url: String,
        originalPageUrl: String? = nil,
        destinationPath: String,
        fileName: String,
        totalBytes: Int64,
        supportsRange: Bool,
        segments: [SegmentInfo] = [],
        customHeaders: [String: String] = [:],
        dateAdded: Date = Date(),
        status: DownloadStatus = .queued,
        mirrorUrls: [String]? = nil
    ) {
        self.id = id
        self.url = url
        self.originalPageUrl = originalPageUrl
        self.destinationPath = destinationPath
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.supportsRange = supportsRange
        self.segments = segments
        self.customHeaders = customHeaders
        self.dateAdded = dateAdded
        self.status = status
        self.mirrorUrls = mirrorUrls
    }

    public static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vortexDir = appSupport.appendingPathComponent("Vortex", isDirectory: true)
        try? FileManager.default.createDirectory(at: vortexDir, withIntermediateDirectories: true)
        return vortexDir
    }

    public var metaFileUrl: URL {
        return DownloadMetadata.appSupportDirectory.appendingPathComponent("\(id.uuidString).vortex_meta")
    }

    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)
            try data.write(to: metaFileUrl, options: .atomic)
        } catch {
            print("[Vortex] Error saving metadata: \(error)")
        }
    }

    public static func loadAll() -> [DownloadMetadata] {
        let dir = appSupportDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [DownloadMetadata] = []
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "vortex_meta" {
            if let data = try? Data(contentsOf: file),
               let meta = try? decoder.decode(DownloadMetadata.self, from: data) {
                results.append(meta)
            }
        }

        return results.sorted(by: { $0.dateAdded > $1.dateAdded })
    }

    public func delete() {
        try? FileManager.default.removeItem(at: metaFileUrl)
    }
}
