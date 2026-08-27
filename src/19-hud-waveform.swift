// MARK: - Apple Siri Fluid Equalizer Waveform View

final class AppleSiriWaveformView: NSView {
    private var levels: [CGFloat] = [0.12, 0.12, 0.12, 0.12]
    private let barCount = 4

    // Tight cyan-to-indigo ramp: one hue family reads as one instrument. A different
    // spectrum color per bar reads as four toys.
    private let barColors: [NSColor] = [
        AppleDesign.siriSpectrum(at: 0.00),
        AppleDesign.siriSpectrum(at: 0.07),
        AppleDesign.siriSpectrum(at: 0.14),
        AppleDesign.siriSpectrum(at: 0.21),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    func updateLevel(db: Double) {
        let norm = max(0.08, min(1.0, CGFloat((db + 55.0) / 45.0)))
        let multipliers: [CGFloat] = [0.65, 1.0, 0.92, 0.60]
        for i in 0..<barCount {
            let target = norm * multipliers[i]
            levels[i] = levels[i] * 0.25 + target * 0.75
        }
        needsDisplay = true
    }

    func reset() {
        levels = [0.12, 0.12, 0.12, 0.12]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let barWidth: CGFloat = 3.0
        let spacing: CGFloat = 3.0
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2.0
        let maxBarHeight = bounds.height - 4.0

        for i in 0..<barCount {
            let barHeight = max(4.0, levels[i] * maxBarHeight)
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let y = (bounds.height - barHeight) / 2.0
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2.0, cornerHeight: barWidth / 2.0, transform: nil)

            context.saveGState()
            let color = barColors[i % barColors.count]
            context.setShadow(offset: .zero, blur: 4.0, color: color.withAlphaComponent(0.60).cgColor)
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }
}
