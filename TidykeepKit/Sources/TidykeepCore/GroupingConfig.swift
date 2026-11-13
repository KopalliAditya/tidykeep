import Foundation

/// Thresholds for `SeriesBuilder`.
///
/// Two signals say whether two photos show the same moment. Both are unit vectors compared by
/// Euclidean distance (0...2):
/// - `dSoft`, between softened Vision feature prints (`FrameSignals.embedding`). It shrugs off
///   blur and shake, but on sharp photos it also calls neighbouring moments alike.
/// - `dMean`, between DINOv2 patch means (`FrameSignals.dinoMean`). It tells neighbouring
///   moments apart much better, but blur moves it more.
///
/// Their weighted sum `softWeight * dSoft + dinoWeight * dMean` is the pair's score, in the
/// same distance units. A photo links to a group member when the score is at most `link`, or
/// when `dSoft` alone is at most `softLink` (which brings back blurry burst frames the content
/// model pulls apart). The anchor test against the group's first photo is the same with
/// `anchor` and `softAnchor`. When either photo has no patch mean (analyzed before the model
/// shipped) the softened print decides alone, against `softOnlyLink` and `softOnlyAnchor`.
///
/// A score of exactly 1 passes, as in the bench (`score <= threshold`).
///
/// The weights come from one logistic regression on dev pairs at most 240 s apart, rescaled to
/// sum to 1; every constant was fitted on dev halves only (bench/rules.py).
public struct GroupingConfig: Sendable, Hashable, Codable {
    /// Longest pause between two shots of one series, in seconds.
    public var maxGap: TimeInterval
    /// Longest a series may run from its first shot, in seconds.
    public var maxSpan: TimeInterval
    /// A photo joins a group if its score to one of the group's recent members is at most this...
    public var link: Float
    /// ...and its score to the group's first photo is at most this, so slow pans don't chain.
    public var anchor: Float
    /// The softened print alone is enough to link at this distance or closer. 0 turns it off.
    public var softLink: Float
    /// The softened print alone is enough to stay with the first photo at this distance or closer.
    public var softAnchor: Float
    /// Link distance on the softened print when a pair has no content embedding.
    public var softOnlyLink: Float
    /// Anchor distance on the softened print when a pair has no content embedding.
    public var softOnlyAnchor: Float
    /// How many recent members of a group to compare against.
    public var lookback: Int

    public static let softWeight: Float = 0.3115
    public static let dinoWeight: Float = 0.6885

    public init(
        maxGap: TimeInterval,
        maxSpan: TimeInterval,
        link: Float,
        anchor: Float,
        softLink: Float = 0.35,
        softAnchor: Float = 0.4136,
        softOnlyLink: Float,
        softOnlyAnchor: Float,
        lookback: Int = 8
    ) {
        self.maxGap = maxGap
        self.maxSpan = maxSpan
        self.link = link
        self.anchor = anchor
        self.softLink = softLink
        self.softAnchor = softAnchor
        self.softOnlyLink = softOnlyLink
        self.softOnlyAnchor = softOnlyAnchor
        self.lookback = lookback
    }

    /// The link test as one number: the pair links when this is at most 1.
    /// `content` is the patch-mean distance, nil when either photo has none.
    public func linkScore(soft: Float, content: Float?) -> Float {
        Self.score(soft: soft, content: content, fused: link, softArm: softLink, softOnly: softOnlyLink)
    }

    /// The anchor test as one number: the photo may stay with the group's first photo when this is at most 1.
    public func anchorScore(soft: Float, content: Float?) -> Float {
        Self.score(soft: soft, content: content, fused: anchor, softArm: softAnchor, softOnly: softOnlyAnchor)
    }

    /// The weighted distance the `link` and `anchor` thresholds apply to.
    static func weighted(soft: Float, content: Float) -> Float {
        softWeight * soft + dinoWeight * content
    }

    /// Each distance divided by its threshold, so the OR of two tests is the smaller ratio.
    /// A threshold of 0 or less turns its test off. A content distance that isn't finite
    /// (vectors of different length) counts as no content embedding: the softened print decides.
    static func score(soft: Float, content: Float?, fused: Float, softArm: Float, softOnly: Float) -> Float {
        guard soft.isFinite else { return .infinity }
        guard let content, content.isFinite else { return ratio(soft, softOnly) }
        return min(ratio(weighted(soft: soft, content: content), fused), ratio(soft, softArm))
    }

    private static func ratio(_ distance: Float, _ threshold: Float) -> Float {
        threshold > 0 ? distance / threshold : .infinity
    }
}
