var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    checks += 1
}
let hudApp = NSApplication.shared
hudApp.setActivationPolicy(.accessory)
extension FloatingHUD {
    func fixtureCheck() {
        showError(message: "Microphone interrupted. Try again.")
        check(shownTarget && notchPanel.isVisible, "error opens previously hidden HUD")
        showStarting()
        check(hideWorkItem?.isCancelled == true, "startup cancels old error hide timer")
        check(currentTranscriptText == "Getting ready…", "startup shows readiness message")
        showListening()
        presence.snap()
        widthSpring.snap()
        applyFrame()
        let path = pillWrapper.layer?.shadowPath
        let begin = CACurrentMediaTime()
        for _ in 0..<10000 { applyFrame() }
        let elapsed = (CACurrentMediaTime() - begin) * 1000
        check(pillWrapper.layer?.shadowPath === path, "settled geometry reuses shadow path")
        print("HUD unchanged-layout 10000 calls ms=\(elapsed)")
        for style in ["slide", "bloom", "drift", "unfurl", "morph"] {
            revealStyle = style
            for amount in [0.0, 0.4, 0.8, 1.0] {
                presence.value = CGFloat(amount)
                applyFrame()
                check(pillWrapper.frame.width > 0 && pillWrapper.frame.height > 0, "reveal geometry stays valid")
            }
        }
        revealStyle = "slide"
        presence.snap()
        applyFrame()
        showSuccess(text: "Deployment ready for review.")
        hostView.displayIfNeeded()
        if let bitmap = hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds) {
            hostView.cacheDisplay(in: hostView.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/justspeak-hud-check.png"))
            }
        }
        hideWorkItem?.cancel()
        hostPanel.orderOut(nil)
        notchPanel.orderOut(nil)
        stopTick()
    }
}
let checkedHUD = FloatingHUD()
checkedHUD.fixtureCheck()
print("PASS: \(checks) HUD checks. No mic, network, or clipboard use.")
