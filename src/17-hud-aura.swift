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
    var audioLevel: CGFloat = 0.0  // 0.0 ... 1.0
    // didSet redraw so state changes land even when the shared display tick is stopped
    // (static success/error frames, reduced motion).
    var state: GlowState = .idle {
        didSet {
            needsDisplay = true
        }
    }
    // Displays without a hardware notch have no bezel to illuminate; the aura rings
    // the floating pill instead. pillSize tracks the pill's live width as it expands.
    var pillMode: Bool = false
    var pillSize: CGSize = .zero

    private var phase: CGFloat = 0.0

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

    // Driven by FloatingHUD's single shared 30Hz display tick (the aura and orb used to run
    // independent 60Hz timers). Per-tick increments are doubled from the old 60Hz values so
    // the on-screen tempo is unchanged: one full 5-color loop stays ~14s while listening
    // (each hue holds ~1.7s, fades ~1.1s); processing triples the tempo so the wait reads
    // as activity.
    func advanceFrame() {
        let speed: CGFloat = (state == .processing) ? 0.0072 : 0.0024
        phase = (phase + speed).truncatingRemainder(dividingBy: 1.0)
        needsDisplay = true
    }

    // outset dilates the path beyond the hardware cutout: a stroke centered on the exact
    // notch outline loses its inner half inside the cutout (those pixels don't exist),
    // which reads as a thin hard line with clipped corners. Pushed outward, the full
    // stroke width and its blur land on real wallpaper. Radii grow by the same amount
    // so the dilated path stays parallel to the bezel curve.
    private func createNotchPath(in bounds: NSRect, outset: CGFloat = 0.0) -> CGPath {
        let path = CGMutablePath()
        let cornerRadius: CGFloat = 14.0 + outset
        let outerCornerRadius: CGFloat = 6.0 + outset

        let topY = bounds.height
        let bottomY = bounds.height - notchRect.height - outset
        let leftX = (bounds.width - notchRect.width) / 2.0 - outset
        let rightX = leftX + notchRect.width + 2.0 * outset

        path.move(to: CGPoint(x: leftX - outerCornerRadius, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: topY - outerCornerRadius),
            control: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftX + cornerRadius, y: bottomY),
            control: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX - cornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY + cornerRadius),
            control: CGPoint(x: rightX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX, y: topY - outerCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightX + outerCornerRadius, y: topY),
            control: CGPoint(x: rightX, y: topY))

        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if state == .idle { return }

        // One tint per frame - the Google cycle lives in TIME, not along the stroke.
        let tint: NSColor
        switch state {
        case .success: tint = AppleDesign.googleGreen
        case .error: tint = AppleDesign.googleRed
        default: tint = AppleDesign.googleSpectrum(at: phase)
        }

        // Voice gives the light its breath: a quiet floor so the glow never dies,
        // headroom so speech visibly brightens and lengthens the spill.
        let energy: CGFloat = (state == .listening) ? (0.30 + 0.70 * audioLevel) : 0.55

        if pillMode {
            drawPillAura(context: context, tint: tint, energy: energy)
            return
        }

        let path = createNotchPath(in: self.bounds, outset: 2.5)
        let bottomY = bounds.height - notchRect.height

        // 1. Downward light spill: a wide, shallow pool under the notch, as if the bezel
        // were backlit. A circular radial gradient drawn through a horizontally scaled
        // CTM becomes the ellipse; clipped so no light paints above the bezel line.
        let dropRadius: CGFloat = 38.0 + 28.0 * energy
        let halfSpan = notchRect.width / 2.0 + 46.0
        let centerAlpha: CGFloat = 0.26 + 0.30 * energy

        let colorSpace = AppleDesign.p3ColorSpace
        let poolColors =
            [
                tint.withAlphaComponent(centerAlpha).cgColor,
                tint.withAlphaComponent(centerAlpha * 0.35).cgColor,
                tint.withAlphaComponent(0.0).cgColor,
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

        // 2. Bezel halo: light that falls off with distance from the bezel, not a band.
        strokeHalo(context: context, path: path, tint: tint, energy: energy)
    }

    // The classic SwiftUI glow recipe (a crisp stroke plus two blurred copies of it,
    // voice swelling both width and blur - the construction Talkify's edge glow uses),
    // adapted to Core Graphics: CG cannot blur a stroke directly, so each blurred copy
    // is drawn as a shadow - the source stroke lands two panel-widths off-canvas and
    // only its gaussian shadow shows in view. Wide halo, tight glow, thin rim on top.
    private func strokeHalo(context: CGContext, path: CGPath, tint: NSColor, energy: CGFloat) {
        let shift = bounds.width * 2.0
        var offscreen = CGAffineTransform(translationX: -shift, y: 0)
        let source = path.copy(using: &offscreen) ?? path
        let width = 6.0 + 6.0 * energy
        let blur = 22.0 + 16.0 * energy

        let passes: [(blur: CGFloat, alpha: CGFloat)] = [
            (blur, 0.40 + 0.25 * energy),
            (blur * 0.5, 0.50 + 0.25 * energy),
        ]
        for pass in passes {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: shift, height: 0),
                blur: pass.blur,
                color: tint.withAlphaComponent(pass.alpha).cgColor
            )
            context.addPath(source)
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        }

        // The rim stays faint and thin - the halo carries the light; the line only
        // keeps the edge defined underneath it.
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(tint.withAlphaComponent(0.25 + 0.15 * energy).cgColor)
        context.setLineWidth(width * 0.35)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    // No-notch displays: the halo wraps the pill capsule instead. Even-odd clipping
    // keeps every photon outside the capsule so the pill face stays hardware-black -
    // the clip applies to the shadow passes too.
    private func drawPillAura(context: CGContext, tint: NSColor, energy: CGFloat) {
        let w = pillSize.width
        let h = pillSize.height
        guard w > 0, h > 0 else { return }
        let rect = CGRect(x: (bounds.width - w) / 2.0, y: (bounds.height - h) / 2.0, width: w, height: h)
        let capsule = CGPath(roundedRect: rect, cornerWidth: h / 2.0, cornerHeight: h / 2.0, transform: nil)

        context.saveGState()
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(capsule)
        context.addPath(mask)
        context.clip(using: .evenOdd)

        strokeHalo(context: context, path: capsule, tint: tint, energy: energy)
        context.restoreGState()
    }
}
