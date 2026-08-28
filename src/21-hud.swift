// MARK: - Unified Floating Dynamic Island HUD (Spring-Driven Motion)

// One scalar spring channel, stepped per display frame with semi-implicit Euler. Substeps
// keep dt·damping far below the explicit stability bound, so a stalled frame (or the 60Hz
// timer fallback) integrates identically to 120Hz - verified numerically at 20/60/120Hz.
// Retargeting keeps position AND velocity: motion redirects mid-flight instead of
// restarting, which is the single biggest tell of system-native animation.
struct SpringChannel {
    var value: CGFloat
    var velocity: CGFloat = 0.0
    var target: CGFloat
    var stiffness: CGFloat
    var dampingRatio: CGFloat
    // Settle threshold in the channel's own units (a 0-1 progress and a width in points
    // need different scales).
    var epsilon: CGFloat = 0.001

    mutating func step(dt: CGFloat) {
        let damping = 2.0 * sqrt(stiffness) * dampingRatio
        let substeps = max(1, Int(ceil(dt / (1.0 / 120.0))))
        let h = dt / CGFloat(substeps)
        for _ in 0..<substeps {
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
        }
    }

    var settled: Bool {
        abs(value - target) < epsilon && abs(velocity) < epsilon * 25.0
    }

    mutating func snap() {
        value = target
        velocity = 0.0
    }
}

private enum HUDMetrics {
    static let minPillWidth: CGFloat = 330
    static let maxPillWidth: CGFloat = 520
    static let pillHeight: CGFloat = 52
    // A deliberate air gap beneath the notch: the aura's light spill needs visible
    // wallpaper between the bezel and the pill to land on.
    static let pillGap: CGFloat = 14.0
    // Host-panel margins: side room for the layer shadow, bottom room for shadow spread
    // plus unfurl's height overshoot.
    static let hostMarginX: CGFloat = 40.0
    static let hostMarginBottom: CGFloat = 44.0

    // The host spans from the screen's TOP edge (the morph membrane must start hidden
    // inside the notch cutout) down past the pill's resting place.
    static func hostSize(notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: maxPillWidth + hostMarginX * 2.0,
            height: notchHeight + pillGap + pillHeight + hostMarginBottom)
    }
}

// AppKit's default constrainFrameRect keeps any window below .mainMenu level (the host is
// .floating) from overlapping the menu bar: setFrame silently shoves it down by the menu-bar
// height. The host must span to the screen top (morph starts inside the notch cutout), so
// the identity override is required - otherwise the pill lands a menu bar below the aura,
// which stays put because .screenSaver is above the clamp.
private final class HUDPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class FloatingHUD: NSObject {
    private let notchPanel: NSPanel
    private let notchGlowView: AppleNotchAuraView

    // The pill lives on a STATIC panel sized to its maximum footprint; nothing ever animates
    // at the window level. All motion is view geometry inside it - GPU-composited and spring
    // driven. The old animator().setFrame pipeline animated the window itself through the
    // window server, and that cadence was the ceiling on smoothness.
    private let hostPanel: NSPanel
    private let hostView: NSView
    private let pillWrapper: NSView  // shadow carrier: masksToBounds off, shadowPath capsule
    private let pillClip: NSView  // continuous-corner capsule clip for the content
    private let backplateView: AppleIslandBackplateView
    private let materialView: NSVisualEffectView  // pill-mode only: wallpaper shows through
    private let orbIcon: AppleIntelligenceOrbView
    private let headerLabel: NSTextField
    private let transcriptLabel: NSTextField
    private let waveformView: AppleSiriWaveformView
    // Hold-to-lock rim: a stroke tracing the capsule clockwise from 12 o'clock that closes
    // at the instant the hold locks. Lives inside pillClip so the capsule mask trims it;
    // implicit actions are nulled so per-frame writes land without CA's 0.25s animation.
    private let lockRingLayer: CAShapeLayer

    private var hideWorkItem: DispatchWorkItem?

    // Main-thread-only lock state. lockAfter is the hold length that locks (nil = no ring);
    // listenStart anchors the ring's clock. On lock, lockPulse runs 1→0: the closed rim
    // flares, then decays to a faint resting ring that persists for as long as the lock does.
    private var lockAfter: TimeInterval?
    private var listenStart: CFTimeInterval = 0
    private var locked = false
    private var lockPulse = SpringChannel(value: 0.0, target: 0.0, stiffness: 90, dampingRatio: 1.0)
    // The lock hint owns the transcript line briefly; live words arriving inside that window
    // are held and rendered once it lapses, so the hint is never wiped mid-read.
    private var lockHintUntil: CFTimeInterval = 0
    private var deferredLiveText: String?
    private var lockRingSize: CGSize = .zero
    private static let lockHint = "Release the key. Press again to finish."

    private var notchInfo: NotchGeometry
    private var screenFrame: NSRect
    // Display the HUD is laid out on; nil = wherever NSScreen.main says. Main-thread-only.
    private var currentDisplayID: CGDirectDisplayID?

    // Presence 0→1 drives travel, alpha and shadow; width is in points. Main-thread-only,
    // like every other HUD member. Exit retunes presence stiffer (700) for a brisk retreat;
    // showListening restores the entrance tuning.
    private var presence = SpringChannel(value: 0.0, target: 0.0, stiffness: 420, dampingRatio: 1.0)
    private var widthSpring = SpringChannel(
        value: HUDMetrics.minPillWidth, target: HUDMetrics.minPillWidth, stiffness: 380, dampingRatio: 0.86, epsilon: 0.05)
    private var shownTarget = false

    // Entrance animation; set once at startup from config. "slide" is the shipped default.
    var revealStyle: String = "slide"

    // Ambient mote emission under the notch while listening; forwarded to the aura view.
    var particlesEnabled: Bool = true {
        didSet { notchGlowView.particlesEnabled = particlesEnabled }
    }

    // Screen-share privacy: the pill never renders dictated words - a generic placeholder
    // stands in while streaming and the success beat shows no transcript.
    var privacyMode: Bool = false

    // CADisplayLink on macOS 14+ (stored as AnyObject so the property needs no availability
    // annotation); a 60Hz timer stands in on older systems.
    private var displayLink: AnyObject?
    private var fallbackTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0
    // Glow/orb are Core Graphics redraws - advanced at ~40Hz even when the springs tick at
    // 120Hz. Pill MOTION stays at native refresh; the slow-breathing glow doesn't need it.
    private var glowAccumulator: CGFloat = 0.0

    // Everything is assembled in locals first: NSObject subclasses may not touch properties
    // of already-assigned stored objects before super.init(), only initialize them.
    override init() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let screenFrame = screen.frame
        let notchInfo = NotchGeometry.detect(screen: screen)

        // 1. Notch glow overlay. The panel stays at alpha 1.0 forever; fades happen on the
        // VIEW's alpha - a layer write per frame, not a window-server call.
        let padding: CGFloat = 50.0
        let glowWidth = notchInfo.rect.width + padding * 2
        let glowHeight = notchInfo.rect.height + padding + 44.0
        let glowX = notchInfo.rect.minX - padding
        let glowY = screenFrame.maxY - glowHeight

        let notchPanel = HUDPanel(
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
        notchPanel.alphaValue = 1.0

        let notchGlowView = AppleNotchAuraView(frame: NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight))
        notchGlowView.notchRect = notchInfo.rect
        notchGlowView.alphaValue = 0.0
        notchPanel.contentView = notchGlowView

        // 2. Static host panel for the pill, at maximum footprint, top edge at screen top.
        let host = HUDMetrics.hostSize(notchHeight: notchInfo.rect.height)
        let hostPanel = HUDPanel(
            contentRect: NSRect(
                x: screenFrame.midX - host.width / 2.0,
                y: screenFrame.maxY - host.height,
                width: host.width, height: host.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostPanel.level = .floating
        hostPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hostPanel.isOpaque = false
        hostPanel.backgroundColor = .clear
        // The window shadow would be recomputed from content on every frame of a shaped,
        // moving pill; a layer shadow with an explicit capsule path composites instead.
        hostPanel.hasShadow = false
        hostPanel.ignoresMouseEvents = true
        hostPanel.alphaValue = 1.0

        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: host.width, height: host.height))
        hostView.wantsLayer = true
        hostView.alphaValue = 0.0

        let pillWrapper = NSView(
            frame: NSRect(
                x: (host.width - HUDMetrics.minPillWidth) / 2.0,
                y: host.height - notchInfo.rect.height - HUDMetrics.pillGap - HUDMetrics.pillHeight,
                width: HUDMetrics.minPillWidth, height: HUDMetrics.pillHeight))
        pillWrapper.wantsLayer = true
        pillWrapper.layer?.masksToBounds = false
        pillWrapper.layer?.shadowColor = NSColor.black.cgColor
        pillWrapper.layer?.shadowRadius = 16.0
        pillWrapper.layer?.shadowOffset = CGSize(width: 0, height: -8)
        pillWrapper.layer?.shadowOpacity = 0.0

        // Hardware-black container. The pill reads as a piece of the notch itself - opaque
        // near-black like the bezel glass, not a translucent overlay - so no blur material.
        let pillClip = NSView(frame: pillWrapper.bounds)
        pillClip.wantsLayer = true
        pillClip.layer?.cornerRadius = HUDMetrics.pillHeight / 2.0
        if #available(macOS 10.15, *) {
            pillClip.layer?.cornerCurve = .continuous
        }
        pillClip.layer?.masksToBounds = true

        // No-notch displays have no bezel for a hardware-black slab to continue, and on a
        // light wallpaper the slab reads as a hard-edged black block. There the pill is a
        // dark translucent material with the wallpaper blurred through it; hidden on notch
        // displays so the bezel illusion stays intact.
        let materialView = NSVisualEffectView(frame: pillClip.bounds)
        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.appearance = NSAppearance(named: .darkAqua)
        materialView.isHidden = true
        pillClip.addSubview(materialView)

        let backplateView = AppleIslandBackplateView(frame: pillClip.bounds)
        pillClip.addSubview(backplateView)

        // Apple Intelligence Living Orb (Top-Left)
        let orbIcon = AppleIntelligenceOrbView(frame: NSRect(x: 16, y: 27, width: 18, height: 18))
        pillClip.addSubview(orbIcon)

        // Eyebrow state label (Top-Center-Left): a single state word in the NOW PLAYING idiom.
        let headerLabel = NSTextField(labelWithString: "")
        headerLabel.frame = NSRect(x: 38, y: 27, width: 230, height: 16)
        pillClip.addSubview(headerLabel)

        // Apple Siri Equalizer (Top-Right)
        let waveformView = AppleSiriWaveformView(
            frame: NSRect(x: HUDMetrics.minPillWidth - 48, y: 26, width: 32, height: 16))
        pillClip.addSubview(waveformView)

        // Live Transcript / Preview Text (Bottom-Row)
        let transcriptLabel = NSTextField(labelWithString: "")
        transcriptLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        transcriptLabel.frame = NSRect(x: 16, y: 7, width: HUDMetrics.minPillWidth - 32, height: 20)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        pillClip.addSubview(transcriptLabel)

        let lockRingLayer = CAShapeLayer()
        lockRingLayer.fillColor = nil
        lockRingLayer.strokeColor = NSColor.white.cgColor
        lockRingLayer.lineWidth = 2.0
        lockRingLayer.lineCap = .round
        lockRingLayer.strokeEnd = 0.0
        lockRingLayer.opacity = 0.0
        lockRingLayer.zPosition = 10
        lockRingLayer.actions = [
            "path": NSNull(), "strokeEnd": NSNull(), "opacity": NSNull(), "lineWidth": NSNull(),
            "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
        ]
        pillClip.layer?.addSublayer(lockRingLayer)

        pillWrapper.addSubview(pillClip)
        hostView.addSubview(pillWrapper)
        hostPanel.contentView = hostView

        self.screenFrame = screenFrame
        self.notchInfo = notchInfo
        self.notchPanel = notchPanel
        self.notchGlowView = notchGlowView
        self.hostPanel = hostPanel
        self.hostView = hostView
        self.pillWrapper = pillWrapper
        self.pillClip = pillClip
        self.backplateView = backplateView
        self.materialView = materialView
        self.orbIcon = orbIcon
        self.headerLabel = headerLabel
        self.waveformView = waveformView
        self.transcriptLabel = transcriptLabel
        self.lockRingLayer = lockRingLayer

        super.init()

        // Re-run screen-dependent layout whenever the display configuration changes
        // (monitor plugged/unplugged, resolution change, etc.) so the notch aura and
        // pill don't stay pinned to stale geometry.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyScreenLayout()
        }

        // On non-notch displays the aura panel must wrap the pill instead of a phantom
        // cutout; applyScreenLayout holds that branch, so run it once at startup.
        applyScreenLayout()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Recomputes screenFrame, notchInfo, and repositions the panels - the same geometry
    // math used to place them in init().
    // Re-anchors both panels on `screen` if it differs from the current one. Called at
    // key-down before showListening; a change mid-exit (quick re-press after moving to the
    // other display) relayouts while the pill is near-collapsed, so no visible jump.
    func retarget(to screen: NSScreen) {
        let id = FocusScreenResolver.displayID(of: screen)
        guard id != currentDisplayID else { return }
        currentDisplayID = id
        applyScreenLayout()
        if #available(macOS 10.15, *) {
            Logger.info("HUD", "Following focus to \(screen.localizedName)\(notchInfo.hasPhysicalNotch ? " (notch)" : " (pill)").")
        }
    }

    // The display picked by retarget while it's still attached; the display-config
    // notification drops back to NSScreen.main when it has been unplugged.
    private func layoutScreen() -> NSScreen {
        if let id = currentDisplayID,
            let s = NSScreen.screens.first(where: { FocusScreenResolver.displayID(of: $0) == id })
        {
            return s
        }
        currentDisplayID = nil
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func applyScreenLayout() {
        let screen = layoutScreen()
        self.screenFrame = screen.frame
        self.notchInfo = NotchGeometry.detect(screen: screen)

        let host = HUDMetrics.hostSize(notchHeight: notchInfo.rect.height)
        let pillTopScreen = screenFrame.maxY - notchInfo.rect.height - HUDMetrics.pillGap
        hostPanel.setFrame(
            NSRect(
                x: screenFrame.midX - host.width / 2.0,
                y: screenFrame.maxY - host.height,
                width: host.width, height: host.height),
            display: true)
        hostView.frame = NSRect(x: 0, y: 0, width: host.width, height: host.height)

        if notchInfo.hasPhysicalNotch {
            // Aura panel hugs the hardware notch, with room below for the light spill.
            let padding: CGFloat = 50.0
            let glowWidth = notchInfo.rect.width + padding * 2
            let glowHeight = notchInfo.rect.height + padding + 44.0
            let glowX = notchInfo.rect.minX - padding
            let glowY = screenFrame.maxY - glowHeight
            notchPanel.setFrame(NSRect(x: glowX, y: glowY, width: glowWidth, height: glowHeight), display: true)
            notchGlowView.frame = NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight)
            notchGlowView.notchRect = notchInfo.rect
            notchGlowView.pillMode = false
        } else {
            // No hardware notch: the halo wraps the pill. The panel is sized to the pill's
            // MAXIMUM footprint so width changes never need a panel reframe. Margin must
            // exceed the halo's worst-case reach (the flank spread pass in drawPillAura:
            // ~16 dilation + 8 drop + 7 half-stroke + 44 blur = ~75px) or the fade gets a
            // hard cutoff.
            let margin: CGFloat = 88.0
            let auraWidth = HUDMetrics.maxPillWidth + margin * 2
            let auraHeight = HUDMetrics.pillHeight + margin * 2
            let auraX = screenFrame.midX - auraWidth / 2.0
            let auraY = pillTopScreen - HUDMetrics.pillHeight - margin
            notchPanel.setFrame(NSRect(x: auraX, y: auraY, width: auraWidth, height: auraHeight), display: true)
            notchGlowView.frame = NSRect(x: 0, y: 0, width: auraWidth, height: auraHeight)
            notchGlowView.pillMode = true
        }
        // The aura's capsule is a circular CGPath; a continuous-curve clip on the pill
        // diverges from it along the end caps and the rim visibly parts from the edge.
        // Match geometries in pill mode; the notch keeps Apple's continuous corners.
        if #available(macOS 10.15, *) {
            let curve: CALayerCornerCurve = notchInfo.hasPhysicalNotch ? .continuous : .circular
            pillClip.layer?.cornerCurve = curve
            backplateView.layer?.cornerCurve = curve
        }
        backplateView.specularRim = notchInfo.hasPhysicalNotch
        backplateView.baseAlpha = notchInfo.hasPhysicalNotch ? 0.97 : 0.58
        backplateView.needsDisplay = true
        materialView.isHidden = notchInfo.hasPhysicalNotch
        notchGlowView.needsDisplay = true
        applyFrame()
    }

    // MARK: Display tick

    private func startTick() {
        guard displayLink == nil && fallbackTimer == nil else { return }
        lastTickTime = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let link = hostView.displayLink(target: self, selector: #selector(onDisplayTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopTick() {
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func onDisplayTick() {
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastTickTime, 0.0), 1.0 / 20.0))
        lastTickTime = now
        guard dt > 0 else { return }

        presence.step(dt: dt)
        widthSpring.step(dt: dt)
        applyFrame()
        updateLockRing(now: now, dt: dt)

        // Continuous glow/orb phases only while those states actually animate; success and
        // error are static frames whose one redraw came from their state didSets.
        let continuous = shownTarget && (notchGlowView.state == .listening || notchGlowView.state == .processing)
        if continuous {
            glowAccumulator += dt
            if glowAccumulator >= 1.0 / 40.0 {
                notchGlowView.advance(dt: glowAccumulator)
                orbIcon.advance(dt: glowAccumulator)
                glowAccumulator = 0.0
            }
        }

        if presence.settled && widthSpring.settled {
            if !shownTarget && presence.target == 0 {
                hostPanel.orderOut(nil)
                notchPanel.orderOut(nil)
                stopTick()
            } else if !continuous {
                stopTick()
            }
        }
    }

    // Lays out the pill for the CURRENT spring values. Runs every animation frame (and once
    // after any instant reduced-motion or screen-change update); AppKit skips repaints for
    // frames set to their existing values, so settled ticks cost nothing.
    private func applyFrame() {
        let p = max(0.0, presence.value)
        let w = min(max(widthSpring.value, HUDMetrics.minPillWidth), HUDMetrics.maxPillWidth)
        let hostBounds = hostView.bounds
        let pillTop = hostBounds.height - notchInfo.rect.height - HUDMetrics.pillGap

        // Each reveal style is a pure mapping from presence to geometry, so the SAME spring
        // handles entrance, exit and mid-flight redirection; overshoot bounces are the
        // spring's own physics (damping ratio per style), never a second animation stage.
        var rect: NSRect
        var radius: CGFloat
        // Morph fades CONTENT late instead of the surface: the membrane pretends to be the
        // notch, and a translucent notch breaks the illusion. Other styles fade the whole
        // surface and keep content at full alpha.
        var contentAlpha: CGFloat = 1.0
        var surfaceAlpha = max(0.0, min(1.0, p / 0.65))

        switch revealStyle {
        case "morph" where notchInfo.hasPhysicalNotch:
            // Membrane: phase A stays glued to the screen top (starting entirely inside the
            // notch cutout, i.e. invisible) while the bottom edge and width stretch to the
            // pill's; phase B detaches - the top edge peels off the notch and travels down
            // to the pill's resting top, opening the aura gap. Spring overshoot past p=1
            // squashes the just-detached droplet by a few percent before it settles.
            // Mapping continuity at the split and radius validity are Python-verified.
            let hostTop = hostBounds.height
            let notchBottom = hostTop - notchInfo.rect.height
            let pillBottom = pillTop - HUDMetrics.pillHeight
            let split: CGFloat = 0.55
            if p < split {
                let t = p / split
                let bottom = notchBottom + (pillBottom - notchBottom) * t
                let pw = notchInfo.rect.width + (w - notchInfo.rect.width) * t
                rect = NSRect(x: (hostBounds.width - pw) / 2.0, y: bottom, width: pw, height: hostTop - bottom)
                radius = 14.0 + (HUDMetrics.pillHeight / 2.0 - 14.0) * t
            } else {
                let t = (p - split) / (1.0 - split)
                let top = hostTop + (pillTop - hostTop) * t
                rect = NSRect(x: (hostBounds.width - w) / 2.0, y: pillBottom, width: w, height: top - pillBottom)
                radius = HUDMetrics.pillHeight / 2.0
            }
            radius = min(radius, rect.height / 2.0)
            contentAlpha = max(0.0, min(1.0, (p - 0.7) / 0.3))
            surfaceAlpha = min(1.0, p / 0.12)

        default:
            var pw = w
            var ph = HUDMetrics.pillHeight
            var lift: CGFloat = 0.0
            switch revealStyle {
            case "drift":
                lift = 4.0 * (1.0 - p)
            case "bloom":
                let s = 0.88 + 0.12 * p
                pw = w * s
                ph = HUDMetrics.pillHeight * s
            case "unfurl":
                ph = HUDMetrics.pillHeight * (0.70 + 0.30 * p)
            default:
                // "slide" - also the fallback for unknown styles and for morph on displays
                // with no physical notch to emerge from.
                lift = 10.0 * (1.0 - p)
            }
            // Top edge pinned: overshoot expressed as height/size with the top fixed can
            // never open a gap between the pill and the notch above it.
            rect = NSRect(x: (hostBounds.width - pw) / 2.0, y: pillTop - ph + lift, width: pw, height: ph)
            radius = ph / 2.0
        }

        let pw = rect.width
        let ph = rect.height
        pillWrapper.frame = rect
        pillClip.frame = pillWrapper.bounds
        pillClip.layer?.cornerRadius = radius
        lockRingLayer.frame = pillClip.bounds
        if lockRingSize != pillClip.bounds.size {
            lockRingSize = pillClip.bounds.size
            lockRingLayer.path = Self.lockRingPath(in: pillClip.bounds, cornerRadius: radius, inset: 1.5)
        }
        materialView.frame = pillClip.bounds
        backplateView.frame = pillClip.bounds
        // Content is top-anchored so unfurl and morph reveal it with the moving top edge.
        orbIcon.frame = NSRect(x: 16, y: ph - 25, width: 18, height: 18)
        headerLabel.frame = NSRect(x: 38, y: ph - 25, width: 230, height: 16)
        waveformView.frame = NSRect(x: pw - 48, y: ph - 26, width: 32, height: 16)
        transcriptLabel.frame = NSRect(x: 16, y: ph - 45, width: pw - 32, height: 20)
        orbIcon.alphaValue = contentAlpha
        headerLabel.alphaValue = contentAlpha
        waveformView.alphaValue = contentAlpha
        transcriptLabel.alphaValue = contentAlpha

        pillWrapper.layer?.shadowPath = CGPath(
            roundedRect: pillWrapper.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Fade completes early in the travel, so arrival reads as motion, not opacity.
        // The drop shadow grounds the pill against the bezel on notch displays; on a
        // no-notch wallpaper it reads as a black ring between the pill and the aura's
        // light, so the aura alone carries the grounding there.
        let shadowStrength: CGFloat = notchInfo.hasPhysicalNotch ? 0.55 : 0.0
        pillWrapper.layer?.shadowOpacity = Float(shadowStrength * surfaceAlpha)
        if !reduceMotion {
            // Privacy mode is aura-only: the glow states and earcons carry everything; a
            // pill showing placeholder text is pure noise on a shared screen.
            hostView.alphaValue = privacyMode ? 0.0 : surfaceAlpha
            notchGlowView.alphaValue = surfaceAlpha
        }
        if !notchInfo.hasPhysicalNotch {
            notchGlowView.pillSize = CGSize(width: pw, height: ph)
        }
    }

    // MARK: Hold-to-lock rim

    // Progress rides the wall clock, not a spring: the ring must close at the same instant
    // the app's lock timer fires, whatever the tick cadence. The hue walks the orb's own
    // Siri spectrum as the sweep advances (cyan at the start, amber as it closes) so the
    // colour itself tells time and hands off into the gold lock flare; the last 15%
    // brightens so the closing moment reads as imminent rather than as loading.
    private func updateLockRing(now: CFTimeInterval, dt: CGFloat) {
        if locked {
            lockPulse.step(dt: dt)
            let pulse = max(0.0, min(1.0, lockPulse.value))
            lockRingLayer.strokeColor = AppleDesign.appleGold.cgColor
            lockRingLayer.strokeEnd = 1.0
            lockRingLayer.lineWidth = 2.0 + 1.5 * pulse
            lockRingLayer.opacity = Float(0.18 + 0.82 * pulse)
            if now >= lockHintUntil, let text = deferredLiveText {
                deferredLiveText = nil
                updateLiveText(text)
            }
            return
        }
        guard let lockAfter = lockAfter, lockAfter > 0 else { return }
        let progress = max(0.0, min(1.0, CGFloat((now - listenStart) / lockAfter)))
        let closing = max(0.0, min(1.0, (progress - 0.85) / 0.15))
        // Spectrum runs cyan → indigo → magenta → amber over [0, 0.75]; stop short of the
        // wrap back to cyan so the ring never cools off right before it locks.
        lockRingLayer.strokeColor = AppleDesign.siriSpectrum(at: progress * 0.75).cgColor
        lockRingLayer.strokeEnd = progress
        lockRingLayer.opacity = Float(0.35 + 0.55 * closing * closing)
    }

    // Capsule outline starting at top-center, running clockwise (layer space is y-up, so
    // clockwise is decreasing angle). Inset keeps the whole stroke inside the clip.
    private static func lockRingPath(in bounds: CGRect, cornerRadius: CGFloat, inset: CGFloat) -> CGPath {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let r = max(0.0, min(cornerRadius - inset, min(rect.width, rect.height) / 2.0))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func clearLockRing() {
        locked = false
        lockAfter = nil
        deferredLiveText = nil
        lockRingLayer.strokeEnd = 0.0
        lockRingLayer.lineWidth = 2.0
        lockRingLayer.opacity = 0.0
    }

    // MARK: State typography

    // Eyebrow state word: uppercase micro-type with wide tracking (the NOW PLAYING idiom).
    private func setHeader(_ text: String, color: NSColor) {
        headerLabel.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
                .foregroundColor: color,
                .kern: 1.1,
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
                .paragraphStyle: paragraph,
            ]
        )
        if caret {
            body.append(
                NSAttributedString(
                    string: " ▏",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                        .foregroundColor: AppleDesign.siriCyan,
                        .paragraphStyle: paragraph,
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

    // Apple crossfades every text swap; streaming word updates are excluded - a fade per
    // word would strobe. Discrete state changes only.
    private func crossfadeTextChange() {
        guard !reduceMotion else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        headerLabel.layer?.add(fade, forKey: "textFade")
        transcriptLabel.layer?.add(fade, forKey: "textFade")
    }

    // MARK: States

    // lockAfter: seconds of holding after which the app locks the turn; the rim ring sweeps
    // over exactly that span. nil = hold-to-lock off, no ring.
    func showListening(lockAfter: TimeInterval? = nil) {
        hideWorkItem?.cancel()
        shownTarget = true

        clearLockRing()
        lockPulse.value = 0.0
        lockPulse.velocity = 0.0
        lockPulse.target = 0.0
        lockHintUntil = 0
        listenStart = CACurrentMediaTime()
        // The ring needs the display tick, which reduced motion never starts while listening.
        if !reduceMotion, let lockAfter = lockAfter, lockAfter > 0 {
            self.lockAfter = lockAfter
        }

        notchGlowView.state = .listening
        notchGlowView.audioLevel = 0.0
        orbIcon.state = .listening
        orbIcon.audioLevel = 0.0
        setHeader("Listening", color: NSColor(white: 1.0, alpha: 0.55))
        // The pill appears on key-down, so the user is already holding: say what to do next.
        setTranscript("Speak, then release to paste", color: NSColor(white: 1.0, alpha: 0.45), caret: false)
        waveformView.reset()

        // A fresh entrance starts collapsed at rest; a retarget mid-exit keeps the spring's
        // live position and velocity, so the pill turns around instead of restarting.
        presence.stiffness = 420
        presence.dampingRatio = Self.entranceDamping(for: revealStyle)
        if presence.value < 0.05 {
            presence.value = 0.0
            presence.velocity = 0.0
            widthSpring.value = HUDMetrics.minPillWidth
            widthSpring.velocity = 0.0
        }
        presence.target = 1.0
        widthSpring.target = HUDMetrics.minPillWidth

        if reduceMotion {
            presence.snap()
            widthSpring.snap()
            applyFrame()
            hostView.alphaValue = 0.0
            notchGlowView.alphaValue = 0.0
            notchPanel.orderFrontRegardless()
            if !privacyMode {
                hostPanel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                if !self.privacyMode {
                    self.hostView.animator().alphaValue = 1.0
                }
                self.notchGlowView.animator().alphaValue = 1.0
            }
            return
        }

        applyFrame()
        notchPanel.orderFrontRegardless()
        if !privacyMode {
            hostPanel.orderFrontRegardless()
        }
        startTick()
    }

    // Slide and drift settle cleanly; bloom takes a soft overshoot; morph gets a subtle
    // droplet squash on detach; unfurl is the bounciest.
    private static func entranceDamping(for style: String) -> CGFloat {
        switch style {
        case "bloom": return 0.80
        case "morph": return 0.75
        case "unfurl": return 0.55
        default: return 1.0
        }
    }

    func updateAudioLevel(db: Double) {
        let norm = max(0.0, min(1.0, CGFloat((db + 55.0) / 45.0)))
        notchGlowView.audioLevel = norm
        orbIcon.audioLevel = norm
        waveformView.updateLevel(db: db)
    }

    // The hold has locked: the closed rim flares and settles to a faint resting ring, the
    // orb becomes a padlock, and the copy says the two things that matter now. The mic is
    // still open, so the aura and waveform keep their listening behaviour.
    func showLocked() {
        guard shownTarget else { return }
        locked = true
        lockAfter = nil
        lockPulse.value = 1.0
        lockPulse.velocity = 0.0
        lockPulse.target = 0.0
        lockRingLayer.strokeEnd = 1.0
        lockRingLayer.strokeColor = AppleDesign.appleGold.cgColor
        if reduceMotion {
            lockRingLayer.lineWidth = 2.0
            lockRingLayer.opacity = 0.18
        }
        orbIcon.state = .locked

        crossfadeTextChange()
        setHeader("Locked", color: AppleDesign.appleGold)
        setTranscript(Self.lockHint, color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        // Hold the hint long enough to read; streamed words queue behind it (tick flushes
        // them). Reduced motion has no tick to flush with, so it skips the hold.
        lockHintUntil = reduceMotion ? 0 : CACurrentMediaTime() + 1.8
        let needed = neededWidth(forText: Self.lockHint)
        if needed > widthSpring.target + 8.0 {
            widthSpring.target = needed
            if reduceMotion {
                widthSpring.snap()
                applyFrame()
            } else {
                startTick()
            }
        }
    }

    private func neededWidth(forText text: String) -> CGFloat {
        let font = transcriptLabel.font ?? NSFont.systemFont(ofSize: 13.5)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return max(HUDMetrics.minPillWidth, min(HUDMetrics.maxPillWidth, textWidth + 64.0))
    }

    func updateLiveText(_ text: String) {
        if locked && CACurrentMediaTime() < lockHintUntil {
            deferredLiveText = text
            return
        }

        // Privacy mode: acknowledge that speech is landing without rendering a word of it.
        // The pill also stays at minimum width - nothing to read, nothing to grow for.
        if privacyMode {
            setTranscript("Speaking…", color: NSColor(white: 1.0, alpha: 0.85), caret: true)
            return
        }

        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }

        // While streaming, the newest words matter most: truncate at the head so the tail
        // of the sentence is always visible, with a slim caret marking the live edge.
        setTranscript(clean, color: .white, caret: true, truncation: .byTruncatingHead)

        // Fluid auto-expansion based on text width. Once the target is at max width it can
        // only stay there until the next showListening resets it, so stop paying the
        // full-transcript measurement on every interim update.
        if widthSpring.target < HUDMetrics.maxPillWidth {
            let needed = neededWidth(forText: clean)
            if abs(needed - widthSpring.target) > 8.0 {
                widthSpring.target = needed
                if reduceMotion {
                    widthSpring.snap()
                    applyFrame()
                } else {
                    startTick()
                }
            }
        }
    }

    func showProcessing() {
        hideWorkItem?.cancel()
        // Words still queued behind the lock hint are the freshest transcript there is.
        let deferred = deferredLiveText
        clearLockRing()
        notchGlowView.state = .processing
        orbIcon.state = .processing

        crossfadeTextChange()
        setHeader("Polishing", color: AppleDesign.siriCyan)
        // Keep the user's words on screen, just dimmed - wiping them for a status message
        // makes the pill feel like it lost the dictation.
        let existing = deferred?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? currentTranscriptText
        if privacyMode || existing.isEmpty || existing == "Speak, then release to paste" || existing == Self.lockHint {
            setTranscript("Polishing…", color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        } else {
            setTranscript(existing, color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        }
        waveformView.reset()
    }

    func showSuccess(text: String) {
        hideWorkItem?.cancel()
        clearLockRing()
        notchGlowView.state = .success
        orbIcon.state = .success
        notchGlowView.emitSuccessRipple()

        crossfadeTextChange()
        setHeader("Pasted", color: AppleDesign.appleGreen)
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        setTranscript(privacyMode || clean.isEmpty ? "Done" : clean, color: .white, caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    func showError(message: String) {
        hideWorkItem?.cancel()
        clearLockRing()
        notchGlowView.state = .error
        orbIcon.state = .error

        crossfadeTextChange()
        setHeader("Error", color: AppleDesign.appleCoral)
        setTranscript(message, color: NSColor(white: 1.0, alpha: 0.85), caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }

    func hide() {
        shownTarget = false
        clearLockRing()
        // Exits are brisker than entrances: stiffer spring, critically damped, retracing the
        // entrance mapping in reverse (each style exits the way it arrived).
        presence.stiffness = 700
        presence.dampingRatio = 1.0
        presence.target = 0.0

        if reduceMotion {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.16
                    self.hostView.animator().alphaValue = 0.0
                    self.notchGlowView.animator().alphaValue = 0.0
                },
                completionHandler: {
                    if !self.shownTarget {
                        self.presence.snap()
                        self.hostPanel.orderOut(nil)
                        self.notchPanel.orderOut(nil)
                    }
                })
            return
        }
        startTick()
    }
}
