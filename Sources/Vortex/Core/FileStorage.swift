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
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
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

        // Pre-allocate space on APFS / macOS
        if totalSize > 0 {
            // ftruncate creates sparse / preallocated size instantly on APFS
            var statBuf = stat()
            if fstat(fd, &statBuf) == 0 {
                if statBuf.st_size < off_t(totalSize) {
                    _ = ftruncate(fd, off_t(totalSize))
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
}
