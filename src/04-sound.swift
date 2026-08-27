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
                sound.volume = 0.65
                return sound
            }
        }
        let fallback = NSSound(named: "Hero")
        fallback?.volume = 0.45
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
