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
            updateEmitter()
        }
    }
    // Displays without a hardware notch have no bezel to illuminate; the aura rings
    // the floating pill instead. pillSize tracks the pill's live width as it expands.
    var pillMode: Bool = false
    var pillSize: CGSize = .zero

    // Ambient light-dust beneath the notch while listening: a CAEmitterLayer (GPU-composited,
    // no per-frame CPU draw) whose birth rate breathes with the voice. The motes stay white
    // on purpose - they read as dust catching whatever light the aura is currently casting.
    var particlesEnabled: Bool = true
    private var emitterLayer: CAEmitterLayer?

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

    // Driven per display frame by FloatingHUD's spring tick; speeds are per-second so any
    // tick cadence renders the same tempo: one full 5-color loop stays ~14s while listening
    // (each hue holds ~1.7s, fades ~1.1s); processing triples the tempo so the wait reads
    // as activity.
    func advance(dt: CGFloat) {
        let speed: CGFloat = (state == .processing) ? 0.216 : 0.072
        phase = (phase + speed * dt).truncatingRemainder(dividingBy: 1.0)
        needsDisplay = true
        updateEmitter()
    }

    // MARK: Particle motes

    // CAEmitterCell needs a bitmap; build one soft 12px radial disc once.
    private static let moteImage: CGImage? = {
        let size = 12
        guard
            let ctx = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])
        else { return nil }
        let center = CGPoint(x: 6, y: 6)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 6, options: [])
        return ctx.makeImage()
    }()

    private func ensureEmitter() -> CAEmitterLayer? {
        if let existing = emitterLayer { return existing }
        guard let hostLayer = layer, let image = Self.moteImage else { return nil }

        let cell = CAEmitterCell()
        cell.contents = image
        cell.birthRate = 10.0
        cell.lifetime = 1.4
        cell.lifetimeRange = 0.4
        cell.velocity = 26.0
        cell.velocityRange = 12.0
        cell.emissionLongitude = -.pi / 2.0  // straight down (layer coords are y-up)
        cell.emissionRange = 0.35
        cell.yAcceleration = -28.0
        cell.scale = 0.30
        cell.scaleRange = 0.15
        cell.alphaSpeed = -0.8
        cell.color = NSColor.white.withAlphaComponent(0.55).cgColor

        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .line
        emitter.emitterCells = [cell]
        emitter.birthRate = 0.0
        hostLayer.addSublayer(emitter)
        emitterLayer = emitter
        return emitter
    }

    // Runs on state changes and every display tick: re-derives geometry (screen layout can
    // change under us) and breathes the birth rate with the voice. The layer-level birthRate
    // multiplies the cell's, so 0 silences emission without tearing the layer down.
    private func updateEmitter() {
        let active =
            particlesEnabled && state == .listening
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard active, let emitter = ensureEmitter() else {
            emitterLayer?.birthRate = 0.0
            return
        }
        emitter.frame = bounds
        if pillMode {
            guard pillSize.width > 0 else {
                emitter.birthRate = 0.0
                return
            }
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY - pillSize.height / 2.0 - 4.0)
            emitter.emitterSize = CGSize(width: pillSize.width * 0.7, height: 2.0)
        } else {
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height - notchRect.height - 4.0)
            emitter.emitterSize = CGSize(width: notchRect.width * 0.8, height: 2.0)
        }
        emitter.birthRate = Float(0.35 + 0.65 * audioLevel)
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
    //
    // rim/rimWidth: the notch path is already dilated so a stroke centered on it lands
    // fully on wallpaper; the pill capsule is not (the even-odd clip amputates the inner
    // half of anything centered on it), so pill mode passes a hairline on a half-width-
    // outset path plus a tight feather so the edge reads as light meeting glass, not a
    // flat band.
    private func strokeHalo(
        context: CGContext, path: CGPath, tint: NSColor, energy: CGFloat,
        rim: CGPath? = nil, rimWidth: CGFloat? = nil
    ) {
        let shift = bounds.width * 2.0
        var offscreen = CGAffineTransform(translationX: -shift, y: 0)
        let source = path.copy(using: &offscreen) ?? path
        let width = 6.0 + 6.0 * energy
        let blur = 22.0 + 16.0 * energy

        var passes: [(blur: CGFloat, alpha: CGFloat)] = [
            (blur, 0.40 + 0.25 * energy),
            (blur * 0.5, 0.50 + 0.25 * energy),
        ]
        if rim != nil {
            passes.append((3.0, 0.30 + 0.25 * energy))
        }
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
        // keeps the edge defined underneath it. A hairline needs more alpha than a
        // band to register at all.
        let rimPath = rim ?? path
        let lineWidth = rimWidth ?? width * 0.35
        let rimAlpha: CGFloat = rim == nil ? 0.25 + 0.15 * energy : 0.55 + 0.30 * energy
        context.saveGState()
        context.addPath(rimPath)
        context.setStrokeColor(tint.withAlphaComponent(rimAlpha).cgColor)
        context.setLineWidth(lineWidth)
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

        // Hairline centered 0.5pt outside the capsule: its full 1pt width survives the
        // clip and sits flush against the pill's edge.
        let rimRect = rect.insetBy(dx: -0.5, dy: -0.5)
        let rimRadius = h / 2.0 + 0.5
        let rim = CGPath(roundedRect: rimRect, cornerWidth: rimRadius, cornerHeight: rimRadius, transform: nil)
        strokeHalo(context: context, path: capsule, tint: tint, energy: energy, rim: rim, rimWidth: 1.0)
        context.restoreGState()
    }

    // One-shot success punctuation: a stroked copy of the halo path expands outward and fades.
    // Runs as its own CAAnimation so it needs no display-tick frames (success freezes the tick).
    func emitSuccessRipple() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard wantsLayer, let hostLayer = self.layer else { return }

        // Start/end paths share the same construction (createNotchPath, or the capsule math
        // drawPillAura uses) so Core Animation interpolates between them element-for-element
        // instead of cross-fading two unrelated shapes.
        let startPath: CGPath
        let endPath: CGPath
        if pillMode {
            let w = pillSize.width
            let h = pillSize.height
            guard w > 0, h > 0 else { return }
            let rect = CGRect(x: (bounds.width - w) / 2.0, y: (bounds.height - h) / 2.0, width: w, height: h)
            startPath = CGPath(roundedRect: rect, cornerWidth: h / 2.0, cornerHeight: h / 2.0, transform: nil)
            let outerRect = rect.insetBy(dx: -18.0, dy: -18.0)
            let outerRadius = h / 2.0 + 18.0
            endPath = CGPath(roundedRect: outerRect, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        } else {
            startPath = createNotchPath(in: bounds, outset: 2.5)
            endPath = createNotchPath(in: bounds, outset: 22.0)
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = bounds
        // Shape layers rasterize at contentsScale (default 1.0) - inherit the host's so the
        // ring stays crisp on Retina.
        shapeLayer.contentsScale = hostLayer.contentsScale
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.strokeColor = AppleDesign.googleGreen.cgColor
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        // Model values land on the END state before the animation is added, so removing
        // the layer after the animation finishes shows no flash back to the start frame.
        shapeLayer.path = endPath
        shapeLayer.opacity = 0.0
        shapeLayer.lineWidth = 1.0
        hostLayer.addSublayer(shapeLayer)

        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = startPath
        pathAnim.toValue = endPath

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.9
        opacityAnim.toValue = 0.0

        let lineWidthAnim = CABasicAnimation(keyPath: "lineWidth")
        lineWidthAnim.fromValue = 3.0
        lineWidthAnim.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [pathAnim, opacityAnim, lineWidthAnim]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            shapeLayer.removeFromSuperlayer()
        }
        shapeLayer.add(group, forKey: "successRipple")
        CATransaction.commit()
    }
}
