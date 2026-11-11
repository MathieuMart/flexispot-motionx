import Charts
import SwiftUI

struct StatTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// Speed profile of a session (stepped, as on the web dashboard).
struct SpeedChart: View {
    struct Point: Identifiable { let id: Int; let t: Double; let v: Double }

    let points: [TracePoint]
    let endMs: Int
    /// Session in progress: the speed being walked right now always stays in view.
    var live = false

    /// Same vertical axis as the web dashboard (speedScale in dashboard.html): zoomed on the speeds that were
    /// really walked, so that going from 3.0 to 3.5 km/h stays readable on a one-hour session.
    private var scale: (lo: Double, hi: Double, step: Double) {
        var lo = Double.infinity, hi = 0.0, cur = 0.0
        for (i, p) in points.enumerated() {
            let isLast = i + 1 == points.count
            let next = isLast ? endMs : points[i + 1].ms
            guard next > p.ms, p.kmh > 0 else { continue }
            hi = max(hi, p.kmh)
            if next - p.ms >= 5000 { lo = min(lo, p.kmh) }           // a speed that was held, not a step of a ramp
            else if live, isLast, p.state == 3 { cur = p.kmh }
        }
        guard hi > 0 else { return (0, 2, 1) }
        if lo > hi { lo = 0 } else if cur > 0 { lo = min(lo, cur) }  // nothing held yet: plain 0-based axis
        var a = lo - max(0.2, (hi - lo) * 0.1), b = hi
        if b - a < 1 { let m = (a + b) / 2; a = m - 0.5; b = m + 0.5 }
        if a < 1 { a = 0 }
        let step = b - a <= 2 ? 0.5 : b - a <= 5 ? 1.0 : 2.0
        return ((a / step + 1e-9).rounded(.down) * step, (b / step - 1e-9).rounded(.up) * step, step)
    }

    /// Speeds below the axis (start and stop ramps, pauses) are drawn on its bottom edge.
    private func series(from lo: Double) -> [Point] {
        var out = points.enumerated().map { Point(id: $0.offset, t: $0.element.seconds, v: max(lo, $0.element.kmh)) }
        if let last = points.last, endMs > last.ms {
            out.append(Point(id: out.count, t: Double(endMs) / 1000, v: max(lo, last.kmh)))
        }
        return out
    }

    var body: some View {
        let s = scale
        let data = series(from: s.lo)
        Chart(data) { p in
            AreaMark(x: .value("Time", p.t), yStart: .value("km/h", s.lo), yEnd: .value("km/h", p.v))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", p.t), y: .value("km/h", p.v))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: s.lo...s.hi)
        .chartXScale(domain: 0...max(10, data.last?.t ?? 10))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let t = value.as(Double.self) { Text(Fmt.hms(t)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: s.lo, through: s.hi + 1e-9, by: s.step))) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(v.formatted(.number.precision(.fractionLength(0...1)))) } }
            }
        }
    }
}

struct ServerMissingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Server not configured", systemImage: "server.rack")
        } description: {
            Text("Enter the address of your MotionX server (e.g. 192.168.1.20:3000) in the Settings tab.")
        }
    }
}
