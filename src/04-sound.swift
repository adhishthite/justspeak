// MARK: - Audio Feedback Sound Manager (Apple System Earcons)

final class SoundManager {
    private static let startSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_begin.caf",
    ]

    private static let commitSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_confirm.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_sent.caf",
    ]

    private static let errorSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_cancel.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/mic_unmute_fail.caf",
    ]

    private static var startSound: NSSound? = {
        for path in startSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.55
                return sound
            }
        }
        let fallback = NSSound(named: "Blow")
        fallback?.volume = 0.45
        return fallback
    }()

    private static var commitSound: NSSound? = {
        for path in commitSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.35
                return sound
            }
        }
        let fallback = NSSound(named: "Hero")
        fallback?.volume = 0.45
        return fallback
    }()

    // Key-release acknowledgment. Deliberately quieter and shorter than the commit earcon -
    // it says "release registered, settling" while the commit sound still owns "text landed".
    // end_record is macOS's own "recording stopped" earcon; no collision with the commit
    // sound, which resolves to jbl_confirm first. No named-sound fallback on purpose: the
    // legacy alert names read as the system error beep - silence beats a wrong-meaning cue.
    private static let releaseSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_received.caf",
    ]

    private static var releaseSound: NSSound? = {
        for path in releaseSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.35
                return sound
            }
        }
        return nil
    }()

    private static var errorSound: NSSound? = {
        for path in errorSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.55
                return sound
            }
        }
        let fallback = NSSound(named: "Funk")
        fallback?.volume = 0.45
        return fallback
    }()

    static func playStartSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            startSound?.stop()
            startSound?.play()
        }
    }

    // volumeScale compensates for system-output ducking: the cue plays through a device
    // sitting at DUCK_FRACTION, so its own volume is scaled up (capped at 1.0) to survive.
    static func playReleaseSound(volumeScale: Float = 1.0) {
        DispatchQueue.global(qos: .userInteractive).async {
            releaseSound?.volume = min(1.0, 0.35 * volumeScale)
            releaseSound?.stop()
            releaseSound?.play()
        }
    }

    static func playCommitSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            commitSound?.stop()
            commitSound?.play()
        }
    }

    static func playErrorSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            errorSound?.stop()
            errorSound?.play()
        }
    }
}
