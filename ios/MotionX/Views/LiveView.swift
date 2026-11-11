import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.api == nil {
                    ServerMissingView()
                } else {
                    // Refreshes every second to detect a silent ESP32.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        content(now: ctx.date)
                    }
                }
            }
            .navigationTitle("MotionX")
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let live = model.live.live
        let stale = live?.isStale(now: now) ?? true
        let inSession = (live?.inSession ?? false) && !stale

        ScrollView {
            VStack(spacing: 16) {
                header(live: live, stale: stale)
                speedCard(live: live, stale: stale)

                if inSession, let live {
                    sessionCard(live)
                }
                todayCard(live: inSession ? live : nil)
            }
            .padding()
            .animation(.snappy, value: inSession)
        }
        .refreshable { await model.history.refresh(api: model.api) }
    }

    private func header(live: LiveState?, stale: Bool) -> some View {
        let (text, color): (String, Color) = {
            guard let live else { return ("No data", .gray) }
            if stale { return ("Offline", .orange) }
            return (live.stateLabel, live.isActive ? .green : .gray)
        }()
        return HStack {
            StatusPill(text: text, color: color)
            Spacer()
            connectionLabel
        }
    }

    private var connectionLabel: some View {
        let (text, image): (String, String) = {
            switch model.live.connection {
            case .idle: return ("—", "pause.circle")
            case .connecting: return ("Connecting…", "antenna.radiowaves.left.and.right")
            case .streaming: return ("Real-time", "dot.radiowaves.left.and.right")
            case .polling: return ("Fallback mode", "arrow.clockwise")
            case .failed: return ("Server unreachable", "exclamationmark.triangle")
            }
        }()
        return Label(text, systemImage: image)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func speedCard(live: LiveState?, stale: Bool) -> some View {
        let showSpeed = (live?.signal ?? false) && !stale
        let speed = showSpeed ? live?.speedKmh ?? 0 : 0
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(showSpeed ? Fmt.speed(speed) : "–")
                    .font(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: speed))
                    .animation(.snappy, value: speed)
                Text("km/h").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            Gauge(value: min(speed, 6), in: 0...6) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.accentColor)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func sessionCard(_ live: LiveState) -> some View {
        let est = Estimator.compute(model.live.points, endMs: live.sessionMs, profile: model.history.profile)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Current session").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "Duration", value: Fmt.hms(live.elapsedS), systemImage: "stopwatch")
                StatTile(title: "Walking", value: Fmt.hms(live.walkS), systemImage: "figure.walk", tint: .green)
                StatTile(title: "Distance", value: Fmt.distanceParts(live.distanceM).0, unit: Fmt.distanceParts(live.distanceM).1, systemImage: "point.topleft.down.to.point.bottomright.curvepath", tint: .blue)
                StatTile(title: "Steps ≈", value: Fmt.int(est.steps), systemImage: "shoeprints.fill", tint: .orange)
                StatTile(title: "Calories ≈", value: Fmt.int(est.kcal), unit: "kcal", systemImage: "flame.fill", tint: .red)
                StatTile(title: "Pace", value: live.speedKmh > 0 ? Fmt.hms(3600 / live.speedKmh) : "–", unit: "/km", systemImage: "speedometer", tint: .purple)
            }
            if !model.live.points.isEmpty {
                SpeedChart(points: model.live.points, endMs: live.sessionMs, live: true)
                    .frame(height: 160)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Today = finished sessions + ongoing session.
    private func todayCard(live: LiveState?) -> some View {
        let t = model.history.today
        var dist = t.distanceM, walk = t.walkS, steps = t.steps
        if let live {
            let est = Estimator.compute(model.live.points, endMs: live.sessionMs, profile: model.history.profile)
            dist += live.distanceM; walk += live.walkS; steps += est.steps
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                if let msg = model.health.lastMessage, model.health.isAuthorized {
                    Label(msg, systemImage: "heart.fill")
                        .font(.caption).foregroundStyle(.pink).lineLimit(1)
                }
            }
            HStack(spacing: 12) {
                StatTile(title: "Distance", value: Fmt.distanceParts(dist).0, unit: Fmt.distanceParts(dist).1, systemImage: "map", tint: .blue)
                StatTile(title: "Steps", value: Fmt.int(steps), systemImage: "shoeprints.fill", tint: .orange)
                StatTile(title: "Walking", value: Fmt.duration(walk), systemImage: "clock", tint: .green)
            }
        }
    }
}
