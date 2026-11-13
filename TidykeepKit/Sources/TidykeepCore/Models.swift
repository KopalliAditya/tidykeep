import Foundation

/// Metadata for one photo, from PhotoKit (or from a folder in the CLI and tests).
public struct AssetMeta: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let creationDate: Date
    /// Changes only when the pixels change (an edit or a revert). Analysis is cached against it.
    public let contentVersion: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let burstID: String?
    public let isFavorite: Bool
    public let hasAdjustments: Bool
    /// Photos marks it as a screenshot. Screenshots of different app screens look alike to the
    /// content model, so the copy pass holds pairs of them to a stricter rule, and a copy that
    /// is a screenshot is never kept over the photo it shows.
    public let isScreenshot: Bool

    public init(
        id: String,
        creationDate: Date,
        contentVersion: Date? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        burstID: String? = nil,
        isFavorite: Bool = false,
        hasAdjustments: Bool = false,
        isScreenshot: Bool = false
    ) {
        self.id = id
        self.creationDate = creationDate
        self.contentVersion = contentVersion
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.burstID = burstID
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
        self.isScreenshot = isScreenshot
    }

    /// Favorites and edited photos are never suggested for removal: the user already chose them.
    public var isProtected: Bool { isFavorite || hasAdjustments }

    private enum CodingKeys: String, CodingKey {
        case id, creationDate, contentVersion, pixelWidth, pixelHeight, burstID, isFavorite, hasAdjustments, isScreenshot
    }

    /// `isScreenshot` is newer than the rest, so metadata written before it decodes as "not a screenshot".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        creationDate = try c.decode(Date.self, forKey: .creationDate)
        contentVersion = try c.decodeIfPresent(Date.self, forKey: .contentVersion)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        burstID = try c.decodeIfPresent(String.self, forKey: .burstID)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        hasAdjustments = try c.decode(Bool.self, forKey: .hasAdjustments)
        isScreenshot = try c.decodeIfPresent(Bool.self, forKey: .isScreenshot) ?? false
    }
}

/// What on-device analysis learned about one photo.
public struct FrameSignals: Sendable, Hashable, Codable {
    /// Softened Vision feature print, used to tell whether two photos show the same moment.
    public var embedding: QuantizedEmbedding
    /// Vision's overall aesthetics score, -1...1. Nil when the request failed.
    public var aesthetics: Float?
    /// Vision flags photos of documents, receipts and the like as utility images.
    public var isUtility: Bool
    /// Focus measure from `Sharpness`; higher is sharper. Only comparable within a group.
    public var sharpness: Float
    /// Vision face capture quality per detected face, 0...1. Blinks, blur and turned heads score low.
    public var faceQualities: [Float]
    /// The content model's CLS embedding (DINOv2-small, unit length): what the picture is,
    /// almost regardless of crop, size, rotation or re-encoding. The copy pass uses it to find
    /// copies across the whole library. Nil when the photo was analyzed without the model.
    public var dinoCLS: QuantizedEmbedding?
    /// The mean of the content model's patch embeddings (unit length), from the same run.
    /// Better than the CLS at telling apart neighbouring moments, so `SeriesBuilder` weighs
    /// it with the feature print. Nil when the photo was analyzed without the model.
    public var dinoMean: QuantizedEmbedding?

    public init(
        embedding: QuantizedEmbedding,
        aesthetics: Float?,
        isUtility: Bool,
        sharpness: Float,
        faceQualities: [Float],
        dinoCLS: QuantizedEmbedding? = nil,
        dinoMean: QuantizedEmbedding? = nil
    ) {
        self.embedding = embedding
        self.aesthetics = aesthetics
        self.isUtility = isUtility
        self.sharpness = sharpness
        self.faceQualities = faceQualities
        self.dinoCLS = dinoCLS
        self.dinoMean = dinoMean
    }

    private enum CodingKeys: String, CodingKey {
        case embedding, aesthetics, isUtility, sharpness, faceQualities, dinoCLS, dinoMean
    }

    /// The content embeddings are newer than the rest, so a cache written without them still
    /// loads; those photos just have no content embedding until they are analyzed again.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        embedding = try c.decode(QuantizedEmbedding.self, forKey: .embedding)
        aesthetics = try c.decodeIfPresent(Float.self, forKey: .aesthetics)
        isUtility = try c.decode(Bool.self, forKey: .isUtility)
        sharpness = try c.decode(Float.self, forKey: .sharpness)
        faceQualities = try c.decode([Float].self, forKey: .faceQualities)
        dinoCLS = try c.decodeIfPresent(QuantizedEmbedding.self, forKey: .dinoCLS)
        dinoMean = try c.decodeIfPresent(QuantizedEmbedding.self, forKey: .dinoMean)
    }
}

public enum LibraryAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case limited
    case full

    public var canRead: Bool { self == .limited || self == .full }
}

/// How far back to look.
public enum ScanScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case last30Days
    case last12Months
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .last30Days: "Last 30 days"
        case .last12Months: "Last 12 months"
        case .everything: "All photos"
        }
    }

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .last30Days: calendar.date(byAdding: .day, value: -30, to: now)
        case .last12Months: calendar.date(byAdding: .month, value: -12, to: now)
        case .everything: nil
        }
    }
}

/// How alike photos must be to count as one group.
public enum Sensitivity: String, CaseIterable, Codable, Sendable, Identifiable {
    case strict
    case balanced
    case loose

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strict: "Only near-identical"
        case .balanced: "Balanced"
        case .loose: "Include similar"
        }
    }

    /// Fitted in bench/rules.py on the dev halves of the benchmark sets (see `GroupingConfig`).
    /// Strict keeps every pair it groups right on the dev data with every constant 15% wider;
    /// balanced and loose aim at 99% and 95% pair precision with a 5% margin. Anchors are the
    /// links times 1.1818 in every preset. Don't raise these by hand: precision falls off a
    /// cliff where the first unrelated series merge, and balanced sits just below it.
    public var config: GroupingConfig {
        switch self {
        case .strict:
            GroupingConfig(maxGap: 30, maxSpan: 120, link: 0.50, anchor: 0.5909, softOnlyLink: 0.50, softOnlyAnchor: 0.5909)
        case .balanced:
            GroupingConfig(maxGap: 60, maxSpan: 240, link: 0.55, anchor: 0.65, softOnlyLink: 0.55, softOnlyAnchor: 0.65)
        case .loose:
            GroupingConfig(maxGap: 180, maxSpan: 900, link: 0.65, anchor: 0.7682, softOnlyLink: 0.58, softOnlyAnchor: 0.6855)
        }
    }
}
