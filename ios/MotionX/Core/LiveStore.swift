import Foundation
import Observation

/// Tracks the treadmill state in real time through the Server-Sent Events stream /api/stream,
/// falling back to GET /api/live if the stream drops.
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

    /// Called when the server reports a session (new session received = `id` present).
    @ObservationIgnored var onSessionEvent: ((StreamSession) -> Void)?
    /// Called on every new state received.
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var currentBase: URL?

    var isRunning: Bool { task != nil }

    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45          // the server sends a ping every 15 s
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    func start(api: APIClient?) {
        if task != nil, api?.base == currentBase { return }   // already connected to the same server
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
                // The stream does not get through: at least fetch the last known state.
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

        // The server always sends "event: X" followed by a single "data: {...}" line.
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
