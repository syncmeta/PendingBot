import Foundation

/// Parse a Postgres / PostgREST timestamp string into a Date.
///
/// Postgres emits timestamps with microsecond fractional seconds
/// (`2026-05-02T14:30:00.123456+00:00`); the default
/// ISO8601DateFormatter rejects them and returns nil. This helper
/// walks both ISO8601 variants, handles the embedded-projection shape
/// (space instead of T), and falls back to a list of explicit patterns
/// for exotic timezone formats Postgres can produce.
///
/// Returns nil only when none of the formats match — at that point the
/// caller decides whether to default to `Date()`, 0, etc.
enum ServerTimestamp {
    static func parse(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // PostgREST sometimes hands back a Postgres-flavoured timestamp
        // ("2026-05-02 14:30:00.123456+00" — space instead of T) when
        // the column comes through an embed projection.
        let withT = s.replacingOccurrences(of: " ", with: "T")
        if withT != s {
            if let d = isoFractional.date(from: withT) { return d }
            if let d = isoPlain.date(from: withT) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in fallbackPatterns {
            df.dateFormat = pattern
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Convenience: parse to a Unix-epoch second, or `default`
    /// (commonly 0 or "now") when parsing fails.
    static func epochSeconds(_ s: String, default fallback: Int) -> Int {
        parse(s).map { Int($0.timeIntervalSince1970) } ?? fallback
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fallbackPatterns = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssX",
        "yyyy-MM-dd HH:mm:ss.SSSSSSX",
        "yyyy-MM-dd HH:mm:ssX",
    ]
}
