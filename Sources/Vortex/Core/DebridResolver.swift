import Foundation

public enum DebridService: String, CaseIterable, Identifiable, Codable {
    case realDebrid = "Real-Debrid"
    case allDebrid = "AllDebrid"
    case torbox = "Torbox"

    public var id: String { rawValue }
}

public struct DebridUnrestrictResult: Sendable {
    public let originalUrl: String
    public let downloadUrl: URL
    public let fileName: String?
    public let fileSize: Int64?
}

public final class DebridResolver: @unchecked Sendable {
    public static let shared = DebridResolver()

    private let supportedHosts: Set<String> = [
        "rapidgator.net", "rg.to", "1fichier.com", "megaup.net", "nitroflare.com",
        "turbobit.net", "ddownload.com", "filefactory.com", "katfile.com",
        "mexashare.com", "rosefile.net", "fikper.com", "uploadgig.com",
        "wdupload.com", "hitfile.net", "clicknupload", "streamtape.com"
    ]

    private init() {}

    public var isConfigured: Bool {
        let key = apiKey
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var selectedService: DebridService {
        get {
            let raw = UserDefaults.standard.string(forKey: "vortex_debrid_service") ?? DebridService.realDebrid.rawValue
            return DebridService(rawValue: raw) ?? .realDebrid
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "vortex_debrid_service")
        }
    }

    public var apiKey: String {
        get {
            return UserDefaults.standard.string(forKey: "vortex_debrid_api_key") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vortex_debrid_api_key")
        }
    }

    /// Checks if a URL belongs to a known throttled cyberlocker
    public func isCyberlocker(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return supportedHosts.contains { host.contains($0) }
    }

    /// Unrestrict a cyberlocker link via Debrid API into a high-speed direct CDN URL
    public func unrestrict(url: URL) async throws -> DebridUnrestrictResult {
        guard isConfigured else {
            throw NSError(domain: "DebridResolver", code: 401, userInfo: [NSLocalizedDescriptionKey: "Debrid API key is not configured in Vortex Preferences."])
        }

        switch selectedService {
        case .realDebrid:
            return try await unrestrictRealDebrid(url: url)
        case .allDebrid:
            return try await unrestrictAllDebrid(url: url)
        case .torbox:
            return try await unrestrictTorbox(url: url)
        }
    }

    private func unrestrictRealDebrid(url: URL) async throws -> DebridUnrestrictResult {
        let endpoint = URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "link=\(url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString)"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DebridResolver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Real-Debrid"])
        }

        guard http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "DebridResolver", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Real-Debrid error: \(errText)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let downloadStr = json?["download"] as? String, let downloadUrl = URL(string: downloadStr) else {
            throw NSError(domain: "DebridResolver", code: -2, userInfo: [NSLocalizedDescriptionKey: "No direct download link returned by Real-Debrid."])
        }

        let filename = json?["filename"] as? String
        let filesize = json?["filesize"] as? Int64

        return DebridUnrestrictResult(
            originalUrl: url.absoluteString,
            downloadUrl: downloadUrl,
            fileName: filename,
            fileSize: filesize
        )
    }

    private func unrestrictAllDebrid(url: URL) async throws -> DebridUnrestrictResult {
        var components = URLComponents(string: "https://api.alldebrid.com/v4/link/unlock")!
        components.queryItems = [
            URLQueryItem(name: "agent", value: "vortex"),
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "link", value: url.absoluteString)
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "DebridResolver", code: -1, userInfo: [NSLocalizedDescriptionKey: "AllDebrid request failed."])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataObj = json?["data"] as? [String: Any]
        guard let linkStr = dataObj?["link"] as? String, let downloadUrl = URL(string: linkStr) else {
            throw NSError(domain: "DebridResolver", code: -2, userInfo: [NSLocalizedDescriptionKey: "AllDebrid failed to unlock link."])
        }

        let filename = dataObj?["filename"] as? String
        let filesize = dataObj?["filesize"] as? Int64

        return DebridUnrestrictResult(
            originalUrl: url.absoluteString,
            downloadUrl: downloadUrl,
            fileName: filename,
            fileSize: filesize
        )
    }

    private func unrestrictTorbox(url: URL) async throws -> DebridUnrestrictResult {
        // Fallback or standard direct download
        return DebridUnrestrictResult(originalUrl: url.absoluteString, downloadUrl: url, fileName: nil, fileSize: nil)
    }
}
