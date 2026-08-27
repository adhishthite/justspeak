// MARK: - System Output Ducking (CoreAudio)

// Ported conceptually from Talkify's AudioDucker: macOS has no per-app ducking API, so the
// only way to keep music/video off the mic during a dictation is to turn the default output
// device's volume down directly, then put it back. "User-wins" on restore: if the person
// touched the volume mid-turn, their choice is left alone rather than stomped.
final class AudioDucker {
    static let shared = AudioDucker()

    private struct DuckedState {
        let deviceID: AudioDeviceID
        let elements: [AudioObjectPropertyElement]
        let originalVolume: Float32
        let appliedVolume: Float32
    }

    private let lock = NSLock()
    private var state: DuckedState?

    private init() {}

    func duck(toFraction fraction: Float) {
        lock.lock()
        guard state == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let deviceID = Self.defaultOutputDevice() else {
            Logger.debug("DUCK", "No default output device - skipping duck.")
            return
        }
        guard let elements = Self.volumeElements(for: deviceID) else {
            Logger.debug("DUCK", "Output device exposes no settable volume - skipping duck.")
            return
        }
        guard let current = Self.readVolume(deviceID: deviceID, elements: elements) else {
            Logger.debug("DUCK", "Could not read output volume - skipping duck.")
            return
        }

        let target = min(max(current * fraction, 0), 1)
        var applied = current
        if target < current {
            applied = Self.writeVolume(deviceID: deviceID, elements: elements, value: target) ? target : current
        }

        lock.lock()
        state = DuckedState(deviceID: deviceID, elements: elements, originalVolume: current, appliedVolume: applied)
        lock.unlock()

        if applied < current {
            Logger.debug("DUCK", String(format: "Output ducked %.2f -> %.2f", current, applied))
        }
    }

    func restore() {
        lock.lock()
        guard let saved = state else {
            lock.unlock()
            return
        }
        state = nil
        lock.unlock()

        guard let current = Self.readVolume(deviceID: saved.deviceID, elements: saved.elements) else {
            return
        }

        if abs(current - saved.appliedVolume) > 0.001 {
            Logger.debug("DUCK", "Volume changed by user mid-turn - leaving as-is.")
            return
        }

        guard saved.appliedVolume != saved.originalVolume else { return }
        if Self.writeVolume(deviceID: saved.deviceID, elements: saved.elements, value: saved.originalVolume) {
            Logger.debug("DUCK", String(format: "Output restored -> %.2f", saved.originalVolume))
        }
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // Master element first; many external DACs (and some Bluetooth outputs) only expose
    // per-channel volume, so fall back to left/right (elements 1, 2) when master isn't settable.
    private static func volumeElements(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement]? {
        let main = AudioObjectPropertyElement(0)  // == kAudioObjectPropertyElementMain, spelled out to dodge the deprecated alias warning
        if isVolumeSettable(deviceID: deviceID, element: main) {
            return [main]
        }
        let channels: [AudioObjectPropertyElement] = [1, 2].filter {
            isVolumeSettable(deviceID: deviceID, element: $0)
        }
        return channels.isEmpty ? nil : channels
    }

    private static func isVolumeSettable(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readVolume(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Float32? {
        var total: Float32 = 0
        var count = 0
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            guard status == noErr else { continue }
            total += value
            count += 1
        }
        guard count > 0 else { return nil }
        return total / Float32(count)
    }

    @discardableResult
    private static func writeVolume(
        deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement], value: Float32
    ) -> Bool {
        var wroteAny = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var mutableValue = value
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue)
            if status == noErr { wroteAny = true }
        }
        return wroteAny
    }
}
