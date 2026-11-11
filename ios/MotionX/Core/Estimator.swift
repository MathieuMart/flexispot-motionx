import Foundation

/// Exact copy of the formulas in server.js (strideMeters, kcalPerMin, compute),
/// to estimate steps and calories during the ongoing session.
enum Estimator {
    static func strideMeters(_ kmh: Double, _ p: Profile) -> Double {
        let base = p.heightCm * 0.00414
        let factor = min(1.1, max(0.6, 0.6 + 0.08 * kmh))
        return base * factor / (p.stepFactor ?? 1)
    }

    static func kcalPerMin(_ kmh: Double, _ p: Profile) -> Double {
        guard kmh > 0 else { return 0 }
        let met = kmh < 3.2 ? 2.0 + 0.25 * kmh : 2.8 + 0.9 * (kmh - 3.2)
        return met * 3.5 * p.weightKg / 200
    }

    static func compute(_ ev: [TracePoint], endMs: Int, profile p: Profile) -> Computed {
        var dist = 0.0, steps = 0.0, kcal = 0.0, walkMs = 0.0
        for (i, e) in ev.enumerated() {
            let tNext = i + 1 < ev.count ? ev[i + 1].ms : max(endMs, e.ms)
            let dt = Double(max(0, tNext - e.ms)) / 1000
            let kmh = e.kmh
            if kmh > 0 && dt > 0 {
                let d = kmh / 3.6 * dt
                dist += d
                walkMs += dt * 1000
                steps += d / strideMeters(kmh, p)
                kcal += kcalPerMin(kmh, p) * dt / 60
            }
        }
        return Computed(distanceM: (dist * 10).rounded() / 10, walkS: Int((walkMs / 1000).rounded()),
                        steps: Int(steps.rounded()), kcal: Int(kcal.rounded()))
    }
}
