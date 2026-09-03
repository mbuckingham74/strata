import Foundation

/// Minimal canonical identity for YouTube Library dedup.
///
/// Maps the various YouTube URL shapes for the same video to one stable key:
/// `youtube.com/watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `music.youtube.com`,
/// extra query params, and scheme/host casing.
///
/// Video IDs are case-sensitive and preserved as-is. When no robust video ID can
/// be extracted, falls back to a normalized URL string so distinct URLs still
/// dedupe stably without colliding.
enum YouTubeCanonicalIdentity {
    /// Genuine YouTube hosts only: exact apex domains plus proper subdomains.
    /// Rejects suffix lookalikes such as `evil-youtube.com` or `youtube.com.evil.com`.
    static func isYouTubeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "youtube.com" || h == "youtu.be" || h == "youtube-nocookie.com" {
            return true
        }
        return h.hasSuffix(".youtube.com") || h.hasSuffix(".youtu.be") || h.hasSuffix(".youtube-nocookie.com")
    }

    /// True when the locator parses as a URL on a genuine YouTube host.
    static func isYouTubeURL(_ locator: String) -> Bool {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let components = URLComponents(string: trimmed) ?? URLComponents(string: "https://\(trimmed)")
        guard let host = components?.host, !host.isEmpty else { return false }
        return isYouTubeHost(host)
    }

    static func videoID(from locator: String) -> String? {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) ?? URLComponents(string: "https://\(trimmed)") else {
            return nil
        }
        // Handle scheme-less locators like "youtu.be/abc".
        if components.host == nil, components.scheme == nil {
            guard let prefixed = URLComponents(string: "https://\(trimmed)") else { return nil }
            components = prefixed
        }
        let host = (components.host ?? "").lowercased()
        guard isYouTubeHost(host) else { return nil }
        let isShort = host == "youtu.be" || host.hasSuffix(".youtu.be")

        let pathParts = components.path.split(separator: "/").map(String.init)
        let queryItems = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == name })?.value
        }

        if isShort {
            if let first = pathParts.first {
                return cleanToken(first)
            }
            return nil
        }

        // youtube.com hosts: ?v= wins (covers /watch and any path carrying it).
        if let v = queryValue("v"), let id = cleanToken(v) {
            return id
        }
        // Path shapes: /shorts/<id>, /embed/<id>, /v/<id>, /live/<id>.
        if pathParts.count >= 2 {
            let head = pathParts[0].lowercased()
            if head == "shorts" || head == "embed" || head == "v" || head == "live" {
                return cleanToken(pathParts[1])
            }
        }
        return nil
    }

    static func dedupeKey(for locator: String) -> String {
        if let id = videoID(from: locator) {
            return "youtube-video:\(id)"
        }
        return "youtube-url:\(normalizedURLString(for: locator))"
    }

    static func normalizedURLString(for locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard var components = URLComponents(string: trimmed) ?? URLComponents(string: "https://\(trimmed)") else {
            return trimmed.lowercased()
        }
        if components.host == nil, components.scheme == nil {
            guard let prefixed = URLComponents(string: "https://\(trimmed)") else {
                return trimmed.lowercased()
            }
            components = prefixed
        }
        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        }
        return components.string ?? trimmed.lowercased()
    }

    /// Valid video tokens use YouTube's ID alphabet; preserve case.
    private static func cleanToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clipped = token.split(separator: "&").first.map(String.init) ?? token
        guard !clipped.isEmpty, clipped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return clipped
    }
}
