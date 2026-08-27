// MARK: - macOS Permissions Validator

struct PermissionChecker {
    static func verifyAll() -> (accessibility: Bool, microphone: Bool) {
        let isAxTrusted = AXIsProcessTrusted()

        var isMicAuthorized = false
        if #available(macOS 14.0, *) {
            isMicAuthorized = (AVAudioApplication.shared.recordPermission == .granted)
        } else {
            isMicAuthorized = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        }

        return (isAxTrusted, isMicAuthorized)
    }

    static func printDetailedStatus() {
        print("\n\(ANSI.bold)════════════════════════════════════════════════════════════════════════════\(ANSI.reset)")
        print("\(ANSI.bold)  JustSpeak macOS Permissions Diagnostic\(ANSI.reset)")
        print("\(ANSI.bold)════════════════════════════════════════════════════════════════════════════\(ANSI.reset)\n")

        let (ax, mic) = verifyAll()

        let axStatus = ax ? "\(ANSI.green)✓ GRANTED\(ANSI.reset)" : "\(ANSI.red)✗ NOT GRANTED\(ANSI.reset)"
        let micStatus = mic ? "\(ANSI.green)✓ GRANTED\(ANSI.reset)" : "\(ANSI.red)✗ NOT GRANTED\(ANSI.reset)"

        print("  1. Accessibility & CGEventTap:   [\(axStatus)]")
        print("  2. Microphone Access:            [\(micStatus)]")
        print("  3. Input Monitoring (Terminal):  [\(ax ? "\(ANSI.green)✓ ACTIVE\(ANSI.reset)" : "\(ANSI.yellow)? CHECK SETTINGS\(ANSI.reset)")]\n")

        if !ax || !mic {
            print("\(ANSI.yellow)\(ANSI.bold)How to grant required permissions on macOS:\(ANSI.reset)")
            if !ax {
                print("  • \(ANSI.bold)Accessibility:\(ANSI.reset) System Settings → Privacy & Security → Accessibility → Toggle ON your Terminal app (Terminal / iTerm2 / VS Code / Cursor / Ghostty)")
                print("  • \(ANSI.bold)Input Monitoring:\(ANSI.reset) System Settings → Privacy & Security → Input Monitoring → Toggle ON your Terminal app")

                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options)
            }
            if !mic {
                print("  • \(ANSI.bold)Microphone:\(ANSI.reset) System Settings → Privacy & Security → Microphone → Toggle ON your Terminal app")
            }
            print("")
        } else {
            print("\(ANSI.green)\(ANSI.bold)All required macOS permissions are properly configured! Ready to speak.\(ANSI.reset)\n")
        }
    }
}
