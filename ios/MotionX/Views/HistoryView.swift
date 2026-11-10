import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.api == nil {
                    ServerMissingView()
                } else if model.history.sessions.isEmpty {
                    if !model.history.loadedOnce || model.history.loading {
                        ProgressView()
                    } else if let err = model.history.error {
                        ContentUnavailableView("Serveur injoignable", systemImage: "wifi.exclamationmark", description: Text(err))
                    } else {
                        ContentUnavailableView("Aucune séance", systemImage: "figure.walk",
                                               description: Text("Tes séances apparaîtront ici dès que l'ESP32 les aura envoyées."))
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Historique")
            .toolbar {
                if model.health.isAuthorized {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.syncHealthNow() }
                        } label: {
                            if model.health.running { ProgressView() } else { Image(systemName: "heart.text.square") }
                        }
                        .disabled(model.health.running)
                        .accessibilityLabel("Synchroniser avec Santé")
                    }
                }
            }
            .refreshable { await model.history.refresh(api: model.api) }
        }
    }

    private var list: some View {
        List {
            Section {
                weekSummary
            }
            if let err = model.history.error {
                Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            ForEach(model.history.byDay, id: \.day) { group in
                Section {
                    ForEach(group.sessions) { s in
                        NavigationLink(value: s) { SessionRow(session: s) }
                    }
                } header: {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                }
            }
        }
        .navigationDestination(for: SessionSummary.self) { SessionDetailView(summary: $0) }
    }

    private var weekSummary: some View {
        let week = model.history.totals(since: Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now))!)
        let days = model.history.daily(days: 7)
        return VStack(alignment: .leading, spacing: 12) {
            Text("7 derniers jours").font(.headline)
            HStack(spacing: 18) {
                summaryValue(Fmt.distance(week.distanceM), "distance")
                summaryValue(Fmt.int(week.steps), "pas")
                summaryValue(Fmt.duration(week.walkS), "de marche")
            }
            Chart(days) { d in
                BarMark(x: .value("Jour", d.day, unit: .day), y: .value("km", d.distanceM / 1000))
                    .foregroundStyle(Calendar.current.isDateInToday(d.day) ? Color.accentColor : Color.accentColor.opacity(0.5))
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 120)
        }
        .padding(.vertical, 6)
    }

    private func summaryValue(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.headline.monospacedDigit())
                Text("\(Fmt.hms(session.computed.walkS)) · \(Fmt.distance(session.computed.distanceM)) · \(Fmt.int(session.computed.steps)) pas")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: session.healthSynced == true ? "heart.fill" : "heart")
                .foregroundStyle(session.healthSynced == true ? Color.pink : Color.secondary.opacity(0.5))
                .accessibilityLabel(session.healthSynced == true ? "Dans Santé" : "Pas encore dans Santé")
        }
        .padding(.vertical, 2)
    }
}

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var detail: SessionDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(title: "Marche", value: Fmt.hms(summary.computed.walkS), systemImage: "figure.walk", tint: .green)
                    StatTile(title: "Durée totale", value: Fmt.hms(summary.durationS ?? summary.computed.walkS), systemImage: "stopwatch")
                    StatTile(title: "Distance", value: Fmt.distanceParts(summary.computed.distanceM).0, unit: Fmt.distanceParts(summary.computed.distanceM).1, systemImage: "map", tint: .blue)
                    StatTile(title: "Pas ≈", value: Fmt.int(summary.computed.steps), systemImage: "shoeprints.fill", tint: .orange)
                    StatTile(title: "Calories ≈", value: Fmt.int(summary.computed.kcal), unit: "kcal", systemImage: "flame.fill", tint: .red)
                    StatTile(title: "Vitesse moy. / max", value: "\(Fmt.speed(avgSpeed)) / \(Fmt.speed(summary.maxKmh ?? 0))", unit: "km/h", systemImage: "speedometer", tint: .purple)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Profil de vitesse").font(.headline)
                    if let detail {
                        SpeedChart(points: detail.events, endMs: (detail.durationS ?? 0) * 1000)
                            .frame(height: 200)
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(summary.healthSynced == true ? "Enregistrée dans Santé" : "Pas encore dans Santé",
                          systemImage: summary.healthSynced == true ? "heart.fill" : "heart")
                        .foregroundStyle(summary.healthSynced == true ? .pink : .secondary)
                    if summary.startEstimated == true {
                        Label("Heure de début estimée (l'ESP32 n'avait pas l'heure)", systemImage: "clock.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                    if let end = summary.end {
                        Label("Fin : \(endLabel(end)) · séance #\(summary.number)", systemImage: "flag.checkered")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            .padding()
        }
        .navigationTitle(summary.startDate.formatted(.dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard detail == nil, let api = model.api else { return }
            do { detail = try await api.session(file: summary.file) } catch { self.error = error.localizedDescription }
        }
    }

    private var avgSpeed: Double {
        let w = Double(summary.computed.walkS)
        return w > 0 ? summary.computed.distanceM / w * 3.6 : (summary.avgKmh ?? 0)
    }

    private func endLabel(_ raw: String) -> String {
        switch raw {
        case "stop": return "arrêt normal"
        case "signal_perdu": return "signal perdu"
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }
}
