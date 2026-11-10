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

/// Profil de vitesse d'une séance (créneaux, comme sur le tableau de bord web).
struct SpeedChart: View {
    struct Point: Identifiable { let id: Int; let t: Double; let v: Double }

    let points: [TracePoint]
    let endMs: Int

    private var series: [Point] {
        var out = points.enumerated().map { Point(id: $0.offset, t: $0.element.seconds, v: $0.element.kmh) }
        if let last = points.last, endMs > last.ms {
            out.append(Point(id: out.count, t: Double(endMs) / 1000, v: last.kmh))
        }
        return out
    }

    var body: some View {
        let data = series
        let vmax = max(4, (data.map(\.v).max() ?? 0).rounded(.up) + 0.5)
        Chart(data) { p in
            AreaMark(x: .value("Temps", p.t), y: .value("km/h", p.v))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Temps", p.t), y: .value("km/h", p.v))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...vmax)
        .chartXScale(domain: 0...max(10, data.last?.t ?? 10))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let s = value.as(Double.self) { Text(Fmt.hms(s)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))") } }
            }
        }
    }
}

struct ServerMissingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Serveur non configuré", systemImage: "server.rack")
        } description: {
            Text("Indique l'adresse de ton serveur MotionX (ex. 192.168.1.20:3000) dans l'onglet Réglages.")
        }
    }
}
