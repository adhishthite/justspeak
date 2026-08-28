// MARK: - HUD Demo Mode (--hud-demo)

// Drives the FloatingHUD through scripted state cycles with synthetic audio levels and
// transcripts - no mic, no network - so visual changes are reviewable without dictating.
final class HudDemo {
    // Held for the process lifetime; app.run() never returns, but a strong static owner
    // keeps intent obvious rather than relying on that fact.
    private static var shared: HudDemo?

    private let hud: FloatingHUD
    private var levelTimer: Timer?
    private var levelPhase: Double = 0.0

    private let sentences = [
        "Please schedule the quarterly review meeting for next Tuesday afternoon at three",
        "Remember to send the updated proposal document to the client before Friday evening",
        "The deployment pipeline needs a second reviewer before it can ship to production",
    ]

    private init(config: Config) {
        self.hud = FloatingHUD()
        hud.revealStyle = config.hudRevealStyle
    }

    static func run(config: Config) -> Never {
        print("\n\(ANSI.bold)\(ANSI.cyan)JustSpeak HUD Demo\(ANSI.reset)")
        print("\(ANSI.gray)Cycling synthetic HUD states - no mic, no network. revealStyle=\(config.hudRevealStyle)\(ANSI.reset)")
        print("\(ANSI.gray)Press Ctrl+C to quit.\(ANSI.reset)\n")

        let demo = HudDemo(config: config)
        shared = demo
        demo.scheduleCycle(sentenceIndex: 0, delay: 0.0)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        // app.run() blocks for the process lifetime; nothing here is reachable, but the
        // compiler needs an explicit diverging statement to accept -> Never.
        fatalError("unreachable")
    }

    // One full cycle: a "listening" turn that succeeds, then a short "listening" turn that
    // errors out, then reschedules itself with the next sample sentence. `delay` is relative
    // to "now" at call time - the loop-back reschedule fires (and only then recurses) at
    // t+12s rather than recursing synchronously, so this never blows the stack.
    private func scheduleCycle(sentenceIndex: Int, delay: TimeInterval) {
        let sentence = sentences[sentenceIndex % sentences.count]
        let nextIndex = sentenceIndex + 1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runListeningTurn(text: sentence)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 4.5) { [weak self] in
            self?.stopLevelTimer()
            self?.hud.showProcessing()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 5.7) { [weak self] in
            self?.hud.showSuccess(text: sentence)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 8.0) { [weak self] in
            self?.runErrorTurn()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 10.0) { [weak self] in
            self?.stopLevelTimer()
            self?.hud.showError(message: "Demo: transcription failed — nothing pasted")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 12.0) { [weak self] in
            self?.scheduleCycle(sentenceIndex: nextIndex, delay: 0.0)
        }
    }

    // Feeds a synthetic speech envelope + progressive transcript for ~4.5s of "listening";
    // the hold-to-lock ring closes at 2.5s so the lock beat previews without an 8s hold.
    private func runListeningTurn(text: String) {
        hud.showListening(lockAfter: 2.5)
        startLevelTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.hud.showLocked()
        }

        let words = text.split(separator: " ").map(String.init)
        var revealed = ""
        for (i, word) in words.enumerated() {
            let delay = 0.2 * Double(i)
            guard delay < 4.3 else { break }
            revealed += (revealed.isEmpty ? "" : " ") + word
            let snapshot = revealed
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hud.updateLiveText(snapshot)
            }
        }
    }

    // Short ~2s "listening" burst that leads into showError instead of a success paste.
    private func runErrorTurn() {
        hud.showListening()
        startLevelTimer()
        hud.updateLiveText("uh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.hud.updateLiveText("uh, hold on")
        }
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelPhase = 0.0
        // ~300ms per "syllable": one full sin cycle every ~10 ticks at 30Hz.
        let phaseStep = Double.pi / 10.0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.levelPhase += phaseStep
            let jitter = Double.random(in: -3.0...3.0)
            let db = -50.0 + 27.0 * abs(sin(self.levelPhase)) + jitter
            self.hud.updateAudioLevel(db: db)
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
