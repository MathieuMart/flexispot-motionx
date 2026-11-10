import Foundation
import Observation

@MainActor @Observable
final class SessionsStore {
    private(set) var sessions: [SessionSummary] = []
    private(set) var profile = Profile()
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedOnce = false

    func refresh(api: APIClient?) async {
        guard let api else { sessions = []; error = nil; return }
        loading = true
        defer { loading = false }
        do {
            let r = try await api.sessions()
            sessions = r.sessions.sorted { $0.start > $1.start }
            if let p = r.profile { profile = p }
            error = nil
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
        loadedOnce = true
    }

    struct Totals { var distanceM = 0.0; var walkS = 0; var steps = 0; var kcal = 0; var count = 0 }

    func totals(since date: Date) -> Totals {
        sessions.filter { $0.startDate >= date }.reduce(into: Totals()) { t, s in
            t.distanceM += s.computed.distanceM
            t.walkS += s.computed.walkS
            t.steps += s.computed.steps
            t.kcal += s.computed.kcal
            t.count += 1
        }
    }

    var today: Totals { totals(since: Calendar.current.startOfDay(for: .now)) }

    struct DayTotal: Identifiable { var day: Date; var distanceM: Double; var steps: Int; var id: Date { day } }

    /// Distance per day over the last `days` days (empty days included).
    func daily(days: Int = 7) -> [DayTotal] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<days).reversed().compactMap { offset -> DayTotal? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            let list = sessions.filter { $0.startDate >= day && $0.startDate < next }
            return DayTotal(day: day, distanceM: list.reduce(0) { $0 + $1.computed.distanceM },
                            steps: list.reduce(0) { $0 + $1.computed.steps })
        }
    }

    /// Sessions grouped by day, most recent first.
    var byDay: [(day: Date, sessions: [SessionSummary])] {
        let groups = Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.startDate) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.start > $1.start }) }
    }
}
