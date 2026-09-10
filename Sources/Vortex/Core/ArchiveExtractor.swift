import Foundation
import AppKit

@MainActor
public struct ArchiveGroup: Identifiable {
    public let id: String // base name without .partXX
    public let baseName: String
    public let destinationDirectory: URL
    public var parts: [DownloadTask]

    public var isComplete: Bool {
        return parts.allSatisfy { $0.isComplete }
    }
}

public final class ArchiveExtractor: @unchecked Sendable {
    public static let shared = ArchiveExtractor()

    private init() {}

    /// Checks if a filename is part of a multi-volume archive
    public func isMultiPartArchive(fileName: String) -> Bool {
        let pattern = #"(?i)\.(part\d+|\d{3})\.(rar|7z|zip)$|(?i)\.(rar|7z|zip)\.\d{3}$|(?i)\.r\d{2,}$"#
        return fileName.range(of: pattern, options: .regularExpression) != nil
    }

    /// Extracts the base group name (e.g. "Game.part01.rar" -> "Game")
    public func extractBaseGroupName(from fileName: String) -> String {
        var clean = fileName
        let patterns = [
            #"(?i)\.part\d+\.rar$"#,
            #"(?i)\.part\d+\.7z$"#,
            #"(?i)\.r\d{2,}$"#,
            #"(?i)\.7z\.\d{3}$"#,
            #"(?i)\.zip\.\d{3}$"#
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p) {
                clean = regex.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: clean.utf16.count), withTemplate: "")
            }
        }
        return clean
    }

    /// Extract an archive file to a destination directory
    public func extract(fileUrl: URL, to destinationDir: URL) async throws {
        let ext = fileUrl.pathExtension.lowercased()

        // 1. If standard zip
        if ext == "zip" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", fileUrl.path, "-d", destinationDir.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "ArchiveExtractor", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Unzip failed with code \(process.terminationStatus)"])
            }
            return
        }

        // 2. Check for 7z / 7zz / unrar in common paths
        let extractorPaths = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/unrar"]
        for p in extractorPaths {
            if FileManager.default.fileExists(atPath: p) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: p)
                process.arguments = ["x", "-y", "-o\(destinationDir.path)", fileUrl.path]
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return
                }
            }
        }

        // 3. Native macOS Archive Utility fallback via open command
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Archive Utility", fileUrl.path]
        try openProcess.run()
        openProcess.waitUntilExit()
    }

    /// Verify CRC32 checksum from an .sfv file if present
    public func verifySFV(in directory: URL) -> Bool? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        guard let sfvFile = files.first(where: { $0.pathExtension.lowercased() == "sfv" }) else { return nil }

        guard let sfvContent = try? String(contentsOf: sfvFile, encoding: .utf8) else { return nil }
        let lines = sfvContent.components(separatedBy: .newlines).filter { !$0.hasPrefix(";") && !$0.isEmpty }

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                let expectedFileName = String(parts[0])
                let expectedCrc = String(parts[1]).uppercased()
                let targetFile = directory.appendingPathComponent(expectedFileName)
                if FileManager.default.fileExists(atPath: targetFile.path) {
                    if let data = try? Data(contentsOf: targetFile) {
                        let actualCrc = String(format: "%08X", computeCRC32(data))
                        if actualCrc != expectedCrc {
                            return false
                        }
                    }
                }
            }
        }
        return true
    }

    private func computeCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = UInt32((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[Int(index)]
        }
        return crc ^ 0xFFFFFFFF
    }

    private lazy var crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}
