import AVFoundation

/// Garde l'app éveillée écran verrouillé en jouant du silence (mode d'arrière-plan « audio »),
/// pour que le flux temps réel continue d'alimenter la Live Activity pendant une séance.
/// Mixé avec les autres sons : ta musique ou tes podcasts ne sont pas coupés.
@MainActor
final class BackgroundKeeper {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine != nil }

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = buffer.frameCapacity
            if let ch = buffer.floatChannelData { ch[0].update(repeating: 0, count: Int(buffer.frameLength)) }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player

            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                              object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                MainActor.assumeIsolated {          // après un appel téléphonique : on relance
                    self?.stop()
                    self?.start()
                }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
