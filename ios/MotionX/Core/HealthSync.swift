import Foundation
import HealthKit
import Observation

/// Transfers the server's sessions to Apple Health (replaces the iOS shortcut).
/// Each session becomes an indoor "Walking" workout with distance, calories and steps.
/// Deduplication: HealthKit sync identifier = session file name.
@MainActor @Observable
final class HealthSync {
    enum HealthError: LocalizedError {
        case unavailable, notAuthorized
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Health is not available on this device"
            case .notAuthorized: return "Health access not authorized (Settings › Health › Data Access & Devices › MotionX)"
            }
        }
    }

    @ObservationIgnored let store = HKHealthStore()

    private(set) var running = false
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "health.lastSync") as? Date
    private(set) var lastMessage: String? = UserDefaults.standard.string(forKey: "health.lastMessage")
    private(set) var authStatus: HKAuthorizationStatus = .notDetermined

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var isAuthorized: Bool { authStatus == .sharingAuthorized }

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(),
         HKQuantityType(.distanceWalkingRunning),
         HKQuantityType(.activeEnergyBurned),
         HKQuantityType(.stepCount)]
    }

    init() { refreshStatus() }

    func refreshStatus() {
        guard isAvailable else { return }
        authStatus = store.authorizationStatus(for: HKObjectType.workoutType())
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: [HKObjectType.workoutType()])
        refreshStatus()
    }

    /// Syncs all pending sessions. Returns the number of workouts created.
    @discardableResult
    func sync(api: APIClient) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        do {
            let n = try await performSync(api: api)
            finish(n == 0 ? "Up to date, nothing new" : "\(n) session\(n > 1 ? "s" : "") added to Health")
            return n
        } catch {
            finish("Failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func finish(_ message: String) {
        lastSync = .now
        lastMessage = message
        UserDefaults.standard.set(lastSync, forKey: "health.lastSync")
        UserDefaults.standard.set(message, forKey: "health.lastMessage")
    }

    private func performSync(api: APIClient) async throws -> Int {
        guard isAvailable else { throw HealthError.unavailable }
        refreshStatus()
        guard isAuthorized else { throw HealthError.notAuthorized }

        var created = 0
        // The server returns at most 20 sessions per call: loop while some remain.
        for _ in 0..<20 {
            let page = try await api.healthPending()
            if page.sessions.isEmpty { break }
            var progressed = false
            for s in page.sessions {
                let syncId = "motionx.\(s.file)"
                if try await !exists(syncId: syncId) {
                    if try await save(s, syncId: syncId) { created += 1 }
                }
                _ = try await api.healthDone(file: s.file)
                progressed = true
            }
            if !progressed || page.sessions.count < 20 { break }
        }
        return created
    }

    private func exists(syncId: String) async throws -> Bool {
        let pred = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncId])
        let q = HKSampleQueryDescriptor(predicates: [.workout(pred)], sortDescriptors: [], limit: 1)
        return try await !q.result(for: store).isEmpty
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func save(_ s: PendingSession, syncId: String) async throws -> Bool {
        guard let start = Self.iso.date(from: s.start), let rawEnd = Self.iso.date(from: s.end) else { return false }
        let end = max(rawEnd, start.addingTimeInterval(max(1, s.durationMin * 60)))

        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        try await builder.beginCollection(at: start)

        var samples: [HKSample] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double) {
            guard value > 0 else { return }
            samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: start, end: end,
                                            metadata: [HKMetadataKeySyncIdentifier: "\(syncId).\(id.rawValue)",
                                                       HKMetadataKeySyncVersion: 1]))
        }
        add(.distanceWalkingRunning, .meter(), s.distanceM)
        add(.activeEnergyBurned, .kilocalorie(), Double(s.kcal))
        add(.stepCount, .count(), Double(s.steps))
        if !samples.isEmpty { try await builder.addSamples(samples) }

        try await builder.addMetadata([
            HKMetadataKeyIndoorWorkout: true,
            HKMetadataKeySyncIdentifier: syncId,
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyWorkoutBrandName: "FlexiSpot MotionX",
        ])
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
        return true
    }
}
