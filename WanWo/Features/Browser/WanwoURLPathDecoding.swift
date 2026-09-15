//
//  WanwoURLPathDecoding.swift
//  WanWo
//
//  【vendored 原件 · 出处 OpenMinis `src/ios/Agent/Chat/MinisURLPathDecoding.swift`（GPL v3）】
//  10-design M6.5 深链语义源（m6-scope-brief §5：容错 percent-decoding :21-35）。
//  类名 MinisURLPathDecoding → WanwoURLPathDecoding；实现逐行保留。
//

import Foundation

/// Shared percent-decoding helpers for resolving `wanwo://` URLs to on-disk
/// subpaths.
///
/// A correctly-formed `wanwo_url` percent-encodes the filename exactly once
/// (see `linuxPathToWanwoURL`), so `URL(string:).path` decodes it back to the
/// real UTF-8 name. But links sometimes arrive double-encoded — the agent (or
/// an intermediate Markdown autolink/sanitize step) re-encodes the literal `%`
/// of an already-encoded URL into `%25`, turning `%E6` into `%2520`/`%25E6`.
/// `url.path` then decodes only one layer, leaving a literal `%E6…` that
/// matches no file on disk, so the tap fell through to the workspace folder
/// view instead of opening the target file. [T-fix-double-encoding 2026-06-01]
///
/// The fix is tolerant resolution: try the single-decoded subpath first
/// (the correct case, unchanged behaviour), then — only when that doesn't
/// exist on disk — try one extra `removingPercentEncoding` pass to recover a
/// double-encoded name. The disk-existence check is the disambiguator, so a
/// filename that legitimately contains a `%` is still resolved by the first
/// candidate and never reaches the extra decode.
enum WanwoURLPathDecoding {
    /// Candidate subpaths for a `wanwo://` URL, in priority order.
    /// `url.path` already strips the scheme/host and percent-decodes once.
    static func subPathCandidates(for url: URL) -> [String] {
        let p = url.path
        let base = p.hasPrefix("/") ? String(p.dropFirst()) : p
        var candidates = [base]
        // Recover double-encoded names: a second decode collapses %25XX → %XX
        // → the real UTF-8 character. Only add it when it actually differs so
        // single-encoded (already-correct) URLs keep exactly one candidate.
        if let twice = base.removingPercentEncoding, twice != base {
            candidates.append(twice)
        }
        return candidates
    }
}
