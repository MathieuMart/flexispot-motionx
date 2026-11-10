import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draftURL = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var healthError: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.20:3000", text: $draftURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    HStack {
                        Button("Save", action: save)
                            .disabled(draftURL == model.serverURL)
                        Spacer()
                        Button {
                            Task { await test() }
                        } label: {
                            if testing { ProgressView() } else { Text("Test") }
                        }
                        .disabled(APIClient(urlString: draftURL) == nil || testing)
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("MotionX Server")
                } footer: {
                    Text("Address of the Node.js server on your NAS (same port as the web dashboard).")
                }

                Section {
                    if !model.health.isAvailable {
                        Label("Health is not available on this device", systemImage: "heart.slash")
                    } else if model.health.isAuthorized {
                        Label("Access granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Toggle("Automatic sync", isOn: $model.autoHealthSync)
                        Button {
                            Task { await model.syncHealthNow() }
                        } label: {
                            HStack {
                                Text("Sync now")
                                Spacer()
                                if model.health.running { ProgressView() }
                            }
                        }
                        .disabled(model.health.running || model.api == nil)
                    } else {
                        Button {
                            Task {
                                do { try await model.health.requestAuthorization(); await model.syncHealthNow() }
                                catch { healthError = error.localizedDescription }
                            }
                        } label: {
                            Label("Allow access to Health", systemImage: "heart.fill")
                        }
                        if model.health.authStatus == .sharingDenied {
                            Text("Access denied. Turn it on in Settings › Health › Data Access & Devices › MotionX.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let msg = model.health.lastMessage, let date = model.health.lastSync {
                        LabeledContent("Last sync") {
                            VStack(alignment: .trailing) {
                                Text(date.formatted(.relative(presentation: .named)))
                                Text(msg).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let healthError {
                        Text(healthError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Each session becomes an indoor “Walking” workout, with distance, calories and steps. Sync happens when the app opens, as soon as a session ends while the app is open, and from time to time in the background. You can turn off the iOS shortcut: sessions already transferred will not be sent again.")
                }

                Section {
                    Toggle("Live Activity", isOn: $model.liveActivityEnabled)
                    Toggle("Lock Screen updates", isOn: $model.keepAwake)
                        .disabled(!model.liveActivityEnabled)
                } header: {
                    Text("Lock Screen and Dynamic Island")
                } footer: {
                    Text("The Live Activity starts when a session begins while the app is open. “Lock Screen updates” keeps the app awake during the session by playing silence, mixed with your music without interrupting it, so that speed, distance and steps stay up to date. Without this option, only the timer keeps ticking.")
                }

                if let live = model.live.live {
                    Section("Treadmill") {
                        if let url = live.deviceURL {
                            Link(destination: url) {
                                LabeledContent("ESP32 page", value: url.host() ?? "")
                            }
                        }
                        if let fw = live.fw { LabeledContent("Firmware", value: fw) }
                        if let rssi = live.rssi, rssi != 0 { LabeledContent("Wi-Fi", value: "\(rssi) dBm") }
                        if let stored = live.stored { LabeledContent("Sessions in memory", value: "\(stored)") }
                        if let pending = live.pending, pending > 0 { LabeledContent("To send to the server", value: "\(pending)") }
                    }
                }

                Section {
                    LabeledContent("Height", value: "\(Int(model.history.profile.heightCm)) cm")
                    LabeledContent("Weight", value: "\(Int(model.history.profile.weightKg)) kg")
                } header: {
                    Text("Profile (steps and calories calculation)")
                } footer: {
                    Text("Set on the server side with the HEIGHT_CM and WEIGHT_KG variables.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { if draftURL.isEmpty { draftURL = model.serverURL } }
        }
    }

    private func save() {
        model.setServer(draftURL)
        testResult = nil
    }

    private func test() async {
        guard let api = APIClient(urlString: draftURL) else { return }
        testing = true
        defer { testing = false }
        do {
            let r = try await api.live()
            if let live = r.live {
                testResult = "✅ Server OK · treadmill: \(live.isStale() ? "silent" : live.stateLabel) · \(r.udpPackets ?? 0) UDP packets received"
            } else {
                testResult = "✅ Server OK · no data received from the ESP32 yet"
            }
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
