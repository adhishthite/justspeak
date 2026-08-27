// MARK: - System Output Ducking (CoreAudio)

// Ported conceptually from Talkify's AudioDucker: macOS has no per-app ducking API, so the
// only way to keep music/video off the mic during a dictation is to turn the default output
// device's volume down directly, then put it back. "User-wins" on restore: if the person
// touched the volume mid-turn, their choice is left alone rather than stomped.
final class AudioDucker {
    static let shared = AudioDucker()

    // Per-element levels: a device without a master volume has independent left/right
    // channels, and collapsing them to one average would permanently flatten the user's
    // stereo balance on the first ducking cycle.
    private struct ElementLevel {
        let element: AudioObjectPropertyElement
        let original: Float32
        let applied: Float32
    }

    private struct DuckedState {
        let deviceID: AudioDeviceID
        let levels: [ElementLevel]
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
        var levels: [ElementLevel] = []
        for element in elements {
            guard let current = Self.readVolume(deviceID: deviceID, element: element) else { continue }
            let target = min(max(current * fraction, 0), 1)
            var applied = current
            if target < current, Self.writeVolume(deviceID: deviceID, element: element, value: target) {
                applied = target
            }
            levels.append(ElementLevel(element: element, original: current, applied: applied))
        }
        guard !levels.isEmpty else {
            Logger.debug("DUCK", "Could not read output volume - skipping duck.")
            return
        }

        lock.lock()
        state = DuckedState(deviceID: deviceID, levels: levels)
        lock.unlock()

        if levels.contains(where: { $0.applied < $0.original }) {
            let detail = levels.map { String(format: "%.2f -> %.2f", $0.original, $0.applied) }.joined(separator: ", ")
            Logger.debug("DUCK", "Output ducked \(detail)")
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

        // User-wins is judged whole-device: the volume keys move every channel together, so
        // any one element off its applied value means the user adjusted - leave all of them.
        var currents: [Float32] = []
        for level in saved.levels {
            guard let current = Self.readVolume(deviceID: saved.deviceID, element: level.element) else { return }
            currents.append(current)
        }
        for (i, level) in saved.levels.enumerated() where abs(currents[i] - level.applied) > 0.001 {
            Logger.debug("DUCK", "Volume changed by user mid-turn - leaving as-is.")
            return
        }

        var restoredAny = false
        for level in saved.levels where level.applied != level.original {
            if Self.writeVolume(deviceID: saved.deviceID, element: level.element, value: level.original) {
                restoredAny = true
            }
        }
        if restoredAny {
            let detail = saved.levels.map { String(format: "%.2f", $0.original) }.joined(separator: ", ")
            Logger.debug("DUCK", "Output restored -> \(detail)")
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

    private static func readVolume(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func writeVolume(
        deviceID: AudioDeviceID, element: AudioObjectPropertyElement, value: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue) == noErr
    }
}
