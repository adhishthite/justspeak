// MARK: - Hotkey & Global Input Monitor (with Tap Auto-Recovery)

final class HotkeyManager {
    enum KeyBinding {
        case rightOption
        case leftOption
        case rightControl
        case leftControl
        case rightCmd
        case leftCmd
        case fn
        case fKey(CGKeyCode)
        case custom(CGKeyCode)

        static func from(string: String) -> KeyBinding {
            switch string.lowercased() {
            case "right_option", "right_alt", "roption": return .rightOption
            case "left_option", "left_alt", "loption": return .leftOption
            case "right_control", "right_ctrl", "rctrl": return .rightControl
            case "left_control", "left_ctrl", "lctrl": return .leftControl
            case "right_cmd", "right_command", "rcmd": return .rightCmd
            case "left_cmd", "left_command", "lcmd": return .leftCmd
            case "fn", "globe": return .fn
            case "f13": return .fKey(0x69)
            case "f14": return .fKey(0x6B)
            case "f15": return .fKey(0x71)
            case "f16": return .fKey(0x6A)
            case "f17": return .fKey(0x40)
            case "f18": return .fKey(0x4F)
            case "f19": return .fKey(0x50)
            case "f20": return .fKey(0x5A)
            default:
                if let code = UInt16(string) {
                    return .custom(CGKeyCode(code))
                }
                return .rightOption
            }
        }

        var name: String {
            switch self {
            case .rightOption: return "Right Option (⌥ Right)"
            case .leftOption: return "Left Option (⌥ Left)"
            case .rightControl: return "Right Control (⌃ Right)"
            case .leftControl: return "Left Control (⌃ Left)"
            case .rightCmd: return "Right Command (⌘ Right)"
            case .leftCmd: return "Left Command (⌘ Left)"
            case .fn: return "Fn / Globe (🌐)"
            case .fKey(let code): return "F-Key (keyCode: \(code))"
            case .custom(let code): return "Custom Key (keyCode: \(code))"
            }
        }
    }

    private let binding: KeyBinding
    private let mode: String
    private var isKeyDown: Bool = false
    private var lastStateChangeTime: CFAbsoluteTime = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    init(binding: KeyBinding, mode: String) {
        self.binding = binding
        self.mode = mode
    }

    func start() -> Bool {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                    // Auto-recover tap if disabled by macOS timeout
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let t = manager.eventTap {
                            CGEvent.tapEnable(tap: t, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    manager.handleCGEvent(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: selfPointer
            )
        else {
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch binding {
        case .rightOption:
            if type == .flagsChanged && keyCode == 61 {
                let isPressed = flags.contains(.maskAlternate)
                updateKeyState(pressed: isPressed)
            }
        case .leftOption:
            if type == .flagsChanged && keyCode == 58 {
                let isPressed = flags.contains(.maskAlternate)
                updateKeyState(pressed: isPressed)
            }
        case .rightControl:
            if type == .flagsChanged && keyCode == 62 {
                let isPressed = flags.contains(.maskControl)
                updateKeyState(pressed: isPressed)
            }
        case .leftControl:
            if type == .flagsChanged && keyCode == 59 {
                let isPressed = flags.contains(.maskControl)
                updateKeyState(pressed: isPressed)
            }
        case .rightCmd:
            if type == .flagsChanged && keyCode == 54 {
                let isPressed = flags.contains(.maskCommand)
                updateKeyState(pressed: isPressed)
            }
        case .leftCmd:
            if type == .flagsChanged && keyCode == 55 {
                let isPressed = flags.contains(.maskCommand)
                updateKeyState(pressed: isPressed)
            }
        case .fn:
            if type == .flagsChanged && keyCode == 63 {
                let isPressed = flags.contains(.maskSecondaryFn)
                updateKeyState(pressed: isPressed)
            }
        case .fKey(let targetCode), .custom(let targetCode):
            if keyCode == targetCode {
                if type == .keyDown {
                    updateKeyState(pressed: true)
                } else if type == .keyUp {
                    updateKeyState(pressed: false)
                }
            }
        }
    }

    private func updateKeyState(pressed: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        if mode == "toggle" {
            // Both toggle transitions fire on a press edge, so the 80ms debounce applies to both.
            guard (now - lastStateChangeTime) > 0.08 else { return }  // 80ms debounce
            if pressed && !isKeyDown {
                isKeyDown = true
                lastStateChangeTime = now
                onKeyDown?()
            } else if pressed && isKeyDown {
                isKeyDown = false
                lastStateChangeTime = now
                onKeyUp?()
            }
        } else {
            // Push-to-Talk (Hold): debounce only the press edge. A release must never be
            // swallowed - dropping it would leave isKeyDown stuck true (mic stuck recording)
            // after a press+release faster than the debounce window.
            if pressed && !isKeyDown {
                guard (now - lastStateChangeTime) > 0.08 else { return }  // 80ms debounce
                isKeyDown = true
                lastStateChangeTime = now
                onKeyDown?()
            } else if !pressed && isKeyDown {
                isKeyDown = false
                lastStateChangeTime = now
                onKeyUp?()
            }
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}
