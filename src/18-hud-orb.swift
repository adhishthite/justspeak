// MARK: - Apple Intelligence Living Siri Orb View

final class AppleIntelligenceOrbView: NSView {
    enum OrbState {
        case listening
        case processing
        case success
        case error
    }
    
    var state: OrbState = .listening {
        didSet {
            needsDisplay = true
        }
    }
    
    var audioLevel: CGFloat = 0.0 {
        didSet {
            needsDisplay = true
        }
    }
    
    private var phase: CGFloat = 0.0
    private var displayTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    func startAnimation() {
        displayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let speed: CGFloat = (self.state == .processing) ? 0.030 : 0.010
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
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = min(bounds.width, bounds.height) / 2.0 - 1.0
        
        switch state {
        case .listening:
            drawLivingOrb(in: context, center: center, maxRadius: maxRadius)
            
        case .processing:
            drawProcessingSwirl(in: context, center: center, maxRadius: maxRadius)
            
        case .success:
            drawAppleCheckmark(in: context, center: center, size: maxRadius * 2.0)
            
        case .error:
            drawAppleAlert(in: context, center: center, size: maxRadius * 2.0)
        }
    }
    
    private func drawLivingOrb(in context: CGContext, center: CGPoint, maxRadius: CGFloat) {
        let baseRadius = maxRadius * (0.75 + 0.35 * audioLevel)
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        
        // 3 Overlapping pulsating chromatic lobes
        let lobes = 3
        for i in 0..<lobes {
            let lobeAngle = CGFloat(i) * (2.0 * .pi / CGFloat(lobes)) + phase * 2.0 * .pi
            let offsetDist = 2.0 * (1.0 + audioLevel)
            let lobeCenter = CGPoint(
                x: center.x + offsetDist * cos(lobeAngle),
                y: center.y + offsetDist * sin(lobeAngle)
            )
            let lobeColor = AppleDesign.siriSpectrum(at: phase + CGFloat(i) / CGFloat(lobes))
            
            let colors = [
                lobeColor.withAlphaComponent(0.85).cgColor,
                lobeColor.withAlphaComponent(0.0).cgColor
            ] as CFArray
            let locs: [CGFloat] = [0.0, 1.0]
            if let radialGrad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locs) {
                context.saveGState()
                context.drawRadialGradient(
                    radialGrad,
                    startCenter: lobeCenter,
                    startRadius: 0,
                    endCenter: lobeCenter,
                    endRadius: baseRadius,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                context.restoreGState()
            }
        }
        
        // Luminous Specular Core
        context.saveGState()
        context.setFillColor(NSColor(white: 1.0, alpha: 0.95).cgColor)
        context.setShadow(offset: .zero, blur: 4.0, color: NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 2.0, y: center.y - 2.0, width: 4.0, height: 4.0))
        context.restoreGState()
    }
    
    private func drawProcessingSwirl(in context: CGContext, center: CGPoint, maxRadius: CGFloat) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: phase * 2.0 * .pi)
        context.translateBy(x: -center.x, y: -center.y)
        
        let path = CGMutablePath()
        let r = maxRadius * 0.85
        path.addArc(center: center, radius: r, startAngle: 0, endAngle: 1.5 * .pi, clockwise: false)
        
        context.setStrokeColor(AppleDesign.siriCyan.cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.siriCyan.withAlphaComponent(0.85).cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
    
    private func drawAppleCheckmark(in context: CGContext, center: CGPoint, size: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - 4.5, y: center.y - 0.5))
        path.addLine(to: CGPoint(x: center.x - 1.5, y: center.y - 3.5))
        path.addLine(to: CGPoint(x: center.x + 4.5, y: center.y + 3.5))
        
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.appleGreen.withAlphaComponent(0.85).cgColor)
        context.setStrokeColor(AppleDesign.appleGreen.cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
    
    private func drawAppleAlert(in context: CGContext, center: CGPoint, size: CGFloat) {
        let path = CGMutablePath()
        let r = size / 2.0 - 2.0
        path.move(to: CGPoint(x: center.x, y: center.y + r))
        path.addLine(to: CGPoint(x: center.x + r, y: center.y - r))
        path.addLine(to: CGPoint(x: center.x - r, y: center.y - r))
        path.closeSubpath()
        
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.appleCoral.withAlphaComponent(0.85).cgColor)
        context.setFillColor(AppleDesign.appleCoral.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

