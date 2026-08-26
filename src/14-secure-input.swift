// MARK: - Secure Input Detection

// TN2150: when any app enables secure input (password fields, Terminal's Secure Keyboard
// Entry), synthesized keystrokes and clipboard pastes into it can fail or leak. We refuse
// and fall back to copy-only rather than bypass it.
enum SecureInputMonitor {
    static var isActive: Bool { IsSecureEventInputEnabled() }

    /// The name of the process currently holding secure input, if the window server will say.
    /// The flag is system-wide, so the holder is often NOT the app the user is looking at -
    /// naming it turns "dictation just stopped working" into something actionable.
    static func holderName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in sessions {
            guard let pid = session["kCGSSessionSecureInputPID"] as? Int32, pid != 0 else { continue }
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
        }
        return nil
    }
}

