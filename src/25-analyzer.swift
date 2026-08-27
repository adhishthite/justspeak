// MARK: - Vocabulary Analyzer (History Mining)

// Mines the local dictation history for words the recognizer keeps mangling and domain
// terms worth boosting, using ANALYZE_MODEL as the analyst. Strictly user-run
// (`--analyze` / `make analyze`) - the dictation pipeline never touches this code.
// Transcripts leave the machine exactly as far as they already did to be transcribed:
// the same Gemini API, same key.
struct VocabularyAnalyzer {
    private struct Suggestion {
        let line: String  // vocabulary-file syntax: "Term" or "wrong => right"
        let reason: String
    }

    // One success row from the history DB. Timestamp and frontmost app travel into the
    // prompt: adjacency exposes re-dictations, the app hints at what a phrase meant
    // ("cloud code" typed into a terminal is almost certainly "Claude Code").
    private struct Row {
        let ts: Double
        let app: String
        let text: String
    }

    static func run(config: Config, days: Int) {
        print("\n\(ANSI.bold)JustSpeak Vocabulary Analyzer\(ANSI.reset)")

        guard !config.geminiApiKey.isEmpty else {
            Logger.error("ANALYZE", "GEMINI_API_KEY is not configured in .env or environment.")
            exit(1)
        }

        let rawPath = config.historyDbPath.isEmpty ? "~/.justspeak/history.db" : config.historyDbPath
        let dbPath = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            Logger.error("ANALYZE", "No history DB at \(dbPath) - dictate a few times first (HISTORY=true).")
            exit(1)
        }

        let rows = loadRows(dbPath: dbPath, days: days)
        guard rows.count >= 5 else {
            Logger.error("ANALYZE", "Only \(rows.count) usable transcript(s) in the last \(days) day(s) - need at least 5 for patterns to emerge.")
            exit(1)
        }

        let model = config.analyzeModel.isEmpty ? config.geminiModel : config.analyzeModel
        let totalWords = rows.reduce(0) { $0 + $1.text.split(separator: " ").count }
        Logger.info("ANALYZE", "Analyzing \(rows.count) transcripts (\(totalWords) words, last \(days) day(s)) with \(model)...")

        let pairs = findRetryPairs(rows)
        if !pairs.isEmpty {
            Logger.info("ANALYZE", "\(pairs.count) possible re-dictation pair(s) - direct correction evidence.")
        }

        let prompt = buildPrompt(rows: rows, pairs: pairs, config: config)
        guard let raw = requestAnalysis(prompt: prompt, model: model, config: config) else {
            exit(1)
        }

        // Terms the config already knows, lowercased: boost terms, both sides of every
        // replacement rule. The prompt asks the model to skip these; enforce it anyway.
        var known = Set(config.customVocabulary.map { $0.lowercased() })
        for rule in config.replacementRules {
            known.insert(rule.wrong.lowercased())
            known.insert(rule.right.lowercased())
        }

        let suggestions = parseSuggestions(raw: raw, known: known)
        guard !suggestions.isEmpty else {
            Logger.success("ANALYZE", "No new suggestions - your vocabulary already covers what the history shows.")
            return
        }

        print("\n\(ANSI.bold)Suggestions (vocabulary-file syntax):\(ANSI.reset)")
        for (idx, s) in suggestions.enumerated() {
            print("  \(ANSI.cyan)\(String(format: "%2d", idx + 1)).\(ANSI.reset) \(ANSI.bold)\(s.line)\(ANSI.reset)")
            print("      \(ANSI.gray)\(s.reason)\(ANSI.reset)")
        }

        offerAppend(suggestions: suggestions, config: config)
    }

    // Same-user read of the app's WAL database; READWRITE mode (like the app itself uses)
    // sidesteps WAL read-only recovery edge cases, and busy_timeout covers a concurrent
    // dictation writing a row mid-query.
    private static func loadRows(dbPath: String, days: Int) -> [Row] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite3_open_v2 error"
            if let handle = handle { sqlite3_close(handle) }
            Logger.error("ANALYZE", "Failed to open history DB: \(msg)")
            exit(1)
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA busy_timeout=2000;", nil, nil, nil)

        let sql = """
            SELECT ts_epoch, app_name, text FROM transcriptions
            WHERE outcome = 'success' AND text IS NOT NULL AND length(trim(text)) > 0 AND ts_epoch >= ?
            ORDER BY ts_epoch DESC LIMIT 500
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.error("ANALYZE", "Failed to query history: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_finalize(stmt)
            exit(1)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Double(days) * 86400.0)

        // Cap the payload so a heavy month of dictation cannot balloon one analysis call;
        // rows are newest-first, so what gets dropped is the oldest history.
        var results: [Row] = []
        var budget = 300_000
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(stmt, 2) else { continue }
            let text = String(cString: cText)
            if text.count > budget {
                Logger.warn("ANALYZE", "Payload cap reached - older transcripts beyond \(results.count) rows were dropped.")
                break
            }
            budget -= text.count
            let ts = sqlite3_column_double(stmt, 0)
            let app = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            results.append(Row(ts: ts, app: app, text: text))
        }
        return results
    }

    // A near-identical dictation seconds after another usually means the user re-said a
    // mangled turn: the differing words are direct correction evidence. This pass is pure
    // recall over adjacent rows (rows arrive newest-first); the model judges whether each
    // pair is a correction or merely similar content.
    private static func findRetryPairs(_ rows: [Row]) -> [(older: Row, newer: Row)] {
        var pairs: [(older: Row, newer: Row)] = []
        for i in 0..<rows.count where i + 1 < rows.count {
            let newer = rows[i]
            let older = rows[i + 1]
            guard newer.ts - older.ts <= 120.0 else { continue }
            let a = tokenSet(older.text)
            let b = tokenSet(newer.text)
            guard !a.isEmpty, !b.isEmpty, a != b else { continue }
            let jaccard = Double(a.intersection(b).count) / Double(a.union(b).count)
            if jaccard >= 0.5 {
                pairs.append((older, newer))
            }
        }
        return pairs
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func buildPrompt(rows: [Row], pairs: [(older: Row, newer: Row)], config: Config) -> String {
        var existing: [String] = config.customVocabulary
        existing.append(contentsOf: config.replacementRules.map { "\($0.wrong) => \($0.right)" })
        let existingBlock = existing.isEmpty ? "(none)" : existing.joined(separator: "\n")

        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let transcriptBlock = rows.map { row in
            let app = row.app.isEmpty ? "?" : row.app
            return "[\(df.string(from: Date(timeIntervalSince1970: row.ts))) | \(app)] \(row.text)"
        }.joined(separator: "\n")

        // Cap the pair block: pairs duplicate transcript text, and 20 is already far more
        // correction evidence than one session needs.
        let pairBlock = pairs.isEmpty
            ? "(none)"
            : pairs.prefix(20).map { p in
                "A [\(df.string(from: Date(timeIntervalSince1970: p.older.ts)))]: \(p.older.text)\nB [\(df.string(from: Date(timeIntervalSince1970: p.newer.ts)))]: \(p.newer.text)"
            }.joined(separator: "\n---\n")

        let contextBlock = config.analyzeContext.isEmpty
            ? ""
            : "\nABOUT THE USER (use this to judge what a garbled phrase plausibly meant):\n\(config.analyzeContext)\n"

        return """
            You are analyzing a user's voice-dictation history to improve their speech-to-text setup.
            Below are their recent transcriptions (newest first, each prefixed with local time and the app dictated into), their EXISTING custom vocabulary, and detected re-dictation pairs.
            \(contextBlock)
            Find two things:
            1. "vocabulary": domain terms the user says repeatedly that a recognizer is likely to mangle - product names, people/company names, acronyms, technical jargon, non-English words. These become recognition-boost hints. Judge by repetition across MANY transcripts, only suggest terms actually present in the transcripts, and never repeat a term already in the existing vocabulary.
            2. "replacements": misrecognitions, fixed later by deterministic "wrong => right" rules.
               - The existing vocabulary is your primary target list: hunt for garbled or phonetic variants of exactly those terms (e.g. "cloud code" when the vocabulary has "Claude Code").
               - The wrong form must appear verbatim in the transcriptions. The right form does NOT have to appear anywhere - infer it from the existing vocabulary, the app column, the user description, and world knowledge.
               - A single occurrence is enough when the intended term is unambiguous in its sentence; otherwise require repetition.
               - In a re-dictation pair, the words differing between A and B are usually the correction (B is what the user meant).
               - Never suggest a rule for grammar, style, punctuation, or capitalization-only differences - only real word substitutions.
               - Each side at most 4 words, and only propose a rule if this user would essentially never mean the wrong form literally: the rule fires on every future dictation.

            Hard rules:
            - At most 15 vocabulary terms and 10 replacements; fewer is better than padded.
            - Each reason is at most 12 words and cites the evidence (e.g. "appears 9 times", "re-dictation pair at 14:02", "vocabulary term 'Claude Code' garbled").
            - If there is nothing worth suggesting, return empty arrays.

            Respond with strict JSON only, exactly this shape:
            {"vocabulary": [{"term": "", "reason": ""}], "replacements": [{"wrong": "", "right": "", "reason": ""}]}

            EXISTING VOCABULARY:
            \(existingBlock)

            RE-DICTATION PAIRS (older A, then newer B, seconds apart):
            \(pairBlock)

            TRANSCRIPTIONS:
            \(transcriptBlock)
            """
    }

    private static func requestAnalysis(prompt: String, model: String, config: Config) -> [String: Any]? {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            Logger.error("ANALYZE", "Invalid REST URL.")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.geminiApiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 90.0

        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.error("ANALYZE", "Failed to serialize analysis request.")
            return nil
        }
        request.httpBody = body

        var parsed: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                Logger.error("ANALYZE", "Request failed: \(error.localizedDescription)")
                return
            }
            guard let data = data else {
                Logger.error("ANALYZE", "Empty response from Gemini.")
                return
            }
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                Logger.error("ANALYZE", "Gemini returned HTTP \(status): \(bodyStr.prefix(200))")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let content = candidates.first?["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let text = parts.first?["text"] as? String,
                let textData = text.data(using: .utf8),
                let result = try? JSONSerialization.jsonObject(with: textData) as? [String: Any]
            else {
                Logger.error("ANALYZE", "Could not parse an analysis JSON out of the model response.")
                return
            }
            if let usage = json["usageMetadata"] as? [String: Any],
                let inTok = usage["promptTokenCount"] as? Int,
                let outTok = usage["candidatesTokenCount"] as? Int
            {
                // The REST_*_PRICE knobs describe the REST fallback model; estimating with
                // them for a different ANALYZE_MODEL would just be a wrong number.
                if model == config.geminiModel {
                    let cost =
                        Double(inTok) / 1_000_000.0 * config.restInputPricePer1M
                        + Double(outTok) / 1_000_000.0 * config.restOutputPricePer1M
                    Logger.info("ANALYZE", "Tokens: \(inTok) in / \(outTok) out (~$\(String(format: "%.4f", cost)))")
                } else {
                    Logger.info("ANALYZE", "Tokens: \(inTok) in / \(outTok) out")
                }
            }
            parsed = result
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 95.0)
        return parsed
    }

    private static func parseSuggestions(raw: [String: Any], known: Set<String>) -> [Suggestion] {
        var suggestions: [Suggestion] = []
        var seen = Set<String>()

        if let vocab = raw["vocabulary"] as? [[String: Any]] {
            for entry in vocab.prefix(15) {
                guard let term = (entry["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !term.isEmpty, term.count <= 60
                else { continue }
                let key = term.lowercased()
                if known.contains(key) || seen.contains(key) { continue }
                seen.insert(key)
                let reason = (entry["reason"] as? String) ?? ""
                suggestions.append(Suggestion(line: term, reason: reason))
            }
        }
        if let rules = raw["replacements"] as? [[String: Any]] {
            for entry in rules.prefix(10) {
                guard let wrong = (entry["wrong"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    let right = (entry["right"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !wrong.isEmpty, !right.isEmpty, wrong.lowercased() != right.lowercased(),
                    wrong.count <= 80, right.count <= 80,
                    // Wispr Flow-style phrase cap: long rules are almost never a true
                    // misrecognition and fire too broadly to be safe.
                    wrong.split(separator: " ").count <= 4, right.split(separator: " ").count <= 4,
                    !wrong.contains("=>"), !right.contains("=>")
                else { continue }
                let key = wrong.lowercased()
                if known.contains(key) || seen.contains(key) { continue }
                seen.insert(key)
                let reason = (entry["reason"] as? String) ?? ""
                suggestions.append(Suggestion(line: "\(wrong) => \(right)", reason: reason))
            }
        }
        return suggestions
    }

    private static func offerAppend(suggestions: [Suggestion], config: Config) {
        // Prefer the vocabulary file the config actually loaded; otherwise create the
        // default candidate the loader looks for first.
        var target =
            config.customVocabularyFile.isEmpty
            ? FileManager.default.currentDirectoryPath + "/vocabulary.txt"
            : (config.customVocabularyFile as NSString).expandingTildeInPath
        if !target.hasPrefix("/") {
            target = FileManager.default.currentDirectoryPath + "/" + target
        }

        print("\nAppend to \(ANSI.bold)\(target)\(ANSI.reset)?")
        print("  \(ANSI.bold)y\(ANSI.reset) = all \(suggestions.count), numbers pick a few (e.g. \"1 3\" or \"2-4\"), \(ANSI.bold)Enter\(ANSI.reset) = none: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard let indices = parseSelection(answer, count: suggestions.count) else {
            print("Didn't understand \"\(answer)\" - nothing written.")
            return
        }
        guard !indices.isEmpty else {
            print("Nothing written. Copy any line above into your vocabulary file manually.")
            return
        }
        let chosen = indices.map { suggestions[$0] }

        var existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var block = "\n# Added by --analyze on \(formatter.string(from: Date()))\n"
        block += chosen.map { $0.line }.joined(separator: "\n") + "\n"

        do {
            try (existing + block).write(toFile: target, atomically: true, encoding: .utf8)
            Logger.success("ANALYZE", "Appended \(chosen.count) of \(suggestions.count) line(s) to \(target). They load on the next launch.")
        } catch {
            Logger.error("ANALYZE", "Failed to write \(target): \(error.localizedDescription)")
        }
    }

    // The answer is either an all/none keyword or a 1-based pick over the printed list
    // ("2", "1 3", "1,3-4"). Strict on purpose: any token that doesn't parse or is out of
    // range invalidates the whole answer (nil) so a typo appends nothing rather than a subset.
    private static func parseSelection(_ input: String, count: Int) -> [Int]? {
        if input.isEmpty || input == "n" || input == "no" { return [] }
        if input == "y" || input == "yes" || input == "a" || input == "all" { return Array(0..<count) }
        let tokens = input.split(whereSeparator: { $0 == "," || $0 == " " })
        if tokens.isEmpty { return nil }
        var picked = Set<Int>()
        for token in tokens {
            let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                guard let lo = Int(parts[0]), let hi = Int(parts[1]), lo >= 1, hi <= count, lo <= hi else { return nil }
                picked.formUnion((lo - 1)...(hi - 1))
            } else {
                guard let n = Int(token), n >= 1, n <= count else { return nil }
                picked.insert(n - 1)
            }
        }
        return picked.sorted()
    }
}
