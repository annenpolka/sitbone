import Foundation

public enum BrowserSiteIdentity {
    private static let secondLevelCountryDomains: Set<String> = [
        "ac", "co", "com", "edu", "go", "gov", "net", "or", "org"
    ]

    /// URL文字列から同一サイト判定用の安定キーを作る
    public static func canonicalSiteKey(urlString: String?) -> String? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        return canonicalHost(host)
    }

    static func canonicalHost(_ host: String) -> String {
        let lowered = host.lowercased()
        let withoutWWW = lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
        let parts = withoutWWW.split(separator: ".")

        guard parts.count > 2 else { return withoutWWW }

        let last = String(parts[parts.count - 1])
        let secondLast = String(parts[parts.count - 2])

        if last.count == 2, secondLevelCountryDomains.contains(secondLast), parts.count >= 3 {
            return parts.suffix(3).joined(separator: ".")
        }

        return parts.suffix(2).joined(separator: ".")
    }
}
