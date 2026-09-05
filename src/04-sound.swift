// MARK: - Audio Feedback Sound Manager (Apple System Earcons)

final class SoundManager {
    // jbl_begin (Siri's rising "listening" chime) leads: begin_record is a low-energy mono
    // click that vanishes on built-in speakers below ~50% volume. Only the chime's attack
    // needs to land before the 350ms duck; the tail riding under the duck is fine.
    private static let startSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_begin.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf",
    ]

    // acknowledgment_sent (the soft "message sent" swoosh) leads: jbl_confirm reads loud and
    // insistent next to the other cues even at low volume.
    private static let commitSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_sent.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_confirm.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf",
    ]

    private static let errorSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_cancel.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/mic_unmute_fail.caf",
    ]

    private static var startSound: NSSound? = {
        for path in startSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.50
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
                sound.volume = 0.22
                return sound
            }
        }
        let fallback = NSSound(named: "Hero")
        fallback?.volume = 0.3
        return fallback
    }()

    // Key-release acknowledgment. Deliberately shorter than the commit earcon - it says
    // "release registered, settling" while the commit sound still owns "text landed".
    // This cue (and the lock cue) fires while the output device is DUCKED, and NSSound gain
    // caps at 1.0, so nothing played here can exceed DUCK_FRACTION of the system volume: it
    // has to be a file with real transient energy. Pop is a short low thud - deep enough
    // not to read as an alert, punchy enough to survive 20%. end_record (macOS's own
    // "recording stopped" click) is too quiet for that and stays only as a fallback.
    private static let releaseSoundPaths = [
        "/System/Library/Sounds/Pop.aiff",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf",
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

    // Hold-to-lock earcon: the release that follows is deliberately silent (a non-event),
    // so this cue must carry "you can let go" on its own - a warm two-note confirmation, not
    // a click. payment_success is Apple Pay's chime (the system's own "locked in" sound;
    // it ships as .aif, not .caf); Glass is the softest of the named chimes. Both distinct
    // from Pop (release) and acknowledgment_sent (commit), so the three moments of a
    // locked turn never sound alike. Fires ducked - see the release note above.
    private static let lockSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/payment_success.aif"
    ]

    private static var lockSound: NSSound? = {
        for path in lockSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.40
                return sound
            }
        }
        let fallback = NSSound(named: "Glass")
        fallback?.volume = 0.30
        return fallback
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

    static func playLockSound(volumeScale: Float = 1.0) {
        DispatchQueue.global(qos: .userInteractive).async {
            lockSound?.volume = min(1.0, 0.40 * volumeScale)
            lockSound?.stop()
            lockSound?.play()
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
