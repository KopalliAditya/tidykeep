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

    public init(
        id: String,
        creationDate: Date,
        contentVersion: Date? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        burstID: String? = nil,
        isFavorite: Bool = false,
        hasAdjustments: Bool = false
    ) {
        self.id = id
        self.creationDate = creationDate
        self.contentVersion = contentVersion
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.burstID = burstID
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
    }

    /// Favorites and edited photos are never suggested for removal: the user already chose them.
    public var isProtected: Bool { isFavorite || hasAdjustments }
}

/// What on-device analysis learned about one photo.
public struct FrameSignals: Sendable, Hashable, Codable {
    /// Image feature print, used to tell whether two photos show the same moment.
    public var embedding: QuantizedEmbedding
    /// Vision's overall aesthetics score, -1...1. Nil when the request failed.
    public var aesthetics: Float?
    /// Vision flags photos of documents, receipts and the like as utility images.
    public var isUtility: Bool
    /// Focus measure from `Sharpness`; higher is sharper. Only comparable within a group.
    public var sharpness: Float
    /// Vision face capture quality per detected face, 0...1. Blinks, blur and turned heads score low.
    public var faceQualities: [Float]

    public init(embedding: QuantizedEmbedding, aesthetics: Float?, isUtility: Bool, sharpness: Float, faceQualities: [Float]) {
        self.embedding = embedding
        self.aesthetics = aesthetics
        self.isUtility = isUtility
        self.sharpness = sharpness
        self.faceQualities = faceQualities
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

    public var config: GroupingConfig {
        switch self {
        case .strict: GroupingConfig(maxGap: 30, maxSpan: 120, linkDistance: 0.40, anchorDistance: 0.50)
        case .balanced: GroupingConfig(maxGap: 60, maxSpan: 240, linkDistance: 0.55, anchorDistance: 0.65)
        case .loose: GroupingConfig(maxGap: 180, maxSpan: 900, linkDistance: 0.70, anchorDistance: 0.80)
        }
    }
}

/// Thresholds for `SeriesBuilder`. Distances are Euclidean distances between
/// revision-2 Vision feature prints (unit vectors, so 0...2).
public struct GroupingConfig: Sendable, Hashable, Codable {
    /// Longest pause between two shots of one series, in seconds.
    public var maxGap: TimeInterval
    /// Longest a series may run from its first shot, in seconds.
    public var maxSpan: TimeInterval
    /// A photo joins a group if it is this close to one of the group's recent members...
    public var linkDistance: Float
    /// ...and this close to the group's first photo, so slow pans don't chain into one group.
    public var anchorDistance: Float
    /// How many recent members of a group to compare against.
    public var lookback: Int

    public init(maxGap: TimeInterval, maxSpan: TimeInterval, linkDistance: Float, anchorDistance: Float, lookback: Int = 8) {
        self.maxGap = maxGap
        self.maxSpan = maxSpan
        self.linkDistance = linkDistance
        self.anchorDistance = anchorDistance
        self.lookback = lookback
    }
}
