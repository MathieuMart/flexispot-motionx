import Foundation
import Observation

/// Suit l'état du tapis en temps réel via le flux Server-Sent Events /api/stream,
/// avec repli sur GET /api/live si le flux tombe.
@MainActor @Observable
final class LiveStore {
    enum Connection: Equatable {
        case idle, connecting, streaming, polling
        case failed(String)
    }

    private(set) var live: LiveState?
    private(set) var points: [TracePoint] = []
    private(set) var traceSessionId = 0
    private(set) var connection: Connection = .idle

    /// Appelé quand le serveur signale une séance (nouvelle séance reçue = `id` présent).
    @ObservationIgnored var onSessionEvent: ((StreamSession) -> Void)?
    /// Appelé à chaque nouvel état reçu.
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var currentBase: URL?

    var isRunning: Bool { task != nil }

    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45          // le serveur envoie un ping toutes les 15 s
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    func start(api: APIClient?) {
        if task != nil, api?.base == currentBase { return }   // déjà connecté au même serveur
        stop()
        guard let api else { connection = .idle; return }
        currentBase = api.base
        task = Task { [weak self] in await self?.run(api) }
    }

    func stop() {
        task?.cancel()
        task = nil
        currentBase = nil
        if connection != .idle { connection = .idle }
    }

    private func run(_ api: APIClient) async {
        while !Task.isCancelled {
            connection = .connecting
            do {
                try await stream(api)
            } catch {
                if Task.isCancelled { return }
                // Le flux ne passe pas : on récupère au moins le dernier état connu.
                if let r = try? await api.live() {
                    apply(live: r.live, trace: r.trace)
                    connection = .polling
                } else {
                    connection = .failed(error.localizedDescription)
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func stream(_ api: APIClient) async throws {
        var req = URLRequest(url: api.url("/api/stream"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw APIError.http(http.statusCode) }

        // Le serveur envoie toujours "event: X" puis une seule ligne "data: {...}".
        var event = "message"
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                handle(event: event, data: payload)
                event = "message"
            }
        }
        throw APIError.streamClosed
    }

    private func handle(event: String, data: Data) {
        let dec = APIClient.decoder
        switch event {
        case "init":
            guard let d = try? dec.decode(StreamInit.self, from: data) else { return }
            apply(live: d.live, trace: d.trace)
            connection = .streaming
        case "live":
            guard let d = try? dec.decode(StreamLive.self, from: data) else { return }
            live = d.live
            if let sid = d.sessionId, sid != traceSessionId { traceSessionId = sid; points = [] }
            if let p = d.point { points.append(p) }
            connection = .streaming
            onUpdate?()
        case "session":
            let d = (try? dec.decode(StreamSession.self, from: data)) ?? StreamSession()
            onSessionEvent?(d)
        default:
            break
        }
    }

    private func apply(live: LiveState?, trace: Trace?) {
        self.live = live
        if let trace { traceSessionId = trace.sessionId; points = trace.events }
        onUpdate?()
    }
}
