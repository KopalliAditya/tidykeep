import Foundation

/// How a copy differs from the photo that is kept, for the Copies list and the copy-set rows.
public enum CopyRelation: String, Sendable, Hashable, Codable {
    /// Same pixels and format: a re-save or a second import.
    case exact
    /// Fewer pixels than the kept photo: sent through a chat app, or resized.
    case smaller
    /// Same size, another file format, such as a JPEG of a HEIC photo.
    case otherFormat
    /// A screenshot of the kept photo.
    case screenshot

    /// `formats` holds file formats by photo ID when known ("HEIC", "JPEG"). A format that
    /// isn't known never makes two photos differ.
    public static func of(_ copy: AssetMeta, keeper: AssetMeta, formats: [String: String] = [:]) -> CopyRelation {
        if copy.isScreenshot && !keeper.isScreenshot { return .screenshot }
        if copy.pixelWidth * copy.pixelHeight < keeper.pixelWidth * keeper.pixelHeight { return .smaller }
        if let a = formats[copy.id], let b = formats[keeper.id], a != b { return .otherFormat }
        return .exact
    }

    /// The one reason a copy set shows in its row: the first copy that would go.
    public static func of(_ group: PhotoGroup, formats: [String: String] = [:]) -> CopyRelation {
        guard let copy = group.members.dropFirst().first(where: { !group.isProtected($0.id) }) ?? group.members.dropFirst().first else {
            return .exact
        }
        return of(copy, keeper: group.keeper, formats: formats)
    }
}
