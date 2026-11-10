import ActivityKit
import Foundation

/// Démarre, met à jour et termine la Live Activity à partir de l'état temps réel.
/// Sans push (compte Personal Team), c'est l'app qui pousse chaque mise à jour.
@MainActor
final class LiveActivityController {
    private typealias State = WalkActivityAttributes.ContentState

    private var activity: Activity<WalkActivityAttributes>?
    private var last: State?
    private var lastPush = Date.distantPast

    var isRunning: Bool { activity != nil }

    /// - canStart : l'app est au premier plan (iOS n'autorise le démarrage qu'à ce moment-là).
    func sync(live: LiveState?, points: [TracePoint], profile: Profile, enabled: Bool, canStart: Bool) {
        guard enabled else { endAll(); return }

        guard let live, live.inSession, !live.isStale() else {
            if let last { end(final: last) }          // séance terminée ou ESP32 silencieux
            else if live != nil { endAll() }          // activité restée d'un lancement précédent
            return
        }

        let est = Estimator.compute(points, endMs: live.sessionMs, profile: profile)
        let now = Date()
        var timerStart = now.addingTimeInterval(-TimeInterval(live.walkS))
        // Évite que le chrono saute d'une seconde à chaque paquet.
        if let prev = last?.walkTimerStart, abs(prev.timeIntervalSince(timerStart)) < 2 { timerStart = prev }

        let state = State(speedKmh: live.speedKmh, distanceM: live.distanceM, steps: est.steps, kcal: est.kcal,
                          walkS: live.walkS, stateLabel: live.stateLabel, moving: live.speedKmh > 0,
                          walkTimerStart: timerStart, updatedAt: now, ended: false)

        if activity == nil {
            activity = Activity<WalkActivityAttributes>.activities.first { $0.attributes.sessionId == live.sessionId }
            // Restes d'une séance précédente
            for a in Activity<WalkActivityAttributes>.activities where a.id != activity?.id {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }

        if activity == nil {
            guard canStart, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = WalkActivityAttributes(sessionId: live.sessionId,
                                               startedAt: now.addingTimeInterval(-TimeInterval(live.elapsedS)))
            activity = try? Activity.request(attributes: attrs, content: content(state), pushType: nil)
            last = state; lastPush = now
            return
        }

        // Mise à jour immédiate si la vitesse ou l'état change, sinon toutes les 5 s (distance, pas).
        let changed = last?.speedKmh != state.speedKmh || last?.stateLabel != state.stateLabel
        guard changed || now.timeIntervalSince(lastPush) >= 5 else { return }
        last = state; lastPush = now
        let a = activity
        Task { await a?.update(content(state)) }
    }

    private func content(_ s: State) -> ActivityContent<State> {
        ActivityContent(state: s, staleDate: s.updatedAt.addingTimeInterval(45))
    }

    private func end(final s: State) {
        var f = s
        f.ended = true; f.moving = false; f.speedKmh = 0; f.updatedAt = .now
        let a = activity
        activity = nil; last = nil
        Task { await a?.end(ActivityContent(state: f, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(10 * 60))) }
    }

    func endAll() {
        activity = nil; last = nil
        // Seulement les activités en cours : le résumé d'une séance finie reste affiché 10 min.
        for a in Activity<WalkActivityAttributes>.activities where a.activityState == .active {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
