import Foundation

/// Offline world place-name pool — reads `place_names.txt` from the bundle
/// (one display-friendly city name per line). 新建机器人 seeds a fresh bot's
/// default name from here, and 「换一个」 rerolls a new unused one.
///
/// Data comes from GeoNames `cities15000` (world cities, population>50k,
/// CC BY 4.0): the asciiname column, deduped, ~11.7k entries. The file's
/// first `#` line (source attribution) is skipped.
///
/// Bundle-read failure falls back to `["Atlantis"]` so there's always at
/// least one name available and a bot can still be created.
enum PlaceNames {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "place_names", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ["Atlantis"]
        }
        let names = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return names.isEmpty ? ["Atlantis"] : names
    }()

    /// A random name not already in `used` (compared case-insensitively).
    /// Falls back to the whole pool when every name is taken.
    static func random(excluding used: Set<String> = []) -> String {
        let pool = all.filter { !used.contains($0.lowercased()) }
        return (pool.isEmpty ? all : pool).randomElement() ?? "Atlantis"
    }
}
