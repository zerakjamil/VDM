import Foundation
import Network

public struct AddDownloadPayload: Codable, Sendable {
    public let url: String
    public let referrer: String?
    public let filename: String?
    public let cookies: String?
    public let userAgent: String?
    public let segments: Int?
}

public struct RefreshDownloadPayload: Codable, Sendable {
    public let taskId: String?
    public let originalUrl: String?
    public let filename: String?
    public let newUrl: String
    public let cookies: String?
    public let userAgent: String?
}

public struct TaskActionPayload: Codable, Sendable {
    public let id: String?
}

public struct BoostPayload: Codable, Sendable {
    public let id: String?
    public let streams: Int?
}

public final class VortexServer: @unchecked Sendable {
    public static let shared = VortexServer()
    public static var port: UInt16 = 17890
    public private(set) var activePort: UInt16 = 17890

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.vortex.server", qos: .userInitiated)
    private var isRunning = false

    public var onAddDownload: (@MainActor (URL, URL?, String?, [String: String], Int) -> Void)?
    public var onRefreshDownload: (@MainActor (String?, String?, String?, URL, String?) async -> Data?)?
    public var onCheckStatus: (@MainActor () -> [String: Any])?
    public var onListDownloads: (@MainActor () -> [[String: Any]])?
    public var onResumeTask: (@MainActor (String?) -> Void)?
    public var onPauseTask: (@MainActor (String?) -> Void)?
    public var onBoostTask: (@MainActor (String?, Int) -> Void)?
    public var onRecycleConnections: (@MainActor (String?) -> Void)?

    public init() {}

    public func start(port: UInt16 = VortexServer.port) {
        guard !isRunning else { return }
        self.activePort = port

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[VortexServer] IPC Server listening on http://127.0.0.1:\(Self.port)")
                case .failed(let error):
                    print("[VortexServer] Failed to listen on port \(Self.port): \(error)")
                default:
                    break
                }
            }

            listener.start(queue: queue)
            isRunning = true
        } catch {
            print("[VortexServer] Error starting server: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHttpRequest(connection: connection, accumulated: Data())
    }

    private func readHttpRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var current = accumulated
            if let data = data {
                current.append(data)
            }

            // Check if headers delimiter exists
            guard let headerEndRange = current.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readHttpRequest(connection: connection, accumulated: current)
                }
                return
            }

            let headerData = current.subdata(in: 0..<headerEndRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid headers")
                return
            }

            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                self.sendResponse(connection: connection, status: "400 Bad Request", body: "Empty request")
                return
            }

            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.sendResponse(connection: connection, status: "400 Bad Request", body: "Malformed request")
                return
            }

            let method = parts[0].uppercased()
            let path = parts[1]

            // Handle CORS preflight
            if method == "OPTIONS" {
                self.sendCorsPreflight(connection: connection)
                return
            }

            // Parse Content-Length for POST body
            var contentLength = 0
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(val) ?? 0
                }
            }

            let bodyStart = headerEndRange.upperBound
            let bodyBytesAvailable = current.count - bodyStart

            if bodyBytesAvailable < contentLength {
                // Need more data
                self.readRemainingBody(connection: connection, accumulated: current, expectedTotal: bodyStart + contentLength)
                return
            }

            let bodyData = current.subdata(in: bodyStart..<(bodyStart + contentLength))
            self.routeRequest(connection: connection, method: method, path: path, body: bodyData)
        }
    }

    private func readRemainingBody(connection: NWConnection, accumulated: Data, expectedTotal: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var current = accumulated
            if let data = data {
                current.append(data)
            }

            if current.count >= expectedTotal {
                // Find headers end again
                if let headerEndRange = current.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = current.subdata(in: 0..<headerEndRange.lowerBound)
                    let headerString = String(data: headerData, encoding: .utf8) ?? ""
                    let lines = headerString.components(separatedBy: "\r\n")
                    let parts = lines.first?.components(separatedBy: " ") ?? []
                    let method = parts.count >= 2 ? parts[0].uppercased() : "GET"
                    let path = parts.count >= 2 ? parts[1] : "/"

                    let bodyData = current.subdata(in: headerEndRange.upperBound..<expectedTotal)
                    self.routeRequest(connection: connection, method: method, path: path, body: bodyData)
                }
            } else {
                self.readRemainingBody(connection: connection, accumulated: current, expectedTotal: expectedTotal)
            }
        }
    }

    private func routeRequest(connection: NWConnection, method: String, path: String, body: Data) {
        let cleanPath = path.components(separatedBy: "?").first ?? path

        switch (method, cleanPath) {
        case ("GET", "/status"), ("GET", "/health"):
            Task { @MainActor in
                let info = self.onCheckStatus?() ?? ["status": "ok", "app": "Vortex", "version": "1.0.0"]
                let jsonData = (try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)) ?? Data("{\"status\":\"ok\"}".utf8)
                self.sendJsonResponse(connection: connection, data: jsonData)
            }

        case ("GET", "/downloads"):
            Task { @MainActor in
                let list = self.onListDownloads?() ?? []
                let jsonData = (try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted)) ?? Data("[]".utf8)
                self.sendJsonResponse(connection: connection, data: jsonData)
            }

        case ("POST", "/download"):
            do {
                let payload = try JSONDecoder().decode(AddDownloadPayload.self, from: body)
                guard let url = URL(string: payload.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid URL\"}")
                    return
                }

                let pageUrl = payload.referrer.flatMap { URL(string: $0) }
                var headers: [String: String] = [:]
                if let ua = payload.userAgent, !ua.isEmpty {
                    headers["User-Agent"] = ua
                }
                if let ref = payload.referrer, !ref.isEmpty {
                    headers["Referer"] = ref
                }
                if let cookies = payload.cookies, !cookies.isEmpty {
                    headers["Cookie"] = cookies
                }

                let segments = payload.segments ?? 8

                Task { @MainActor in
                    self.onAddDownload?(url, pageUrl, payload.filename, headers, segments)
                    let resp = "{\"success\":true,\"message\":\"Download added to Vortex\"}"
                    self.sendJsonResponse(connection: connection, data: Data(resp.utf8))
                }
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Failed to parse JSON payload: \(error.localizedDescription)\"}")
            }

        case ("POST", "/refresh"):
            do {
                let payload = try JSONDecoder().decode(RefreshDownloadPayload.self, from: body)
                guard let newUrl = URL(string: payload.newUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid new URL\"}")
                    return
                }

                Task { @MainActor in
                    if let responseData = await self.onRefreshDownload?(payload.taskId, payload.originalUrl, payload.filename, newUrl, payload.cookies) {
                        self.sendJsonResponse(connection: connection, data: responseData)
                    } else {
                        self.sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No matching expired download found to refresh\"}")
                    }
                }
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Failed to parse JSON payload: \(error.localizedDescription)\"}")
            }

        case ("POST", "/resume"):
            let payload = try? JSONDecoder().decode(TaskActionPayload.self, from: body)
            Task { @MainActor in
                self.onResumeTask?(payload?.id)
                let resp = "{\"success\":true,\"message\":\"Resume command processed\"}"
                self.sendJsonResponse(connection: connection, data: Data(resp.utf8))
            }

        case ("POST", "/pause"):
            let payload = try? JSONDecoder().decode(TaskActionPayload.self, from: body)
            Task { @MainActor in
                self.onPauseTask?(payload?.id)
                let resp = "{\"success\":true,\"message\":\"Pause command processed\"}"
                self.sendJsonResponse(connection: connection, data: Data(resp.utf8))
            }

        case ("POST", "/boost"):
            let payload = try? JSONDecoder().decode(BoostPayload.self, from: body)
            let streams = payload?.streams ?? 48
            Task { @MainActor in
                self.onBoostTask?(payload?.id, streams)
                let resp = "{\"success\":true,\"message\":\"Boosted to \(streams) streams\"}"
                self.sendJsonResponse(connection: connection, data: Data(resp.utf8))
            }

        case ("POST", "/recycle"):
            let payload = try? JSONDecoder().decode(TaskActionPayload.self, from: body)
            Task { @MainActor in
                self.onRecycleConnections?(payload?.id)
                let resp = "{\"success\":true,\"message\":\"Connections recycled with fresh sockets\"}"
                self.sendJsonResponse(connection: connection, data: Data(resp.utf8))
            }

        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Endpoint not found\"}")
        }
    }

    private func sendCorsPreflight(connection: NWConnection) {
        let response = "HTTP/1.1 204 No Content\r\n" +
                       "Access-Control-Allow-Origin: *\r\n" +
                       "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                       "Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With\r\n" +
                       "Access-Control-Max-Age: 86400\r\n" +
                       "Content-Length: 0\r\n" +
                       "Connection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJsonResponse(connection: NWConnection, data: Data) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Type: application/json\r\n" +
                      "Content-Length: \(data.count)\r\n" +
                      "Connection: close\r\n\r\n"
        var packet = Data(headers.utf8)
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(status)\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Type: application/json\r\n" +
                      "Content-Length: \(bodyData.count)\r\n" +
                      "Connection: close\r\n\r\n"
        var packet = Data(headers.utf8)
        packet.append(bodyData)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
