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
                        Button("Enregistrer", action: save)
                            .disabled(draftURL == model.serverURL)
                        Spacer()
                        Button {
                            Task { await test() }
                        } label: {
                            if testing { ProgressView() } else { Text("Tester") }
                        }
                        .disabled(APIClient(urlString: draftURL) == nil || testing)
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Serveur MotionX")
                } footer: {
                    Text("Adresse du serveur Node.js sur ton NAS (même port que le tableau de bord web).")
                }

                Section {
                    if !model.health.isAvailable {
                        Label("Santé n'est pas disponible sur cet appareil", systemImage: "heart.slash")
                    } else if model.health.isAuthorized {
                        Label("Accès autorisé", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Toggle("Synchro automatique", isOn: $model.autoHealthSync)
                        Button {
                            Task { await model.syncHealthNow() }
                        } label: {
                            HStack {
                                Text("Synchroniser maintenant")
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
                            Label("Autoriser l'accès à Santé", systemImage: "heart.fill")
                        }
                        if model.health.authStatus == .sharingDenied {
                            Text("Accès refusé. Active-le dans Réglages › Santé › Accès aux données et appareils › MotionX.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let msg = model.health.lastMessage, let date = model.health.lastSync {
                        LabeledContent("Dernière synchro") {
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
                    Text("Apple Santé")
                } footer: {
                    Text("Chaque séance devient un entraînement « Marche » en intérieur, avec distance, calories et pas. La synchro se fait à l'ouverture de l'app, dès qu'une séance se termine pendant que l'app est ouverte, et de temps en temps en arrière-plan. Tu peux désactiver le raccourci iOS : les séances déjà transférées ne seront pas renvoyées.")
                }

                Section {
                    Toggle("Live Activity", isOn: $model.liveActivityEnabled)
                    Toggle("Mise à jour écran verrouillé", isOn: $model.keepAwake)
                        .disabled(!model.liveActivityEnabled)
                } header: {
                    Text("Écran verrouillé et Dynamic Island")
                } footer: {
                    Text("La Live Activity démarre quand une séance commence et que l'app est ouverte. « Mise à jour écran verrouillé » garde l'app éveillée pendant la séance en jouant du silence, mélangé à ta musique sans la couper, pour que vitesse, distance et pas restent à jour. Sans cette option, seul le chrono continue d'avancer.")
                }

                if let live = model.live.live {
                    Section("Tapis") {
                        if let url = live.deviceURL {
                            Link(destination: url) {
                                LabeledContent("Page de l'ESP32", value: url.host() ?? "")
                            }
                        }
                        if let fw = live.fw { LabeledContent("Firmware", value: fw) }
                        if let rssi = live.rssi, rssi != 0 { LabeledContent("Wi-Fi", value: "\(rssi) dBm") }
                        if let stored = live.stored { LabeledContent("Séances en mémoire", value: "\(stored)") }
                        if let pending = live.pending, pending > 0 { LabeledContent("À envoyer au serveur", value: "\(pending)") }
                    }
                }

                Section {
                    LabeledContent("Taille", value: "\(Int(model.history.profile.heightCm)) cm")
                    LabeledContent("Poids", value: "\(Int(model.history.profile.weightKg)) kg")
                } header: {
                    Text("Profil (calcul des pas et calories)")
                } footer: {
                    Text("Défini côté serveur avec les variables HEIGHT_CM et WEIGHT_KG.")
                }
            }
            .navigationTitle("Réglages")
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
                testResult = "✅ Serveur OK · tapis : \(live.isStale() ? "silencieux" : live.stateLabel) · \(r.udpPackets ?? 0) paquets UDP reçus"
            } else {
                testResult = "✅ Serveur OK · aucune donnée reçue de l'ESP32 pour l'instant"
            }
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
