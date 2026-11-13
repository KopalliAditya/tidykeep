import CryptoKit
import Foundation
import Testing
@testable import TidykeepFiles

@Suite("Content hashing")
struct ContentHasherTests {
    @Test func fullDigestIsTheSHA256OfTheContent() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let content = bytes(2_300_000, seed: 11)
        let file = try temp.write("a.bin", content)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()

        #expect(try ContentHasher.fullDigest(of: file, length: Int64(content.count)) == .digest(expected))
        // A length that doesn't match what's on disk means the file changed: no digest.
        #expect(try ContentHasher.fullDigest(of: file, length: Int64(content.count - 1)) == .skipped(.unreadable))
    }

    @Test func aMissingFileHasNoDigest() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let missing = temp.url.appendingPathComponent("missing.bin")

        #expect(try ContentHasher.edgeDigest(of: missing, length: 500_000) == .skipped(.unreadable))
    }

    @Test func readsWithDownloadsBarredThenRestoresTheThread() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)

        let inside = FileFacts.withoutDownloads { getiopolicy_np(type, IOPOL_SCOPE_THREAD) }

        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }

    @Test func restoresTheThreadWhenTheBodyThrows() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)

        #expect(throws: CancellationError.self) {
            try FileFacts.withoutDownloads { throw CancellationError() }
        }

        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }

    @Test func stopsBetweenPiecesWhenCancelled() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let length = 3_000_000
        let file = try temp.write("a.bin", bytes(length, seed: 12))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ContentHasher.fullDigest(of: file, length: Int64(length))
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
