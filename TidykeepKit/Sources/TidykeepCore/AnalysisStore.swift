import Foundation

/// The on-device cache of analysis results, so each photo is analyzed once.
///
/// Entries are keyed by photo ID and checked against the photo's content version, so an
/// edited photo is analyzed again. The file records the analyzer version (Vision request
/// revisions included); a new SDK that changes a revision invalidates the whole cache
/// instead of mixing incompatible feature prints.
public actor AnalysisStore {
    /// Bumped whenever what an entry holds changes, so a cache from an older build is
    /// rebuilt rather than read with fields missing. A file without it is from schema 1.
    /// 2: the content embeddings (`FrameSignals.dinoCLS` and `dinoMean`).
    static let schema = 2

    struct Entry: Codable {
        var contentVersion: Date?
        var signals: FrameSignals
    }

    struct Contents: Codable {
        var schema: Int?
        var analyzerVersion: String
        var entries: [String: Entry]
    }

    private let url: URL?
    private var contents: Contents
    private var dirty = false

    /// `url == nil` keeps everything in memory.
    public init(url: URL?, analyzerVersion: String) {
        self.url = url
        let empty = Contents(schema: Self.schema, analyzerVersion: analyzerVersion, entries: [:])
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode(Contents.self, from: data),
              saved.schema == Self.schema, saved.analyzerVersion == analyzerVersion
        else {
            contents = empty
            return
        }
        contents = saved
    }

    public var count: Int { contents.entries.count }

    public func signals(for meta: AssetMeta) -> FrameSignals? {
        guard let entry = contents.entries[meta.id], entry.contentVersion == meta.contentVersion else { return nil }
        return entry.signals
    }

    public func put(_ signals: FrameSignals, for meta: AssetMeta) {
        contents.entries[meta.id] = Entry(contentVersion: meta.contentVersion, signals: signals)
        dirty = true
    }

    public func remove(_ ids: some Sequence<String> & Sendable) {
        for id in ids where contents.entries.removeValue(forKey: id) != nil {
            dirty = true
        }
    }

    /// Drops entries for photos that are gone from the library.
    public func retainOnly(_ ids: Set<String>) {
        let before = contents.entries.count
        contents.entries = contents.entries.filter { ids.contains($0.key) }
        if contents.entries.count != before { dirty = true }
    }

    public func removeAll() {
        contents.entries.removeAll()
        dirty = true
    }

    public func save() throws {
        guard dirty, let url else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(contents)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        dirty = false
    }
}

/// A small Codable value saved as JSON next to the cache.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
