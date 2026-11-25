import Foundation

/// Which neighbour the pager should keep prepared.
public enum PrewarmDirection: String, Equatable {
    case next
    case previous
}

/// Pure hysteresis policy for the prewarm target. The pager is anchored on a
/// settled page; the target only flips after the user has moved a meaningful
/// fraction of a page in the opposite direction. A micro-drag around the
/// rest point therefore cannot alternate between N-1 and N+1.
public enum PrewarmPolicy {
    /// Fractions of a page. 0.25 on a 6s Plus is roughly 184 pt.
    public static let enterThreshold: Double = 0.25

    public enum Mode: String {
        case hysteresis
        case fixedNext
    }

    /// `fixedNext` is a deliberate fallback for measurements, not the default.
    public static var mode: Mode = .hysteresis

    /// Returns the direction that should stay prepared after moving
    /// `deltaPages` from the anchor page (negative = toward the previous page).
    public static func direction(
        current: PrewarmDirection,
        deltaPages: Double
    ) -> PrewarmDirection {
        guard mode == .hysteresis else { return .next }
        switch current {
        case .next:
            return deltaPages <= -enterThreshold ? .previous : .next
        case .previous:
            return deltaPages >= enterThreshold ? .next : .previous
        }
    }

    /// The neighbour index for the anchor, or nil at the ends of the feed.
    public static func targetIndex(
        anchor: Int,
        direction: PrewarmDirection,
        count: Int
    ) -> Int? {
        guard count > 0, anchor >= 0, anchor < count else { return nil }
        let index = direction == .next ? anchor + 1 : anchor - 1
        return (0..<count).contains(index) ? index : nil
    }
}

/// The role a visible cell should currently have. Applying the same role twice
/// must be a no-op so scroll callbacks cannot thrash the player pool.
public enum CellRole: Equatable {
    case active
    case prewarm
    case none

    public static func of(
        streamId: Int64,
        active: Int64,
        prewarm: Int64?
    ) -> CellRole {
        if streamId == active { return .active }
        if let prewarm, streamId == prewarm { return .prewarm }
        return .none
    }
}
