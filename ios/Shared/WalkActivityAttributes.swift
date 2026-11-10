import ActivityKit
import Foundation

/// Live Activity d'une séance de tapis (écran verrouillé + Dynamic Island).
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Double
        var distanceM: Double
        var steps: Int
        var kcal: Int
        var walkS: Int
        var stateLabel: String
        /// Bande en mouvement : le chrono avance tout seul, même sans mise à jour de l'app.
        var moving: Bool
        /// Début virtuel du chrono de marche (= maintenant − temps de marche) pour Text(timerInterval:).
        var walkTimerStart: Date
        var updatedAt: Date
        var ended: Bool
    }

    var sessionId: Int
    var startedAt: Date
}
