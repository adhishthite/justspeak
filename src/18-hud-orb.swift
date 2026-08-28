// MARK: - Apple Intelligence Living Siri Orb View

final class AppleIntelligenceOrbView: NSView {
    enum OrbState {
        case listening
        case processing
        case success
        case error
        case locked
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    // Driven per display frame by FloatingHUD's spring tick; speeds are per-second so any
    // tick cadence renders the same tempo.
    func advance(dt: CGFloat) {
        let speed: CGFloat = (state == .processing) ? 1.8 : 0.60
        phase = (phase + speed * dt).truncatingRemainder(dividingBy: 1.0)
        needsDisplay = true
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

        case .locked:
            drawAppleLock(in: context, center: center)
        }
    }

    private func drawLivingOrb(in context: CGContext, center: CGPoint, maxRadius: CGFloat) {
        let baseRadius = maxRadius * (0.75 + 0.35 * audioLevel)
        let colorSpace = AppleDesign.p3ColorSpace

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

            let colors =
                [
                    lobeColor.withAlphaComponent(0.85).cgColor,
                    lobeColor.withAlphaComponent(0.0).cgColor,
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

    // Padlock in the checkmark's idiom: one stroke weight, one glow, gold for "held".
    private func drawAppleLock(in context: CGContext, center: CGPoint) {
        let bodyRect = CGRect(x: center.x - 5.0, y: center.y - 6.0, width: 10.0, height: 7.5)
        let body = CGPath(roundedRect: bodyRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)

        let r: CGFloat = 3.2
        let hinge = CGPoint(x: center.x, y: bodyRect.maxY + 1.6)
        let shackle = CGMutablePath()
        shackle.move(to: CGPoint(x: center.x - r, y: bodyRect.maxY - 0.5))
        shackle.addLine(to: CGPoint(x: center.x - r, y: hinge.y))
        shackle.addArc(center: hinge, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        shackle.addLine(to: CGPoint(x: center.x + r, y: bodyRect.maxY - 0.5))

        context.saveGState()
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.appleGold.withAlphaComponent(0.85).cgColor)
        context.setFillColor(AppleDesign.appleGold.cgColor)
        context.addPath(body)
        context.fillPath()
        context.setStrokeColor(AppleDesign.appleGold.cgColor)
        context.setLineWidth(2.0)
        context.setLineCap(.round)
        context.addPath(shackle)
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
