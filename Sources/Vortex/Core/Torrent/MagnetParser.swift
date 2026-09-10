import Foundation

public struct MagnetMetadata: Sendable {
    public let rawUri: String
    public let infoHash: String // hex 40 chars
    public let displayName: String
    public let trackers: [URL]
}

public struct MagnetParser {
    public static func parse(uri: String) -> MagnetMetadata? {
        guard let url = URL(string: uri), url.scheme?.lowercased() == "magnet" else {
            return nil
        }

        guard let components = URLComponents(string: uri), let queryItems = components.queryItems else {
            return nil
        }

        // xt: urn:btih:<hash>
        guard let xt = queryItems.first(where: { $0.name == "xt" })?.value else {
            return nil
        }

        var hash = xt.replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
        if hash.count == 32 {
            // Base32 encoded sha1 -> convert or retain
            hash = hash.uppercased()
        }

        let dn = queryItems.first(where: { $0.name == "dn" })?.value?.removingPercentEncoding ?? "Torrent_\(hash.prefix(8))"
        let trList = queryItems.filter { $0.name == "tr" }.compactMap { $0.value }.compactMap { URL(string: $0) }

        return MagnetMetadata(
            rawUri: uri,
            infoHash: hash,
            displayName: dn,
            trackers: trList
        )
    }
}
