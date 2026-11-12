import Foundation

/// A short, honest measurement of the library drive as Porthole uses it: a sequential write (with the drive made to finish it), a sequential read that skips the
/// system's cache, and how many small files it can create per second (what Preparing a download does thousands of times). Everything is made in a folder of its own
/// inside the library and removed again.
struct DriveSpeed: Equatable {
    var writeMBps: Double
    var readMBps: Double
    var smallFilesPerSecond: Double
    var fileSystem: String?

    var summary: String {
        String(format: "Write %.0f MB/s \u{00B7} read %.0f MB/s \u{00B7} %.0f small files/s", writeMBps, readMBps, smallFilesPerSecond)
            + (fileSystem.map { " \u{00B7} \($0)" } ?? "")
    }
}

/// How a download is written to the library drive. A slow drive (a cheap thumb drive) gets few writers, one at a time, in order; anything faster is written like the
/// device's own storage.
enum DriveWriteMode: String {
    case gentle, normal
    /// Below this a download is written gently. A thumb drive that manages 5 MB/s of one long write does far less when many writers jump between files.
    static let gentleBelowMBps = 40.0
    static func mode(forWriteMBps mbps: Double) -> DriveWriteMode { mbps < gentleBelowMBps ? .gentle : .normal }
}

enum DriveSpeedTest {
    private static let megabytes = 64

    /// The quick one a download starts with: 8 MB written in order and made to reach the drive. Blocking, a second or two on a slow thumb drive.
    static func quickWriteMBps(in root: URL) throws -> Double {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(".porthole-speed-test", isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let block = [UInt8](repeating: 0xA5, count: 1 << 20)
        let fd = open(folder.appendingPathComponent("quick.bin").path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let began = DispatchTime.now()
        let size = 8
        for i in 0..<size {
            let written = block.withUnsafeBytes { pwrite(fd, $0.baseAddress, block.count, off_t(i) << 20) }
            guard written == block.count else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        return Double(size) / max(seconds(since: began), 0.001)
    }
    private static let smallFiles = 60

    /// Blocking: run it off the main thread, with the library's access held.
    static func run(in root: URL) throws -> DriveSpeed {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(".porthole-speed-test", isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let block = [UInt8](repeating: 0xA5, count: 1 << 20)
        let big = folder.appendingPathComponent("big.bin").path

        // Write.
        var began = DispatchTime.now()
        let fd = open(big, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for i in 0..<megabytes {
            let written = block.withUnsafeBytes { pwrite(fd, $0.baseAddress, block.count, off_t(i) << 20) }
            guard written == block.count else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        let writeSeconds = seconds(since: began)

        // Read, without the cache.
        began = DispatchTime.now()
        let rd = open(big, O_RDONLY)
        guard rd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(rd, F_NOCACHE, 1)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for i in 0..<megabytes {
            let got = buffer.withUnsafeMutableBytes { pread(rd, $0.baseAddress, 1 << 20, off_t(i) << 20) }
            if got <= 0 { break }
        }
        close(rd)
        let readSeconds = seconds(since: began)

        // Small files: create, write 4 KB, close.
        let small = folder.appendingPathComponent("small", isDirectory: true)
        try fm.createDirectory(at: small, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5A, count: 4096)
        began = DispatchTime.now()
        for i in 0..<smallFiles {
            try payload.write(to: small.appendingPathComponent("f\(i)"))
        }
        let smallSeconds = seconds(since: began)

        return DriveSpeed(writeMBps: Double(megabytes) / max(writeSeconds, 0.001), readMBps: Double(megabytes) / max(readSeconds, 0.001),
                          smallFilesPerSecond: Double(smallFiles) / max(smallSeconds, 0.001), fileSystem: SteamStorageFileSystem.typeName(at: root))
    }

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
