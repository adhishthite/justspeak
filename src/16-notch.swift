// MARK: - Hardware Notch Geometry Detection

struct NotchGeometry {
    let rect: NSRect
    let hasPhysicalNotch: Bool
    
    static func detect(screen: NSScreen) -> NotchGeometry {
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            let height = screen.frame.height - left.origin.y
            let rect = NSRect(
                x: left.maxX,
                y: screen.frame.height - height,
                width: width,
                height: height
            )
            return NotchGeometry(rect: rect, hasPhysicalNotch: true)
        } else {
            let width: CGFloat = 196
            let height: CGFloat = 34
            let rect = NSRect(
                x: (screen.frame.width - width) / 2.0,
                y: screen.frame.height - height,
                width: width,
                height: height
            )
            return NotchGeometry(rect: rect, hasPhysicalNotch: false)
        }
    }
}

