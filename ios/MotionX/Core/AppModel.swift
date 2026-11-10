import BackgroundTasks
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    static let refreshTaskId = "ch.perso.motionx.sync"

    let live = LiveStore()
    let history = SessionsStore()
    let health = HealthSync()
    @ObservationIgnored let activities = LiveActivityController()
    @ObservationIgnored let keeper = BackgroundKeeper()

    private(set) var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""

    var autoHealthSync: Bool = UserDefaults.standard.object(forKey: "autoHealthSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoHealthSync, forKey: "autoHealthSync") }
    }

    var liveActivityEnabled: Bool = UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivity"); updateActivity() }
    }

    /// Garde l'app éveillée écran verrouillé pendant une séance (audio silencieux).
    var keepAwake: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateActivity() }
    }

    var api: APIClient? { APIClient(urlString: serverURL) }

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?

    private init() {
        live.onSessionEvent = { [weak self] ev in self?.sessionEvent(ev) }
        live.onUpdate = { [weak self] in self?.updateActivity() }
        // Détecte un ESP32 devenu silencieux même sans nouveau paquet.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                self?.updateActivity()
            }
        }
    }

    // MARK: Live Activity

    private func updateActivity() {
        activities.sync(live: live.live, points: live.points, profile: history.profile,
                        enabled: liveActivityEnabled, canStart: isActive)
        if keepAwake && activities.isRunning {
            keeper.start()
        } else if keeper.isRunning {
            keeper.stop()
            if !isActive { live.stop() }       // plus rien à suivre : on laisse iOS suspendre l'app
        }
    }

    func setServer(_ url: String) {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        if isActive { live.start(api: api) }
        Task { await history.refresh(api: api) }
    }

    // MARK: cycle de vie

    func becameActive() {
        isActive = true
        health.refreshStatus()
        live.start(api: api)
        Task {
            await history.refresh(api: api)
            await autoSync()
        }
    }

    func wentToBackground() {
        isActive = false
        // Pendant une séance, l'audio silencieux garde l'app éveillée : on garde le flux ouvert.
        if !keeper.isRunning { live.stop() }
        scheduleBackgroundRefresh()
    }

    // MARK: synchro Santé

    func syncHealthNow() async {
        guard let api else { return }
        await health.sync(api: api)
        await history.refresh(api: api)
    }

    private func autoSync() async {
        guard autoHealthSync, health.isAuthorized else { return }
        await syncHealthNow()
    }

    /// Le serveur annonce une séance : nouvelle séance de l'ESP32 (avec `id`) ou séance marquée transférée.
    private func sessionEvent(_ ev: StreamSession) {
        refreshDebounce?.cancel()
        let isNew = ev.id != nil
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if isNew { await self.autoSync() }
            await self.history.refresh(api: self.api)
        }
    }

    // MARK: rafraîchissement en arrière-plan

    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await autoSync()
    }
}
