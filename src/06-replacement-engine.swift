// MARK: - Replacement Engine (Deterministic Wrong→Right Enforcement)

// Post-transcription enforcement layer: the model can be *biased* toward the right spelling
// via boost vocabulary, but this layer *guarantees* it - longest-match-first, word-boundary,
// case-preserving (ALL-CAPS / Title / lower propagation).
enum ReplacementEngine {
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        // Longest wrong-form first so "gemini api" wins over "gemini".
        for rule in rules.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            guard !rule.wrong.isEmpty else { continue }
            // Lookarounds instead of \b: word boundaries silently never match when the wrong
            // form starts/ends with punctuation ("e.g.", "c++").
            let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: rule.wrong))(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            let mutable = NSMutableString(string: result)
            for match in matches {
                let original = ns.substring(with: match.range)
                let replacement = propagateCase(from: original, to: rule.right, wrong: rule.wrong)
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
            result = mutable as String
        }
        return result
    }

    // "KUBERNETES"->"GRPC" stays caps; "Kubernetes"->"GRPC" follows the rule's canonical
    // casing unless the match was ALL-CAPS or the rule carries EXPLICIT casing. A rule is
    // explicitly cased when its right side contains uppercase (gRPC, iPhone) - or when its
    // WRONG side does ("NPM"->"npm" is a deliberate lowercase rule; ALL-CAPS propagation
    // would silently undo it) - or when wrong/right are the same word modulo case.
    static func propagateCase(from original: String, to replacement: String, wrong: String = "") -> String {
        let hasExplicitCasing = replacement.dropFirst().contains(where: { $0.isUppercase })
            || replacement.first?.isUppercase == true
            || wrong.contains(where: { $0.isUppercase })
            || (!wrong.isEmpty && wrong.lowercased() == replacement.lowercased())
        if hasExplicitCasing {
            return replacement // dictionary term carries its own casing (gRPC, iPhone)
        }
        if original == original.uppercased(), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}

