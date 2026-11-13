import CoreGraphics
import Foundation
import TidykeepCore
import ImageIO
import UniformTypeIdentifiers

/// A folder of image files acting as a photo library, for `tkscan` and the tests.
///
/// Capture dates come from an optional `manifest.json`, then EXIF, then the file's
/// creation date. "Deleting" moves files into `.removed/` inside the folder.
public final class FolderPhotoSource: PhotoSource {
    /// Per-file overrides, keyed by file name.
    public struct Manifest: Codable, Sendable {
        public struct Entry: Codable, Sendable {
            public var date: Date
            public var burst: String?
            public var favorite: Bool?
            public var edited: Bool?
            /// What PhotoKit's screenshot subtype would say. A folder can't know, so it is
            /// false unless the manifest says otherwise.
            public var screenshot: Bool?

            public init(date: Date, burst: String? = nil, favorite: Bool? = nil, edited: Bool? = nil, screenshot: Bool? = nil) {
                self.date = date
                self.burst = burst
                self.favorite = favorite
                self.edited = edited
                self.screenshot = screenshot
            }
        }

        public var files: [String: Entry]

        public init(files: [String: Entry]) { self.files = files }

        public static let fileName = "manifest.json"

        public func write(to folder: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
        }

        static func read(from folder: URL) -> Manifest? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Manifest.self, from: data)
        }
    }

    public let folder: URL
    static let removedFolder = ".removed"

    public init(folder: URL) {
        self.folder = folder
    }

    public func access() async -> LibraryAccess { .full }
    public func requestAccess() async -> LibraryAccess { .full }
    public func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    public func fetchAssets(since: Date?) async throws -> [AssetMeta] {
        let manifest = Manifest.read(from: folder)
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url -> AssetMeta? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
            let name = url.lastPathComponent
            let entry = manifest?.files[name]
            guard let date = entry?.date ?? Self.exifDate(url) ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            else { return nil }
            if let since, date < since { return nil }
            let size = Self.pixelSize(url)
            return AssetMeta(
                id: name,
                creationDate: date,
                pixelWidth: size.width,
                pixelHeight: size.height,
                burstID: entry?.burst,
                isFavorite: entry?.favorite ?? false,
                hasAdjustments: entry?.edited ?? false,
                isScreenshot: entry?.screenshot ?? false
            )
        }.sorted { $0.creationDate < $1.creationDate }
    }

    public func analysisImage(for id: String, maxPixelSize: Int) async throws -> CGImage {
        let url = folder.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PhotoSourceError.notFound }
        guard let image = Self.thumbnail(url, maxPixelSize: maxPixelSize) else { throw PhotoSourceError.unreadable }
        return image
    }

    public func thumbnail(for id: String, pixelSize: Int) async -> CGImage? {
        Self.thumbnail(folder.appendingPathComponent(id), maxPixelSize: pixelSize)
    }

    public func delete(_ ids: [String]) async -> Set<String> {
        let bin = folder.appendingPathComponent(Self.removedFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Like PhotoKit's source, look again: a photo marked favorite or edited since is kept.
        let manifest = Manifest.read(from: folder)
        var deleted = Set<String>()
        for id in ids {
            if let entry = manifest?.files[id], entry.favorite == true || entry.edited == true { continue }
            do {
                try FileManager.default.moveItem(at: folder.appendingPathComponent(id), to: bin.appendingPathComponent(id))
                deleted.insert(id)
            } catch {
                continue
            }
        }
        return deleted
    }

    public func existing(_ ids: [String]) async -> Set<String> {
        Set(ids.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
    }

    // MARK: -

    static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func exifDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: text) else { return nil }
        let subsec = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(subsec)
    }
}
