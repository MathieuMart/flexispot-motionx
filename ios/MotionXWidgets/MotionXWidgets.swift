import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MotionXWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WalkLiveActivity()
    }
}

private let accent = Color(red: 0.20, green: 0.82, blue: 0.38)

struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let st = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(st.ended ? "Terminé" : st.stateLabel, systemImage: "figure.walk")
                            .font(.caption).foregroundStyle(accent)
                        SpeedText(state: st, size: 34)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Marche").font(.caption).foregroundStyle(.secondary)
                        WalkTimer(state: st)
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Metric(value: Fmt.distanceParts(st.distanceM).0, unit: Fmt.distanceParts(st.distanceM).1, icon: "map")
                        Spacer()
                        Metric(value: Fmt.int(st.steps), unit: "pas", icon: "shoeprints.fill")
                        Spacer()
                        Metric(value: Fmt.int(st.kcal), unit: "kcal", icon: "flame.fill")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "figure.walk").foregroundStyle(accent)
                    Text(Fmt.speed(st.speedKmh)).monospacedDigit()
                }
            } compactTrailing: {
                WalkTimer(state: st)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(accent)
            } minimal: {
                Text(Fmt.speed(st.speedKmh))
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

/// Chrono de marche : avance tout seul tant que la bande tourne, figé sinon.
struct WalkTimer: View {
    let state: WalkActivityAttributes.ContentState

    var body: some View {
        if state.moving && !state.ended {
            Text(timerInterval: state.walkTimerStart...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Fmt.hms(state.walkS))
        }
    }
}

struct SpeedText: View {
    let state: WalkActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Fmt.speed(state.speedKmh))
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            Text("km/h").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Metric: View {
    let value: String
    let unit: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(accent)
            Text(value).font(.headline.monospacedDigit())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LockScreenView: View {
    let state: WalkActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("MotionX", systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Text(state.ended ? "Séance terminée" : state.stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline) {
                SpeedText(state: state, size: 44)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Marche").font(.caption).foregroundStyle(.secondary)
                    WalkTimer(state: state)
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
            HStack {
                Metric(value: Fmt.distanceParts(state.distanceM).0, unit: Fmt.distanceParts(state.distanceM).1, icon: "map")
                Spacer()
                Metric(value: Fmt.int(state.steps), unit: "pas", icon: "shoeprints.fill")
                Spacer()
                Metric(value: Fmt.int(state.kcal), unit: "kcal", icon: "flame.fill")
            }
            if isStale && !state.ended {
                Text("Pas de mise à jour depuis \(state.updatedAt.formatted(date: .omitted, time: .shortened)) — ouvre MotionX")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

// Aperçus Xcode
extension WalkActivityAttributes.ContentState {
    static let preview = WalkActivityAttributes.ContentState(
        speedKmh: 4.5, distanceM: 2340, steps: 3120, kcal: 142, walkS: 1834, stateLabel: "En marche",
        moving: true, walkTimerStart: .now.addingTimeInterval(-1834), updatedAt: .now, ended: false)
}

#Preview("Écran verrouillé", as: .content, using: WalkActivityAttributes(sessionId: 7, startedAt: .now)) {
    WalkLiveActivity()
} contentStates: {
    WalkActivityAttributes.ContentState.preview
}
