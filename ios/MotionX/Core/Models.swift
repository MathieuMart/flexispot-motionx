import Foundation

// JSON formats of the Node server (server.js). The decoder converts snake_case keys → camelCase.

/// Last state sent by the ESP32 (UDP → server → SSE).
struct LiveState: Decodable, Equatable {
    var device: String?
    var fw: String?
    var signal: Bool
    var state: Int
    var stateName: String
    var speedKmh: Double
    var inSession: Bool
    var sessionId: Int
    var sessionMs: Int
    var elapsedS: Int
    var walkS: Int
    var distanceM: Double
    var receivedAt: Double?      // ms epoch, server clock
    var from: String?            // ESP32 IP as seen by the server
    var via: String?
    var ip: String?
    var rssi: Int?
    var stored: Int?
    var pending: Int?

    enum CodingKeys: String, CodingKey {
        case device, fw, signal, state, stateName, speedKmh, inSession, sessionId, sessionMs
        case elapsedS, walkS, distanceM, receivedAt, from, via, ip, rssi, stored, pending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = c.v(.device, nil)
        fw = c.v(.fw, nil)
        signal = c.v(.signal, false)
        state = c.v(.state, 0)
        stateName = c.v(.stateName, "")
        speedKmh = c.v(.speedKmh, 0)
        inSession = c.v(.inSession, false)
        sessionId = c.v(.sessionId, 0)
        sessionMs = c.v(.sessionMs, 0)
        elapsedS = c.v(.elapsedS, 0)
        walkS = c.v(.walkS, 0)
        distanceM = c.v(.distanceM, 0)
        receivedAt = c.v(.receivedAt, nil)
        from = c.v(.from, nil)
        via = c.v(.via, nil)
        ip = c.v(.ip, nil)
        rssi = c.v(.rssi, nil)
        stored = c.v(.stored, nil)
        pending = c.v(.pending, nil)
    }

    /// The server has received nothing from the ESP32 for more than 20 s (same rule as the web dashboard).
    func isStale(now: Date = .now) -> Bool {
        guard let r = receivedAt else { return true }
        return now.timeIntervalSince1970 * 1000 - r > 20_000
    }

    /// Treadmill counting down, walking or decelerating.
    var isActive: Bool { signal && state >= 2 }

    var stateLabel: String {
        guard signal else { return "Treadmill off" }
        switch state {
        case 0: return "Initializing"
        case 1: return "Standby"
        case 2: return "Countdown"
        case 3: return "Walking"
        case 5: return "Slowing down"
        default: return stateName.isEmpty ? "Unknown" : stateName.capitalized
        }
    }

    /// Address of the ESP32 web page.
    var deviceURL: URL? {
        let host = (ip?.isEmpty == false ? ip : from) ?? ""
        return host.isEmpty ? nil : URL(string: "http://\(host)")
    }
}

/// A raw session event: [ms since start, state, speed × 10].
struct TracePoint: Decodable, Hashable {
    let ms: Int
    let state: Int
    let speed10: Int

    init(ms: Int, state: Int, speed10: Int) { self.ms = ms; self.state = state; self.speed10 = speed10 }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        ms = try c.decode(Int.self)
        state = try c.decode(Int.self)
        speed10 = try c.decode(Int.self)
    }

    var seconds: Double { Double(ms) / 1000 }
    var kmh: Double { Double(speed10) / 10 }
}

struct Trace: Decodable {
    var sessionId: Int
    var events: [TracePoint]
}

struct Profile: Decodable, Equatable {
    var heightCm: Double = 175
    var weightKg: Double = 75
}

/// Values recomputed by the server from the events.
struct Computed: Decodable, Hashable {
    var distanceM: Double
    var walkS: Int
    var steps: Int
    var kcal: Int
}

struct SessionSummary: Decodable, Identifiable, Hashable {
    var file: String
    var number: Int
    var device: String?
    var fw: String?
    var start: Int
    var durationS: Int?
    var maxKmh: Double?
    var avgKmh: Double?
    var end: String?
    var startEstimated: Bool?
    var eventsCount: Int?
    var computed: Computed
    var healthSynced: Bool?

    enum CodingKeys: String, CodingKey {
        case file, number = "id", device, fw, start, durationS, maxKmh, avgKmh, end
        case startEstimated, eventsCount, computed, healthSynced
    }

    var id: String { file }
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { startDate.addingTimeInterval(TimeInterval(durationS ?? computed.walkS)) }
}

struct SessionsResponse: Decodable {
    var profile: Profile?
    var sessions: [SessionSummary]
}

struct SessionDetail: Decodable {
    var number: Int
    var start: Int
    var durationS: Int?
    var maxKmh: Double?
    var avgKmh: Double?
    var end: String?
    var startEstimated: Bool?
    var events: [TracePoint]
    var computed: Computed

    enum CodingKeys: String, CodingKey {
        case number = "id", start, durationS, maxKmh, avgKmh, end, startEstimated, events, computed
    }
}

struct LiveResponse: Decodable {
    var live: LiveState?
    var trace: Trace?
    var udpPackets: Int?
}

/// Session to transfer to Health (GET /api/health/pending).
struct PendingSession: Decodable {
    var file: String
    var start: String          // ISO 8601 with offset, e.g. 2026-11-09T21:33:03+01:00
    var end: String
    var durationMin: Double
    var distanceM: Double
    var kcal: Int
    var steps: Int
}

struct PendingResponse: Decodable {
    var count: Int
    var sessions: [PendingSession]
}

struct OKResponse: Decodable { var ok: Bool }

// Payloads of the Server-Sent Events stream /api/stream
struct StreamInit: Decodable { var live: LiveState?; var trace: Trace? }
struct StreamLive: Decodable { var live: LiveState; var point: TracePoint?; var sessionId: Int? }
struct StreamSession: Decodable { var file: String?; var id: Int? }

extension KeyedDecodingContainer {
    /// Decodes a value, or returns the fallback if missing / null / wrong type.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
