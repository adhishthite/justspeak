// MARK: - Input Device Catalog (CoreAudio)

/// Enumerates capture-capable CoreAudio devices and describes the one an AVAudioEngine input
/// is actually using. Every Mac with an external display that carries a mic (Studio Display,
/// many webcams) has at least two inputs, and macOS silently picks whichever it made the
/// default - so the choice must be both configurable and logged.
struct InputDeviceCatalog {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let transport: String
        let isDefault: Bool

        var label: String { "\(name) [\(transport)]" }
    }

    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        let defaultID = defaultInputDevice()
        return ids.filter { hasInputStreams($0) }.map { describe($0, isDefault: $0 == defaultID) }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func describe(_ id: AudioDeviceID, isDefault: Bool) -> Device {
        Device(
            id: id,
            name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown Input (\(id))",
            uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
            transport: transportName(id),
            isDefault: isDefault
        )
    }

    // INPUT_DEVICE matching: exact UID first (stable across renames), then case-insensitive
    // substring of the name, so "studio" finds "Studio Display Microphone". Ambiguity
    // resolves to the first match in HAL order; the log line shows what was picked.
    static func match(_ query: String, in devices: [Device]) -> Device? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = devices.first(where: { $0.uid == q }) { return exact }
        let lowered = q.lowercased()
        return devices.first(where: { $0.name.lowercased().contains(lowered) })
    }

    // Lid state from the power-management root (the node `pmset` reads); nil on Macs
    // without a clamshell or when IOKit declines.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return prop.takeRetainedValue() as? Bool
    }

    // INPUT_DEVICE=auto: lid open -> the built-in mic; lid closed -> a physical external one
    // (the default if it already is, else first in HAL order). Virtual/aggregate devices
    // are never auto-picked - name them explicitly. Falls back to the default when the
    // wanted class is absent (no external mic while closed, desktop with no built-in).
    static func autoSelection(in devices: [Device], lidClosed: Bool) -> Device? {
        let builtin = devices.filter { $0.transport == "builtin" }
        let external = devices.filter { !["builtin", "virtual", "aggregate"].contains($0.transport) }
        let wanted = lidClosed ? external : builtin
        return wanted.first(where: { $0.isDefault }) ?? wanted.first ?? devices.first(where: { $0.isDefault })
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        default: return "unknown"
        }
    }
}
