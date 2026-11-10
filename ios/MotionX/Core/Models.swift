import Foundation

// Formats JSON du serveur Node (server.js). Le décodeur convertit les clés snake_case → camelCase.

/// Dernier état envoyé par l'ESP32 (UDP → serveur → SSE).
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
    var receivedAt: Double?      // ms epoch, horloge du serveur
    var from: String?            // IP de l'ESP32 vue par le serveur
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

    /// Le serveur n'a rien reçu de l'ESP32 depuis plus de 20 s (même règle que le tableau de bord web).
    func isStale(now: Date = .now) -> Bool {
        guard let r = receivedAt else { return true }
        return now.timeIntervalSince1970 * 1000 - r > 20_000
    }

    /// Tapis en compte à rebours, en marche ou en décélération.
    var isActive: Bool { signal && state >= 2 }

    var stateLabel: String {
        guard signal else { return "Tapis éteint" }
        switch state {
        case 0: return "Initialisation"
        case 1: return "Veille"
        case 2: return "Compte à rebours"
        case 3: return "En marche"
        case 5: return "Décélération"
        default: return stateName.isEmpty ? "Inconnu" : stateName.capitalized
        }
    }

    /// Adresse de la page web de l'ESP32.
    var deviceURL: URL? {
        let host = (ip?.isEmpty == false ? ip : from) ?? ""
        return host.isEmpty ? nil : URL(string: "http://\(host)")
    }
}

/// Un événement brut de séance : [ms depuis le début, état, vitesse × 10].
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

/// Valeurs recalculées par le serveur à partir des événements.
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

/// Séance à transférer dans Santé (GET /api/health/pending).
struct PendingSession: Decodable {
    var file: String
    var start: String          // ISO 8601 avec décalage, ex. 2026-11-09T21:33:03+01:00
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

// Charges utiles du flux Server-Sent Events /api/stream
struct StreamInit: Decodable { var live: LiveState?; var trace: Trace? }
struct StreamLive: Decodable { var live: LiveState; var point: TracePoint?; var sessionId: Int? }
struct StreamSession: Decodable { var file: String?; var id: Int? }

extension KeyedDecodingContainer {
    /// Décode une valeur, ou renvoie la valeur par défaut si absente / null / mauvais type.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
