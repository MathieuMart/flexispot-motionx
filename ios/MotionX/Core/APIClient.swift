import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int)
    case streamClosed

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server address"
        case .http(let code): return "The server responded with \(code)"
        case .streamClosed: return "Real-time stream closed"
        }
    }
}

/// HTTP client for the MotionX server (server.js on the NAS).
struct APIClient {
    let base: URL

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Accepts "192.168.1.20:3000", "nas.local:3000", "http://…", with or without a trailing "/".
    init?(urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        base = url
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 10) async throws -> T {
        var req = URLRequest(url: url(path, query: query))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw APIError.http(http.statusCode) }
        return try Self.decoder.decode(T.self, from: data)
    }

    func live() async throws -> LiveResponse { try await get("/api/live") }
    func sessions() async throws -> SessionsResponse { try await get("/api/sessions") }
    func session(file: String) async throws -> SessionDetail {
        let safe = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return try await get("/api/sessions/" + safe)
    }
    func healthPending() async throws -> PendingResponse { try await get("/api/health/pending") }
    func healthDone(file: String) async throws -> OKResponse {
        try await get("/api/health/done", query: [URLQueryItem(name: "file", value: file)])
    }
}
