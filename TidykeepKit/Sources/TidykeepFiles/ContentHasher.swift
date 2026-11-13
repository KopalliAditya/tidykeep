import CryptoKit
import Foundation

/// SHA-256 of file content, read in fixed-size pieces so a 4 GB video costs 1 MB of memory.
///
/// Both functions give a skip reason, rather than throw, when a file can't be read or isn't
/// fully on the device: one bad file shouldn't stop a check, but the Coverage sheet must still
/// count it. They throw only `CancellationError`.
enum ContentHasher {
    /// A file's digest, or why there isn't one.
    enum Outcome: Equatable {
        case digest(String)
        case skipped(FileSkipReason)
    }

    /// How much of each end the quick pass reads.
    static let edgeBytes = 64 * 1024
    /// Files this long or shorter are read whole by the quick pass, so its digest is the full one.
    static let wholeFileLimit = Int64(2 * edgeBytes)
    static let chunkBytes = 1024 * 1024

    /// The quick pass: the first and last 64 KB. Copies made by a download or an export often
    /// share a length but differ near an end (headers, metadata), so this rules most of them out
    /// for a fraction of the reading.
    static func edgeDigest(of url: URL, length: Int64) throws -> Outcome {
        guard length > wholeFileLimit else { return try fullDigest(of: url, length: length) }
        return try withFile(url) { file in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: edgeBytes, alignment: 16)
            defer { buffer.deallocate() }
            var hasher = SHA256()
            for offset in [Int64(0), length - Int64(edgeBytes)] {
                guard (try? read(file, into: buffer, at: offset)) == edgeBytes else { return nil }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
            }
            return hex(hasher.finalize())
        }
    }

    /// The full digest. Skipped when the length read differs from `length`: the file changed
    /// since the scan, and a digest of something else must not make it a duplicate.
    static func fullDigest(of url: URL, length: Int64) throws -> Outcome {
        try withFile(url) { file in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 16)
            defer { buffer.deallocate() }
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let count = try? read(file, into: buffer, at: total) else { return nil }
                if count == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                total += Int64(count)
                if total > length { return nil }
            }
            return total == length ? hex(hasher.finalize()) : nil
        }
    }

    /// Opens the file read-only with downloads barred and hashes it with `body`, which returns
    /// nil when the read failed or the length was wrong.
    ///
    /// A file that fails after the check said it was safe is asked again, because iOS may have
    /// evicted it in between; then it's in iCloud only, not unreadable.
    private static func withFile(_ url: URL, _ body: (Int32) throws -> String?) throws -> Outcome {
        if let reason = FileFacts.reasonNotToRead(url) { return .skipped(reason) }
        let digest: String? = try FileFacts.withoutDownloads {
            let file = url.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_RDONLY | O_NOFOLLOW) } ?? -1
            }
            guard file >= 0 else { return nil }
            defer { close(file) }
            return try body(file)
        }
        if let digest { return .digest(digest) }
        return .skipped(FileFacts.reasonNotToRead(url) == .iCloudOnly ? .iCloudOnly : .unreadable)
    }

    private struct ReadFailed: Error {}

    /// Fills `buffer` from `offset`, short only at the end of the file.
    private static func read(_ file: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        var filled = 0
        while filled < buffer.count {
            let count = pread(file, buffer.baseAddress! + filled, buffer.count - filled, off_t(offset) + off_t(filled))
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadFailed()
            }
            if count == 0 { break }
            filled += count
        }
        return filled
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
