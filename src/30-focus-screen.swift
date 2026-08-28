// MARK: - Focus Screen Resolver

/// Which display should host the HUD for this turn. NSScreen.main is "the screen with our key
/// window" - JustSpeak has none, so it degrades to the menu-bar display and the notch lights
/// up while the user types on the external monitor. The dictation lands where the frontmost
/// app's focused window is, so that window's bounds (one AX round-trip, hard-capped at 50ms in
/// case the app is hung) pick the screen; the pointer is the fallback for apps that expose no
/// focused window.
struct FocusScreenResolver {
    static func resolve(frontmostPID pid: pid_t?) -> NSScreen? {
        if let pid = pid, let frame = focusedWindowFrame(pid: pid),
            let screen = screenContaining(frame)
        {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // Largest-overlap wins: a window straddling two displays follows its majority.
    private static func screenContaining(_ frame: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best
    }

    // AX reports window bounds in global top-left coordinates (y grows downward from the top
    // of the primary display); NSScreen frames are bottom-left, so flip against the primary
    // screen's height. `screens.first` is the primary (origin 0,0) by AppKit contract.
    private static func focusedWindowFrame(pid: pid_t) -> NSRect? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowAny = windowRef, CFGetTypeID(windowAny) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowAny as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posAny = posRef, let sizeAny = sizeRef,
            CFGetTypeID(posAny) == AXValueGetTypeID(), CFGetTypeID(sizeAny) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAny as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeAny as! AXValue, .cgSize, &size),
            size.width > 0, size.height > 0
        else { return nil }

        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - origin.y - size.height
        return NSRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
    }
}
