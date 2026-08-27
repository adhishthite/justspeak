// MARK: - Correction Watcher (post-paste typed-correction capture)

// Opt-in (LEARN_CORRECTIONS): after a successful paste, read the focused field back once via
// the Accessibility API and diff it against what was pasted - a single-word swap the user
// typed ("cloud" -> "Claude") is direct misrecognition evidence. Observations only feed the
// local corrections table that `make analyze` mines; nothing is ever auto-applied. Apps that
// expose no usable AX value (most terminals, many Electron apps) silently learn nothing -
// same degradation OpenWhispr ships. Uses the Accessibility permission the paste path
// already requires; never stores or prints the field content, only the changed word pairs.
final class CorrectionWatcher {
    struct Pair {
        let wrong: String
        let right: String
    }

    private let history: TranscriptionHistoryStore?
    private let delayMs: Int
    private let privacyMode: Bool
    // Lowercased boost terms: a correction whose right side is a known vocabulary term
    // passes the proper-noun gate even when lowercase ("kubectl", "gcloud").
    private let vocabSet: Set<String>
    // Main-thread-only. Bumping invalidates any armed read-back (captureActive idiom):
    // a new capture means the field is about to change under the pending read.
    private var generation = 0

    init(config: Config, history: TranscriptionHistoryStore?) {
        self.history = history
        self.delayMs = config.learnDelayMs
        self.privacyMode = config.privacyMode
        self.vocabSet = Set(config.customVocabulary.map { $0.lowercased() })
    }

    // Main thread. Called after a successful paste into the app identified by pid.
    func arm(pastedText: String, targetPid: pid_t, appName: String) {
        generation += 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000.0) { [weak self] in
            self?.fire(gen: gen, pastedText: pastedText, targetPid: targetPid, appName: appName)
        }
    }

    // Main thread. A new capture invalidates the pending read - the next paste would land
    // in the field and the diff would misread it as an edit.
    func cancelPending() {
        generation += 1
    }

    private func fire(gen: Int, pastedText: String, targetPid: pid_t, appName: String) {
        guard gen == generation else { return }
        // The user moved on or is in a password field: reading the focused element now would
        // capture text that has nothing to do with the paste.
        guard !SecureInputMonitor.isActive else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier == targetPid
        else { return }
        guard let field = Self.focusedFieldValue(pid: targetPid) else { return }

        let pairs = Self.extractCorrections(pasted: pastedText, field: field, vocabSet: vocabSet)
        guard !pairs.isEmpty else { return }
        for p in pairs {
            if privacyMode {
                Logger.info("LEARN", "Observed a typed correction (words hidden - privacy mode).")
            } else {
                Logger.info("LEARN", "Observed typed correction: \"\(p.wrong)\" -> \"\(p.right)\" - `make analyze` will pick it up.")
            }
            history?.recordCorrection(wrong: p.wrong, right: p.right, appName: appName)
        }
    }

    // Focused element's string value in the target app, or nil when the app exposes none.
    private static func focusedFieldValue(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedAny as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
            let value = valueRef as? String, !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: Diff + gates (Python-mirrored; see verification protocol)

    // The gate stack is deliberately strict (WhimprFlow/Wispr Flow lineage): only single-word
    // swaps, both sides >=3 chars, no stopwords, no capitalization-only fixes, right side a
    // proper noun or known vocabulary term, and phonetically plausible via a Levenshtein
    // band. A missed correction costs nothing (the analyzer can still infer it); a false
    // positive plants a bad rule suggestion.
    static func extractCorrections(pasted: String, field: String, vocabSet: Set<String>) -> [Pair] {
        let pastedTokens = tokenize(pasted)
        let fieldTokens = tokenize(field)
        guard !pastedTokens.isEmpty, !fieldTokens.isEmpty else { return [] }

        let window = bestWindow(pasted: pastedTokens, field: fieldTokens)
        guard !window.isEmpty else { return [] }

        var pairs: [Pair] = []
        for (wrongRaw, rightRaw) in substitutions(from: pastedTokens, to: window) {
            let wrong = strip(wrongRaw)
            let right = strip(rightRaw)
            guard !wrong.isEmpty, !right.isEmpty else { continue }
            guard wrong.lowercased() != right.lowercased() else { continue }
            guard wrong.count >= 3, right.count >= 3 else { continue }
            guard !stopwords.contains(wrong.lowercased()), !stopwords.contains(right.lowercased()) else { continue }
            guard right.first!.isUppercase || vocabSet.contains(right.lowercased()) else { continue }
            let dist = levenshtein(wrong.lowercased(), right.lowercased())
            let maxLen = max(wrong.count, right.count)
            guard dist <= max(2, (6 * maxLen) / 10) else { continue }
            pairs.append(Pair(wrong: wrong, right: right))
            if pairs.count >= 3 { break }
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    // Surrounding punctuation only; inner characters ("Next.js", "co-pilot") stay.
    private static func strip(_ token: String) -> String {
        let punct = CharacterSet(charactersIn: ".,!?;:\"'()[]{}<>«»\u{2018}\u{2019}\u{201C}\u{201D}")
        return token.trimmingCharacters(in: punct)
    }

    // Locate the paste inside a field that may hold unrelated text (an email draft, a doc).
    // Slides a pasted-length window over the field and keeps the best token-set overlap;
    // below 0.5 the paste was rewritten or deleted and diffing would produce noise.
    private static func bestWindow(pasted: [String], field: [String]) -> [String] {
        let n = pasted.count
        if field.count <= n {
            return overlapScore(pasted, field) >= 0.5 ? field : []
        }
        // Always slide an exact-length window: comparing against the whole field dilutes
        // the overlap score when the paste sits inside a larger draft.
        var best: [String] = []
        var bestScore = 0.0
        for start in 0...(field.count - n) {
            let window = Array(field[start..<start + n])
            let score = overlapScore(pasted, window)
            if score > bestScore {
                bestScore = score
                best = window
            }
        }
        return bestScore >= 0.5 ? best : []
    }

    private static func overlapScore(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a.map { strip($0).lowercased() }.filter { !$0.isEmpty })
        let sb = Set(b.map { strip($0).lowercased() }.filter { !$0.isEmpty })
        guard !sa.isEmpty, !sb.isEmpty else { return 0.0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    // LCS-based token diff. Each maximal run of changed tokens between two matches pairs
    // positionally when both sides changed the same number of tokens (<=3): "cloud code" ->
    // "Claude Code" yields cloud->Claude and code->Code. Unequal or longer runs are
    // discarded - those are rewrites of intent, not misrecognitions.
    private static func substitutions(from a: [String], to b: [String]) -> [(String, String)] {
        let n = a.count
        let m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [(String, String)] = []
        var i = 0
        var j = 0
        var runDel: [String] = []
        var runIns: [String] = []
        func flushRun() {
            if !runDel.isEmpty && runDel.count == runIns.count && runDel.count <= 3 {
                for k in 0..<runDel.count {
                    result.append((runDel[k], runIns[k]))
                }
            }
            runDel.removeAll()
            runIns.removeAll()
        }
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                flushRun()
                i += 1
                j += 1
            } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                runIns.append(b[j])
                j += 1
            } else {
                runDel.append(a[i])
                i += 1
            }
        }
        flushRun()
        return result
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let ca = Array(a)
        let cb = Array(b)
        if ca.isEmpty { return cb.count }
        if cb.isEmpty { return ca.count }
        var prev = Array(0...cb.count)
        var curr = [Int](repeating: 0, count: cb.count + 1)
        for i in 1...ca.count {
            curr[0] = i
            for j in 1...cb.count {
                let cost = ca[i - 1] == cb[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[cb.count]
    }

    private static let stopwords: Set<String> = [
        "the", "and", "but", "for", "not", "you", "your", "are", "was", "were", "have", "has",
        "had", "this", "that", "these", "those", "with", "from", "into", "will", "would",
        "can", "could", "should", "just", "like", "what", "when", "where", "which", "who",
        "how", "all", "any", "some", "there", "here", "then", "than", "them", "they", "its",
        "it's", "out", "about", "over", "under", "also", "very", "more", "most", "our",
    ]
}
