// MARK: - Apple Dynamic Island Obsidian Acrylic Backplate View

final class AppleIslandBackplateView: NSView {
    // The specular rim sells the pill as glass beside the bezel; wrapped in the pill-mode
    // aura it is a second, white outline fighting the tinted hairline, so it's off there.
    var specularRim: Bool = true
    // Near-opaque beside the bezel; lowered in pill mode so the material underneath shows.
    var baseAlpha: CGFloat = 0.97

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        if #available(macOS 10.15, *) {
            self.layer?.cornerCurve = .continuous
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        if #available(macOS 10.15, *) {
            self.layer?.cornerCurve = .continuous
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let cornerRadius = bounds.height / 2.0
        let pillPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // 1. Deep Obsidian Base - near-opaque so the pill matches the notch's hardware black
        context.saveGState()
        context.addPath(pillPath)
        context.setFillColor(NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.059, alpha: baseAlpha).cgColor)
        context.fillPath()
        context.restoreGState()

        guard specularRim else { return }

        // 2. Continuous Dual-Stage Specular Rim Light Gradient
        let borderPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil)
        context.saveGState()
        context.addPath(borderPath)
        context.setLineWidth(1.0)
        context.replacePathWithStrokedPath()
        context.clip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let strokeColors =
            [
                NSColor(white: 1.0, alpha: 0.28).cgColor,
                NSColor(white: 1.0, alpha: 0.10).cgColor,
                NSColor(white: 1.0, alpha: 0.04).cgColor,
            ] as CFArray
        let strokeLocations: [CGFloat] = [0.0, 0.5, 1.0]
        if let strokeGradient = CGGradient(colorsSpace: colorSpace, colors: strokeColors, locations: strokeLocations) {
            context.drawLinearGradient(
                strokeGradient,
                start: CGPoint(x: bounds.midX, y: bounds.maxY),
                end: CGPoint(x: bounds.midX, y: bounds.minY),
                options: []
            )
        }
        context.restoreGState()
    }
}
