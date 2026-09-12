import Foundation
import Darwin

public final class FileStorage: @unchecked Sendable {
    public let filePath: String
    private var fileDescriptor: Int32 = -1
    private let lock = NSLock()

    public init(filePath: String) {
        self.filePath = filePath
    }

    deinit {
        close()
    }

    /// Pre-allocate or open file for concurrent direct writes
    public func prepareFile(totalSize: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }

        // Create parent directory if needed
        let parentDir = (filePath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        isDir = false
        if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
            throw NSError(domain: "FileStorageError", code: Int(EISDIR), userInfo: [NSLocalizedDescriptionKey: "Failed to open file: '\(filePath)' is a directory, not a file!"])
        }

        // Open with read/write and create if not exists
        let fd = Darwin.open(filePath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            throw NSError(domain: "FileStorageError", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open file: \(err)"])
        }

        self.fileDescriptor = fd

        // Check destination filesystem
        var fsStat = statfs()
        var isApfs = true
        var isFat32 = false

        if statfs(parentDir, &fsStat) == 0 {
            let typeName = withUnsafePointer(to: &fsStat.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0).lowercased()
                }
            }
            isApfs = (typeName == "apfs")
            isFat32 = (typeName == "msdos")
        }

        if isFat32 && totalSize >= 4_294_967_296 {
            Darwin.close(fd)
            self.fileDescriptor = -1
            throw NSError(
                domain: "FileStorageError",
                code: Int(EFBIG),
                userInfo: [NSLocalizedDescriptionKey: "Destination volume is formatted as FAT32, which does not support files 4GB or larger (\(totalSize) bytes). Please use an APFS or exFAT volume."]
            )
        }

        // Pre-allocate space safely based on filesystem capabilities
        if totalSize > 0 {
            var statBuf = stat()
            if fstat(fd, &statBuf) == 0 {
                if statBuf.st_size < off_t(totalSize) {
                    if isApfs {
                        // ftruncate creates sparse / preallocated size instantly on APFS
                        _ = ftruncate(fd, off_t(totalSize))
                    } else if totalSize <= 50 * 1024 * 1024 {
                        // On non-APFS (exFAT, FAT32, SMB), ftruncate causes synchronous full-disk zero-fill
                        // which hangs the application for 10-30 minutes on large 10-25GB files.
                        // Only truncate small files <= 50MB; for larger files, let pwrite expand dynamically.
                        _ = ftruncate(fd, off_t(totalSize))
                    }
                }
            }
        }
    }

    /// Direct write at specific byte offset using POSIX pwrite (thread-safe without seeking)
    public func write(data: Data, atOffset offset: Int64) throws {
        lock.lock()
        let fd = self.fileDescriptor
        lock.unlock()

        guard fd >= 0 else {
            throw NSError(domain: "FileStorageError", code: -1, userInfo: [NSLocalizedDescriptionKey: "File is not open for writing"])
        }

        var bytesWritten = 0
        let count = data.count

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            while bytesWritten < count {
                let chunkPtr = baseAddress.advanced(by: bytesWritten)
                let chunkLen = count - bytesWritten
                let currentOffset = off_t(offset + Int64(bytesWritten))

                let written = Darwin.pwrite(fd, chunkPtr, chunkLen, currentOffset)
                if written < 0 {
                    let err = String(cString: strerror(errno))
                    throw NSError(domain: "FileStorageError", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "pwrite failed at offset \(currentOffset): \(err)"])
                } else if written == 0 {
                    break
                }
                bytesWritten += written
            }
        }
    }

    public func flush() {
        lock.lock()
        let fd = self.fileDescriptor
        lock.unlock()

        if fd >= 0 {
            fsync(fd)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }

        if fileDescriptor >= 0 {
            fsync(fileDescriptor)
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// Verifies physical allocation and completeness on disk.
    /// Returns true only if the file is physically allocated to match expectedTotalBytes (no sparse holes).
    public func verifyCompleteness(expectedTotalBytes: Int64) -> (complete: Bool, allocatedBytes: Int64) {
        guard expectedTotalBytes > 0 else { return (true, 0) }

        var statBuf = stat()
        let res: Int32
        lock.lock()
        if fileDescriptor >= 0 {
            res = fstat(fileDescriptor, &statBuf)
        } else {
            res = stat(filePath, &statBuf)
        }
        lock.unlock()

        guard res == 0 else {
            return (false, 0)
        }

        if statBuf.st_size < off_t(expectedTotalBytes) {
            return (false, Int64(statBuf.st_blocks) * 512)
        }

        let allocated = Int64(statBuf.st_blocks) * 512
        let threshold = max(0, expectedTotalBytes - 65536)
        return (allocated >= threshold, allocated)
    }

    public static func verifyFileCompleteness(filePath: String, expectedTotalBytes: Int64) -> (complete: Bool, allocatedBytes: Int64) {
        guard expectedTotalBytes > 0 else { return (true, 0) }
        var statBuf = stat()
        guard stat(filePath, &statBuf) == 0 else { return (false, 0) }
        if statBuf.st_size < off_t(expectedTotalBytes) {
            return (false, Int64(statBuf.st_blocks) * 512)
        }
        let allocated = Int64(statBuf.st_blocks) * 512
        let threshold = max(0, expectedTotalBytes - 65536)
        return (allocated >= threshold, allocated)
    }
}
