import ActivityKit
import Foundation

/// Live Activity for a treadmill session (Lock Screen + Dynamic Island).
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Double
        var distanceM: Double
        var steps: Int
        var kcal: Int
        var walkS: Int
        var stateLabel: String
        /// Belt is moving: the timer ticks on its own, even without an update from the app.
        var moving: Bool
        /// Virtual start of the walking timer (= now − walking time) for Text(timerInterval:).
        var walkTimerStart: Date
        var updatedAt: Date
        var ended: Bool
    }

    var sessionId: Int
    var startedAt: Date
}
