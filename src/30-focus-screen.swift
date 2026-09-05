// MARK: - Focus Screen Resolver

/// Which display should host the HUD for this turn. NSScreen.main is "the screen with our key
/// window" - JustSpeak has none, so it degrades to the menu-bar display and the notch lights
/// up while the user types on the external monitor. The dictation lands where the frontmost
/// app's focused window is, so that window's bounds (one AX round-trip, hard-capped at 50ms in
/// case the app is hung) pick the screen; the pointer is the fallback for apps that expose no
/// focused window.
struct FocusScreenResolver {
    private static let lookupQueue = DispatchQueue(label: "com.justspeak.focus", qos: .userInitiated)

    // Capture AppKit state on main; Accessibility IPC runs away from the event loop.
    static func resolve(frontmostPID pid: pid_t?, completion: @escaping (NSScreen?) -> Void) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        lookupQueue.async {
            let frame = pid.flatMap { focusedWindowFrame(pid: $0, primaryTop: primaryTop) }
            DispatchQueue.main.async {
                if let frame = frame, let screen = screenContaining(frame) {
                    completion(screen)
                } else {
                    let mouse = NSEvent.mouseLocation
                    completion(NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
                }
            }
        }
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
    //
    // One 50ms budget covers all three round-trips: the messaging timeout is per request,
    // so each call gets whatever is left, and a hung app costs ~50ms total, not 3x.
    private static let lookupBudget: CFAbsoluteTime = 0.05

    private static func focusedWindowFrame(pid: pid_t, primaryTop: CGFloat) -> NSRect? {
        let deadline = ProcessInfo.processInfo.systemUptime + lookupBudget
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard copyAttribute(appElement, kAXFocusedWindowAttribute, deadline: deadline, into: &windowRef),
            let windowAny = windowRef, CFGetTypeID(windowAny) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowAny as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard copyAttribute(window, kAXPositionAttribute, deadline: deadline, into: &posRef),
            copyAttribute(window, kAXSizeAttribute, deadline: deadline, into: &sizeRef),
            let posAny = posRef, let sizeAny = sizeRef,
            CFGetTypeID(posAny) == AXValueGetTypeID(), CFGetTypeID(sizeAny) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAny as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeAny as! AXValue, .cgSize, &size),
            size.width > 0, size.height > 0
        else { return nil }

        let flippedY = primaryTop - origin.y - size.height
        return NSRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
    }

    // Refuses outright once the budget is spent (a 0 timeout would mean "system default",
    // not "none"); a few ms of floor keeps a sub-millisecond remainder from being pointless.
    private static func copyAttribute(
        _ element: AXUIElement, _ attribute: String, deadline: CFAbsoluteTime, into ref: inout CFTypeRef?
    ) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0.002 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
    }
}
