import Foundation

/// Why a photo was picked as the keeper.
public enum PickReason: String, Sendable, Codable, Hashable, CaseIterable {
    case favorite
    case sharpest
    case bestFaces
    case bestLook
    case bestOverall

    public var phrase: String {
        switch self {
        case .favorite: "you marked it as a favorite"
        case .sharpest: "sharpest"
        case .bestFaces: "best faces"
        case .bestLook: "best overall look"
        case .bestOverall: "best all-round"
        }
    }
}

public struct ShotScore: Sendable, Hashable {
    public let id: String
    /// Weighted score, 0...1, relative to the rest of the group.
    public let total: Double
    public let sharpness: Double
    public let aesthetics: Double
    /// Nil when nobody in the group has a detected face.
    public let faces: Double?
}

/// A group's photos, best first.
public struct Ranking: Sendable, Hashable {
    public let scores: [ShotScore]
    public let keeperID: String
    public let reasons: [PickReason]
    /// The top two are too close to call; the UI asks the user to take a look.
    public let isCloseCall: Bool

    public var orderedIDs: [String] { scores.map(\.id) }
}

/// Ranks the photos in one group.
///
/// Only differences between near-identical shots matter, so each signal is measured from
/// the group's worst photo, in units of a difference that clearly shows (capped at 1).
/// A tiny edge stays tiny: Vision's aesthetics score can prefer a blurred frame by a
/// hair, and that mustn't outweigh a frame that is plainly sharper.
public enum ShotScorer {
    public struct Weights: Sendable, Hashable {
        public var aesthetics: Double
        public var sharpness: Double
        public var faces: Double

        public static let scenery = Weights(aesthetics: 0.55, sharpness: 0.45, faces: 0)
        public static let people = Weights(aesthetics: 0.30, sharpness: 0.30, faces: 0.40)
    }

    static let closeCallMargin = 0.08
    /// A difference that clearly shows, per signal. Sharpness is a log scale, so 1 is
    /// about 2.7 times the detail. Aesthetics runs -1...1; face quality 0...1.
    static let unit = (aesthetics: 0.5, sharpness: 1.0, faces: 0.25)
    /// The share of a unit a photo must lead by for that signal to be named as the reason.
    static let reasonLead = 0.3

    public static func rank(_ members: [(meta: AssetMeta, signals: FrameSignals)]) -> Ranking {
        precondition(!members.isEmpty, "a group has at least one photo")

        let sharp = scaled(members.map { Double($0.signals.sharpness) }, unit: unit.sharpness)

        let rawAesthetics = members.map { $0.signals.aesthetics.map(Double.init) }
        let known = rawAesthetics.compactMap { $0 }.sorted()
        let fallback = known.isEmpty ? 0 : known[known.count / 2]
        let look = scaled(rawAesthetics.map { $0 ?? fallback }, unit: unit.aesthetics)

        let maxFaces = members.map(\.signals.faceQualities.count).max() ?? 0
        let faces: [Double]? = maxFaces == 0 ? nil : scaled(members.map {
            faceScore($0.signals.faceQualities, groupMaxFaces: maxFaces)
        }, unit: unit.faces)

        let w = faces == nil ? Weights.scenery : Weights.people
        var scores: [ShotScore] = members.indices.map { i in
            let face = faces?[i]
            let total = w.aesthetics * look[i] + w.sharpness * sharp[i] + w.faces * (face ?? 0)
            return ShotScore(id: members[i].meta.id, total: total, sharpness: sharp[i], aesthetics: look[i], faces: face)
        }
        let index = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.meta.id, $0) })
        scores.sort { $0.total != $1.total ? $0.total > $1.total : index[$0.id]! < index[$1.id]! }

        if let favorite = scores.first(where: { members[index[$0.id]!].meta.isFavorite }) {
            scores.removeAll { $0.id == favorite.id }
            scores.insert(favorite, at: 0)
            return Ranking(scores: scores, keeperID: favorite.id, reasons: [.favorite], isCloseCall: false)
        }

        let top = scores[0]
        var reasons: [PickReason] = []
        if let face = top.faces, leads(face, faces) { reasons.append(.bestFaces) }
        if leads(top.sharpness, sharp) { reasons.append(.sharpest) }
        if leads(top.aesthetics, look) { reasons.append(.bestLook) }
        if reasons.isEmpty { reasons = [.bestOverall] }

        let closeCall = scores.count > 1 && top.total - scores[1].total < closeCallMargin
        return Ranking(scores: scores, keeperID: top.id, reasons: reasons, isCloseCall: closeCall)
    }

    /// A photo's faces: mostly the worst face (one blink spoils a group shot), and a
    /// penalty for faces missing compared with the best frame in the group.
    static func faceScore(_ qualities: [Float], groupMaxFaces: Int) -> Double {
        guard !qualities.isEmpty, groupMaxFaces > 0 else { return 0 }
        let q = qualities.map(Double.init)
        let base = 0.6 * q.min()! + 0.4 * q.reduce(0, +) / Double(q.count)
        return base * Double(min(q.count, groupMaxFaces)) / Double(groupMaxFaces)
    }

    /// Distance above the group's lowest value, in units, capped at 1.
    static func scaled(_ values: [Double], unit: Double) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        let range = max(hi - lo, unit)
        return values.map { ($0 - lo) / range }
    }

    /// The photo is the group's best on this signal, by a margin that shows.
    private static func leads(_ value: Double, _ all: [Double]?) -> Bool {
        guard let all, let best = all.max() else { return false }
        return value == best && best >= reasonLead
    }
}
