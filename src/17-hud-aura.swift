// MARK: - Apple Intelligence Glowing Notch Bezel Aura (Hardware Bezel Illumination)

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
            let speed: CGFloat = (self.state == .processing) ? 0.024 : 0.007
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
        let leftX = (bounds.width - notchRect.width) / 2.0
        let rightX = leftX + notchRect.width
        
        // 16-Stop Continuous Apple Intelligence Chromatic Gradient
        let stops = 16
        var cgColors: [CGColor] = []
        var locations: [CGFloat] = []
        for i in 0...stops {
            let loc = CGFloat(i) / CGFloat(stops)
            let color: NSColor
            if state == .success {
                color = AppleDesign.appleGreen
            } else if state == .error {
                color = AppleDesign.appleCoral
            } else {
                color = AppleDesign.siriSpectrum(at: loc + phase)
            }
            cgColors.append(color.cgColor)
            locations.append(loc)
        }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: locations) else { return }
        
        // 1. Layer 1: Ethereal Atmospheric Aurora Bloom
        let auraBlur: CGFloat = (state == .listening) ? (16.0 + 20.0 * audioLevel) : 16.0
        let auraWidth: CGFloat = (state == .listening) ? (7.0 + 8.0 * audioLevel) : 7.0
        let dominantGlowColor: NSColor
        if state == .success {
            dominantGlowColor = AppleDesign.appleGreen
        } else if state == .error {
            dominantGlowColor = AppleDesign.appleCoral
        } else {
            dominantGlowColor = AppleDesign.siriSpectrum(at: phase + 0.5)
        }
        
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -3),
            blur: auraBlur,
            color: dominantGlowColor.withAlphaComponent(0.70 + 0.25 * audioLevel).cgColor
        )
        context.addPath(path)
        context.setLineWidth(auraWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: leftX - 16, y: 0),
            end: CGPoint(x: rightX + 16, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
        
        // 2. Layer 2: Precision Apple Intelligence Chromatic Ribbon
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(2.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: leftX - 16, y: 0),
            end: CGPoint(x: rightX + 16, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
        
        // 3. Layer 3: Refractive Specular Platinum Core Line
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.95).cgColor)
        context.setLineWidth(0.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}

