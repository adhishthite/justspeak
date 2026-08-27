// MARK: - Notch Bezel Aura (Downward Light Spill, Google-Color Time Cycle)

final class AppleNotchAuraView: NSView {
    enum GlowState {
        case idle
        case listening
        case processing
        case success
        case error
    }
    
    var notchRect: NSRect = .zero
    var audioLevel: CGFloat = 0.0 // 0.0 ... 1.0
    var state: GlowState = .idle
    
    private var phase: CGFloat = 0.0
    private var displayTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }
    
    func startAnimation() {
        displayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // One full 5-color loop: ~14s while listening (each hue holds ~1.7s, fades ~1.1s);
            // processing triples the tempo so the wait reads as activity.
            let speed: CGFloat = (self.state == .processing) ? 0.0036 : 0.0012
            self.phase = (self.phase + speed).truncatingRemainder(dividingBy: 1.0)
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.displayTimer = timer
    }
    
    func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
    
    private func createNotchPath(in bounds: NSRect) -> CGPath {
        let path = CGMutablePath()
        let cornerRadius: CGFloat = 14.0
        let outerCornerRadius: CGFloat = 6.0
        
        let topY = bounds.height
        let bottomY = bounds.height - notchRect.height
        let leftX = (bounds.width - notchRect.width) / 2.0
        let rightX = leftX + notchRect.width
        
        path.move(to: CGPoint(x: leftX - outerCornerRadius, y: topY))
        path.addQuadCurve(to: CGPoint(x: leftX, y: topY - outerCornerRadius),
                          control: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY + cornerRadius))
        path.addQuadCurve(to: CGPoint(x: leftX + cornerRadius, y: bottomY),
                          control: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX - cornerRadius, y: bottomY))
        path.addQuadCurve(to: CGPoint(x: rightX, y: bottomY + cornerRadius),
                          control: CGPoint(x: rightX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX, y: topY - outerCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rightX + outerCornerRadius, y: topY),
                          control: CGPoint(x: rightX, y: topY))
        
        return path
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if state == .idle { return }

        let path = createNotchPath(in: self.bounds)
        let bottomY = bounds.height - notchRect.height

        // One tint per frame - the Google cycle lives in TIME, not along the stroke.
        let tint: NSColor
        switch state {
        case .success: tint = AppleDesign.googleGreen
        case .error:   tint = AppleDesign.googleRed
        default:       tint = AppleDesign.googleSpectrum(at: phase)
        }

        // Voice gives the light its breath: a quiet floor so the glow never dies,
        // headroom so speech visibly brightens and lengthens the spill.
        let energy: CGFloat = (state == .listening) ? (0.30 + 0.70 * audioLevel) : 0.55

        // 1. Downward light spill: a wide, shallow pool under the notch, as if the bezel
        // were backlit. A circular radial gradient drawn through a horizontally scaled
        // CTM becomes the ellipse; clipped so no light paints above the bezel line.
        let dropRadius: CGFloat = 30.0 + 22.0 * energy
        let halfSpan = notchRect.width / 2.0 + 46.0
        let centerAlpha: CGFloat = 0.26 + 0.30 * energy

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let poolColors = [
            tint.withAlphaComponent(centerAlpha).cgColor,
            tint.withAlphaComponent(centerAlpha * 0.35).cgColor,
            tint.withAlphaComponent(0.0).cgColor
        ] as CFArray
        let poolLocations: [CGFloat] = [0.0, 0.45, 1.0]
        if let pool = CGGradient(colorsSpace: colorSpace, colors: poolColors, locations: poolLocations) {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: bottomY))
            context.translateBy(x: bounds.midX, y: bottomY)
            context.scaleBy(x: halfSpan / dropRadius, y: 1.0)
            context.drawRadialGradient(
                pool,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: dropRadius,
                options: []
            )
            context.restoreGState()
        }

        // 2. Bezel rim: one thin line of the same hue hugging the notch outline, with a
        // soft downward halo - definition, not decoration.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 8.0 + 6.0 * energy,
            color: tint.withAlphaComponent(0.6).cgColor
        )
        context.addPath(path)
        context.setStrokeColor(tint.withAlphaComponent(0.50 + 0.30 * energy).cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}

