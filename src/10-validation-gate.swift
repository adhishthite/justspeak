// MARK: - REST-Only Validation Gate (no reference transcript)

/// Guards the REST fallback only: gemini-3.5-flash-lite is PROMPTED to transcribe audio, and
/// its documented failure mode is answering (or chatting about) the audio instead of
/// transcribing it. The WS route uses a dedicated transcription model and never sees this
/// gate. Ported from Jot's ValidationGate, minus the checks that need a raw reference
/// transcript to compare against (length-ratio, word-containment, trigram similarity) - the
/// REST path has no second model call to validate against.
enum RestValidationGate {
    /// Strips model artifacts that are not failures: code fences, "Transcript:"/"CLEAN:"
    /// labels, wrapping quotes.
    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:", "Transcription:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    // Jot's broad opener check ("Sure," / "Okay," ...) only fires when the first word differs
    // from a raw reference transcript - people legitimately DICTATE replies that open with
    // those words, and the REST path has no reference to compare against. So this gate keeps
    // only phrasings that are near-certainly the model's own voice: transcript framing
    // ("Here's the transcription", "The audio says"), transcription refusals, and AI
    // self-identification. Bare "language model" / "as an AI engineer" style dictations pass.
    private static let answerPattern = try! NSRegularExpression(
        pattern: #"^(here('s| is) (the |your )?(transcript|transcription)\b|the (audio|recording|speaker) (says|said|contains)\b|this (audio|recording) (contains|is)\b|i can('|no)t (transcribe|process) (this|the|that)\b|i('m| am) (sorry, but i can('|no)t|unable to) (transcribe|process)\b)"#,
        options: [.caseInsensitive]
    )
    private static let selfReferencePattern = try! NSRegularExpression(
        pattern: #"as an ai[,.]|as an ai (language model|assistant|model)\b|i('m| am) (just )?an ai[,.]|i('m| am) (just )?an ai (assistant|language model|model)\b"#,
        options: [.caseInsensitive]
    )

    /// nil = pass. Checks ported from Jot that don't require a raw reference transcript:
    /// AI self-reference and model-voice transcript framing.
    static func rejectionReason(_ cleaned: String) -> String? {
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        if selfReferencePattern.firstMatch(in: cleaned, range: range) != nil {
            return "ai_selfreference"
        }
        if answerPattern.firstMatch(in: cleaned, range: range) != nil {
            return "answer_pattern"
        }
        return nil
    }
}

