import Foundation

// Shared between the app and the Live Activity extension.
enum Fmt {
    /// 754 → "12:34", 3723 → "1:02:03"
    static func hms(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
    static func hms(_ seconds: Int) -> String { hms(Double(seconds)) }

    /// 740 → "740 m", 1234 → "1.23 km"
    static func distance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded())) m" : (m / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }

    static func km(_ m: Double) -> String { (m / 1000).formatted(.number.precision(.fractionLength(2))) }

    /// Value + unit split for the tiles: (740, "m") or ("1.23", "km")
    static func distanceParts(_ m: Double) -> (String, String) {
        m < 1000 ? ("\(Int(m.rounded()))", "m") : (km(m), "km")
    }

    static func int(_ n: Int) -> String { n.formatted(.number) }

    static func speed(_ kmh: Double) -> String { kmh.formatted(.number.precision(.fractionLength(1))) }

    /// "1 h 05" or "42 min"
    static func duration(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }
}
