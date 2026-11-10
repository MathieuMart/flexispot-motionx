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

    /// Keeps the app awake on the Lock Screen during a session (silent audio).
    var keepAwake: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateActivity() }
    }

    var api: APIClient? { APIClient(urlString: serverURL) }

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?

    private init() {
        live.onSessionEvent = { [weak self] ev in self?.sessionEvent(ev) }
        live.onUpdate = { [weak self] in self?.updateActivity() }
        // Detects an ESP32 that went silent even when no new packet arrives.
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
            if !isActive { live.stop() }       // nothing left to track: let iOS suspend the app
        }
    }

    func setServer(_ url: String) {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        if isActive { live.start(api: api) }
        Task { await history.refresh(api: api) }
    }

    // MARK: lifecycle

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
        // During a session, the silent audio keeps the app awake: keep the stream open.
        if !keeper.isRunning { live.stop() }
        scheduleBackgroundRefresh()
    }

    // MARK: Health sync

    func syncHealthNow() async {
        guard let api else { return }
        await health.sync(api: api)
        await history.refresh(api: api)
    }

    private func autoSync() async {
        guard autoHealthSync, health.isAuthorized else { return }
        await syncHealthNow()
    }

    /// The server announces a session: a new session from the ESP32 (with `id`) or a session marked as transferred.
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

    // MARK: background refresh

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
