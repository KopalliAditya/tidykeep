import Foundation
import Testing
@testable import TidykeepFiles

@Suite("Performance smoke")
struct PerformanceTests {
    /// 2,000 small files, every content written twice, all the same length so every file goes
    /// through the hashing pass. The bound is loose: it catches an accidental quadratic step
    /// or a whole-file load, not a few slow milliseconds on a busy CI machine.
    @Test func twoThousandSmallFiles() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        for index in 0..<1_000 {
            var content = bytes(2_048, seed: UInt8(index % 251))
            withUnsafeBytes(of: UInt32(index).littleEndian) { content.replaceSubrange(0..<4, with: $0) }
            try temp.write("Folder \(index % 20)/file-\(index).bin", content)
            try temp.write("Copies \(index % 10)/copy-\(index).bin", content)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let inventory = try await scan(temp.url)
        let sets = try await DuplicateFileFinder.find(inventory.items).sets
        let elapsed = clock.now - start

        #expect(inventory.checkedCount == 2_000)
        #expect(sets.count == 1_000)
        #expect(sets.allSatisfy { $0.items.count == 2 })
        #expect(elapsed < .seconds(60))
    }
}
