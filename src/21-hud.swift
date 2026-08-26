// MARK: - Unified Floating Dynamic Island HUD (Apple Native Craftsmanship)

final class FloatingHUD {
    private let notchPanel: NSPanel
    private let notchGlowView: AppleNotchAuraView
    
    private let pillPanel: NSPanel
    private let pillContentView: NSView
    private let backplateView: AppleIslandBackplateView
    private let orbIcon: AppleIntelligenceOrbView
    private let headerLabel: NSTextField
    private let transcriptLabel: NSTextField
    private let waveformView: AppleSiriWaveformView
    
    private var hideWorkItem: DispatchWorkItem?
    private var currentWidth: CGFloat = 330
    private let minPillWidth: CGFloat = 330
    private let maxPillWidth: CGFloat = 520
    private let pillHeight: CGFloat = 52
    // Tucked nearly flush beneath the notch so the pill reads as the notch extruding,
    // not a separate floating window.
    private let pillGap: CGFloat = 2.0
    private var notchInfo: NotchGeometry
    private var screenFrame: NSRect

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        self.screenFrame = screen.frame
        self.notchInfo = NotchGeometry.detect(screen: screen)
        
        // 1. Setup Hardware Notch Glow Overlay Panel
        let padding: CGFloat = 50.0
        let glowWidth = notchInfo.rect.width + padding * 2
        let glowHeight = notchInfo.rect.height + padding + 12.0
        let glowX = notchInfo.rect.minX - padding
        let glowY = screen.frame.height - glowHeight
        
        self.notchPanel = NSPanel(
            contentRect: NSRect(x: glowX, y: glowY, width: glowWidth, height: glowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.level = .screenSaver
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.ignoresMouseEvents = true
        notchPanel.alphaValue = 0.0
        
        self.notchGlowView = AppleNotchAuraView(frame: NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight))
        notchGlowView.notchRect = notchInfo.rect
        notchPanel.contentView = notchGlowView
        
        // 2. Setup Floating Dynamic Island Panel
        let initialWidth = minPillWidth
        let pillX = screen.frame.midX - initialWidth / 2.0
        let pillY = screen.frame.height - notchInfo.rect.height - pillHeight - pillGap
        
        self.pillPanel = NSPanel(
            contentRect: NSRect(x: pillX, y: pillY, width: initialWidth, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pillPanel.level = .floating
        pillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        pillPanel.isOpaque = false
        pillPanel.backgroundColor = .clear
        pillPanel.hasShadow = true
        pillPanel.ignoresMouseEvents = true
        pillPanel.alphaValue = 0.0
        
        // Hardware-black container. The pill reads as a piece of the notch itself - opaque
        // near-black like the bezel glass, not a translucent overlay - so no blur material.
        // (The old NSVisualEffectView blur was painted over by the 0.9-alpha backplate anyway,
        // and its layer shadow was dead code: masksToBounds clips layer shadows; the window
        // shadow comes from pillPanel.hasShadow.)
        self.pillContentView = NSView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: pillHeight))
        pillContentView.wantsLayer = true
        pillContentView.layer?.cornerRadius = pillHeight / 2.0
        if #available(macOS 10.15, *) {
            pillContentView.layer?.cornerCurve = .continuous
        }
        pillContentView.layer?.masksToBounds = true
        
        self.backplateView = AppleIslandBackplateView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: pillHeight))
        pillContentView.addSubview(backplateView)
        
        // Apple Intelligence Living Orb (Top-Left)
        self.orbIcon = AppleIntelligenceOrbView(frame: NSRect(x: 16, y: 27, width: 18, height: 18))
        pillContentView.addSubview(orbIcon)
        
        // Eyebrow state label (Top-Center-Left): a single state word in the NOW PLAYING idiom.
        // State leads; the tool's name is not information the user needs at a glance.
        self.headerLabel = NSTextField(labelWithString: "")
        headerLabel.frame = NSRect(x: 38, y: 27, width: 230, height: 16)
        pillContentView.addSubview(headerLabel)
        
        // Apple Siri Equalizer (Top-Right)
        self.waveformView = AppleSiriWaveformView(frame: NSRect(x: initialWidth - 48, y: 26, width: 32, height: 16))
        pillContentView.addSubview(waveformView)
        
        // Live Transcript / Preview Text (Bottom-Row)
        self.transcriptLabel = NSTextField(labelWithString: "")
        transcriptLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        transcriptLabel.frame = NSRect(x: 16, y: 7, width: initialWidth - 32, height: 20)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        pillContentView.addSubview(transcriptLabel)

        pillPanel.contentView = pillContentView

        // Re-run screen-dependent layout whenever the display configuration changes
        // (monitor plugged/unplugged, resolution change, etc.) so the notch aura and
        // pill don't stay pinned to stale geometry. FloatingHUD isn't an NSObject subclass,
        // so use the block-based observer API rather than a @objc selector target.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyScreenLayout()
        }
    }

    // Recomputes screenFrame, notchInfo, and repositions the notch/pill panels to match -
    // the same geometry math used to place them in init().
    private func applyScreenLayout() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        self.screenFrame = screen.frame
        self.notchInfo = NotchGeometry.detect(screen: screen)

        // Notch Glow Overlay Panel geometry
        let padding: CGFloat = 50.0
        let glowWidth = notchInfo.rect.width + padding * 2
        let glowHeight = notchInfo.rect.height + padding + 12.0
        let glowX = notchInfo.rect.minX - padding
        let glowY = screenFrame.height - glowHeight
        notchPanel.setFrame(NSRect(x: glowX, y: glowY, width: glowWidth, height: glowHeight), display: true)
        notchGlowView.frame = NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight)
        notchGlowView.notchRect = notchInfo.rect
        notchGlowView.needsDisplay = true

        // Floating Dynamic Island Panel geometry (preserves currentWidth)
        let pillX = screenFrame.midX - currentWidth / 2.0
        let pillY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        pillPanel.setFrame(NSRect(x: pillX, y: pillY, width: currentWidth, height: pillHeight), display: true)
    }

    private func updatePillWidth(targetWidth: CGFloat) {
        let clamped = max(minPillWidth, min(maxPillWidth, targetWidth))
        guard abs(clamped - currentWidth) > 8.0 else { return }
        currentWidth = clamped
        
        let newX = screenFrame.midX - currentWidth / 2.0
        let newY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        let newRect = NSRect(x: newX, y: newY, width: currentWidth, height: pillHeight)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            pillPanel.animator().setFrame(newRect, display: true)
            pillContentView.frame = NSRect(x: 0, y: 0, width: currentWidth, height: pillHeight)
            backplateView.frame = NSRect(x: 0, y: 0, width: currentWidth, height: pillHeight)
            waveformView.frame = NSRect(x: currentWidth - 48, y: 26, width: 32, height: 16)
            transcriptLabel.frame = NSRect(x: 16, y: 7, width: currentWidth - 32, height: 20)
        }
    }
    
    // MARK: State typography

    // Eyebrow state word: uppercase micro-type with wide tracking (the NOW PLAYING idiom).
    private func setHeader(_ text: String, color: NSColor) {
        headerLabel.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
                .foregroundColor: color,
                .kern: 1.1
            ]
        )
    }

    // Transcript line; caret appends a slim tinted insertion mark while text is streaming.
    // Truncation MUST ride inside the attributed string: a label rendering attributedStringValue
    // takes its line-break mode from the string's NSParagraphStyle, not the cell - which is why
    // setting transcriptLabel.lineBreakMode alone never worked. While streaming, truncate the
    // HEAD so the newest words flow into view; finished text truncates the tail as usual.
    private func setTranscript(_ text: String, color: NSColor, caret: Bool, truncation: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        let body = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        if caret {
            body.append(NSAttributedString(
                string: " ▏",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: AppleDesign.siriCyan,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        transcriptLabel.attributedStringValue = body
    }

    // Plain transcript text with any streaming caret stripped.
    private var currentTranscriptText: String {
        var text = transcriptLabel.attributedStringValue.string
        if text.hasSuffix(" ▏") { text = String(text.dropLast(2)) }
        return text
    }

    func showListening() {
        hideWorkItem?.cancel()
        currentWidth = minPillWidth

        // Notch aura only exists where the hardware notch does; on external or non-notch
        // displays the pill stands alone rather than glowing around a phantom cutout.
        let hasNotch = notchInfo.hasPhysicalNotch
        if hasNotch {
            notchGlowView.state = .listening
            notchGlowView.audioLevel = 0.0
            notchGlowView.startAnimation()
        }

        // Pill Layout & Content
        orbIcon.state = .listening
        orbIcon.audioLevel = 0.0
        orbIcon.startAnimation()
        setHeader("Listening", color: NSColor(white: 1.0, alpha: 0.55))
        // The pill appears on key-down, so the user is already holding: say what to do next.
        setTranscript("Speak, then release to paste", color: NSColor(white: 1.0, alpha: 0.45), caret: false)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        waveformView.reset()

        let pillX = screenFrame.midX - minPillWidth / 2.0
        let pillY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        let finalRect = NSRect(x: pillX, y: pillY, width: minPillWidth, height: pillHeight)
        pillContentView.frame = NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight)
        backplateView.frame = NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight)
        waveformView.frame = NSRect(x: minPillWidth - 48, y: 26, width: 32, height: 16)
        transcriptLabel.frame = NSRect(x: 16, y: 7, width: minPillWidth - 32, height: 20)

        // Signature entrance: the pill slides out from beneath the notch, as if the notch
        // itself extends. Reduced-motion preference gets a plain fade.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startRect = reduceMotion ? finalRect : finalRect.offsetBy(dx: 0, dy: 10)
        pillPanel.setFrame(startRect, display: true)

        if hasNotch { notchPanel.orderFrontRegardless() }
        pillPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.16 : 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            if hasNotch { notchPanel.animator().alphaValue = 1.0 }
            pillPanel.animator().alphaValue = 1.0
            pillPanel.animator().setFrame(finalRect, display: true)
        }
    }
    
    func updateAudioLevel(db: Double) {
        let norm = max(0.0, min(1.0, CGFloat((db + 55.0) / 45.0)))
        notchGlowView.audioLevel = norm
        orbIcon.audioLevel = norm
        waveformView.updateLevel(db: db)
    }
    
    func updateLiveText(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }

        // While streaming, the newest words matter most: truncate at the head so the tail
        // of the sentence is always visible, with a slim caret marking the live edge.
        setTranscript(clean, color: .white, caret: true, truncation: .byTruncatingHead)

        // Fluid Dynamic Island auto-expansion based on text width
        let font = transcriptLabel.font ?? NSFont.systemFont(ofSize: 13.5)
        let textWidth = (clean as NSString).size(withAttributes: [.font: font]).width
        let neededWidth = max(minPillWidth, textWidth + 64.0)
        updatePillWidth(targetWidth: neededWidth)
    }

    func showProcessing() {
        hideWorkItem?.cancel()
        notchGlowView.state = .processing
        orbIcon.state = .processing

        setHeader("Polishing", color: AppleDesign.siriCyan)
        // Keep the user's words on screen, just dimmed - wiping them for a status message
        // makes the pill feel like it lost the dictation.
        let existing = currentTranscriptText
        if existing.isEmpty || existing == "Speak, then release to paste" {
            setTranscript("Polishing…", color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        } else {
            setTranscript(existing, color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        }
        waveformView.reset()
    }

    func showSuccess(text: String) {
        hideWorkItem?.cancel()
        notchGlowView.state = .success
        orbIcon.state = .success

        setHeader("Pasted", color: AppleDesign.appleGreen)
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        setTranscript(clean.isEmpty ? "Done" : clean, color: .white, caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    func showError(message: String) {
        hideWorkItem?.cancel()
        notchGlowView.state = .error
        orbIcon.state = .error

        setHeader("Error", color: AppleDesign.appleCoral)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        setTranscript(message, color: NSColor(white: 1.0, alpha: 0.85), caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }

    func hide() {
        // Retract back beneath the notch, mirroring the entrance.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let retractRect = pillPanel.frame.offsetBy(dx: 0, dy: 10)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.notchPanel.animator().alphaValue = 0.0
            self.pillPanel.animator().alphaValue = 0.0
            if !reduceMotion {
                self.pillPanel.animator().setFrame(retractRect, display: true)
            }
        }, completionHandler: {
            if self.notchPanel.alphaValue == 0.0 {
                self.notchPanel.orderOut(nil)
                self.pillPanel.orderOut(nil)
                self.notchGlowView.stopAnimation()
                self.orbIcon.stopAnimation()
            }
        })
    }
}

