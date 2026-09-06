import Foundation

/// Best-effort heuristic for guessing a differential pair's *other* net name from one half's own
/// name -- e.g. "USB_DP" -> "USB_DN", "D+" -> "D-", "SIG_P" -> "SIG_N". Used by
/// SourceListViewController to offer mirroring an Included/Probe/Excite toggle onto the other half
/// of a pair, the same spirit as GroundNetHeuristic guessing a board's ground net by name -- no
/// existing pair is still inferred from the net-name string; once the user accepts the suggestion,
/// reciprocal pair metadata is persisted on the two InvolvedNetConfig entries.
enum DifferentialPairNetHeuristic {
    /// Candidate partner net names for `netName`, trying standard polarity-marker suffix
    /// conventions in priority order -- an explicit delimiter first ("_P"/"_N", "+"/"-"), a bare
    /// trailing letter last ("P"/"N", as in "USB_DP"/"USB_DN") since that's the most prone to a
    /// false match (plenty of ordinary net names simply happen to end in "P" or "N"). Returns []
    /// if none apply. This never claims a candidate is real -- the caller checks each in turn
    /// against the real board (does a net/pin with that name actually exist) and uses the first
    /// that does.
    static func partnerCandidates(for netName: String) -> [String] {
        let suffixPairs: [(suffix: String, replacement: String)] = [
            ("_P", "_N"), ("_N", "_P"),
            ("+", "-"), ("-", "+"),
            ("P", "N"), ("N", "P"),
        ]
        var candidates: [String] = []
        for (suffix, replacement) in suffixPairs {
            guard netName.hasSuffix(suffix), netName.count > suffix.count else { continue }
            candidates.append(String(netName.dropLast(suffix.count)) + replacement)
        }
        return candidates
    }
}
