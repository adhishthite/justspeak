// MARK: - Gemini REST Fallback Client (Single-Turn Audio)

struct GeminiRestClient {
    static func transcribe(
        pcmData: Data,
        apiKey: String,
        model: String,
        languageCodes: [String] = [],
        customVocabulary: [String] = [],
        isRetry: Bool = false,
        completion: @escaping (Result<(text: String, latencyMs: Double, inputTokens: Int?, outputTokens: Int?), Error>) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "JustSpeak", code: -1, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY is empty."])))
            return
        }
        
        let wavData = createWavData(from: pcmData, sampleRate: 16000, channels: 1)
        let base64Wav = wavData.base64EncodedString()
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "JustSpeak", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid REST URL."])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10.0
        
        let payload: [String: Any]
        if model.contains("transcribe") {
            // Dedicated STT Foundation Model (Pure Audio, zero developer instruction requirement)
            payload = [
                "contents": [
                    [
                        "parts": [
                            [
                                "inlineData": [
                                    "mimeType": "audio/wav",
                                    "data": base64Wav
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        } else {
            // General Multimodal LLM (Prompt & System Instruction guided)
            var promptText = "Transcribe this audio precisely. Fix punctuation, capitalization, and grammar. Remove filler words (um, uh, you know). Preserve technical terms, acronyms, code snippets, numbers, and formatting. Output ONLY the polished transcription without commentary, explanations, or quotes."
            var systemText = "You are a professional voice dictation engine. Transcribe and polish the spoken audio into clean text. Output ONLY the final text."
            
            if !languageCodes.isEmpty {
                let langList = languageCodes.joined(separator: ", ")
                promptText += "\nTarget language(s): \(langList)"
                systemText += "\nTarget language(s): \(langList)"
            }
            
            if !customVocabulary.isEmpty {
                let vocabList = customVocabulary.joined(separator: ", ")
                promptText += "\nCustom vocabulary & technical terms to recognize accurately: \(vocabList)"
                systemText += "\nCustom vocabulary: \(vocabList)"
            }
            
            payload = [
                "contents": [
                    [
                        "parts": [
                            [
                                "inlineData": [
                                    "mimeType": "audio/wav",
                                    "data": base64Wav
                                ]
                            ],
                            [
                                "text": promptText
                            ]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.0
                ],
                "systemInstruction": [
                    "parts": [
                        [
                            "text": systemText
                        ]
                    ]
                ]
            ]
        }
        
        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(NSError(domain: "JustSpeak", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize REST JSON."])))
            return
        }
        request.httpBody = requestBody
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "JustSpeak", code: -4, userInfo: [NSLocalizedDescriptionKey: "No data received from Gemini REST API."])))
                return
            }

            // 429: per-minute throttles carry a short retryDelay - honor it once. Only a real
            // daily/hard quota (quotaId contains "PerDay") is terminal; anything else clears on
            // its own and is worth one retry if the wait is short.
            if (response as? HTTPURLResponse)?.statusCode == 429 {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                if bodyStr.contains("PerDay") {
                    completion(.failure(NSError(domain: "GeminiAPI", code: 429, userInfo: [NSLocalizedDescriptionKey: "Daily quota exhausted for \(model) - retry won't help until reset."])))
                    return
                }
                let delay = Self.retryDelaySeconds(from: data, response: response as? HTTPURLResponse) ?? 2.0
                if !isRetry, delay <= 8.0 {
                    Logger.warn("REST", "429 rate limited on \(model) - retrying once after \(String(format: "%.1f", delay))s.")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        Self.transcribe(pcmData: pcmData, apiKey: apiKey, model: model, languageCodes: languageCodes, customVocabulary: customVocabulary, isRetry: true, completion: completion)
                    }
                    return
                }
                completion(.failure(NSError(domain: "GeminiAPI", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited (429) on \(model); retry delay \(String(format: "%.1f", delay))s \(isRetry ? "after one retry" : "exceeds budget") - not retrying."])))
                return
            }

            // Other non-2xx statuses get named failures instead of a JSON-parse error whose
            // text buries the cause. 400/401/403 are key problems (an invalid API key comes
            // back as 400 API_KEY_INVALID), 404 is a wrong/retired model name - none of them
            // is retryable, so fail immediately with the fix in the message.
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
                var apiReason = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let apiError = json["error"] as? [String: Any],
                   let msg = apiError["message"] as? String {
                    apiReason = " (\(msg.prefix(140)))"
                }
                let message: String
                switch status {
                case 400, 401, 403:
                    message = "Gemini rejected the request (HTTP \(status))\(apiReason) - check GEMINI_API_KEY in .env."
                case 404:
                    message = "Model not found: \(model) (HTTP 404)\(apiReason) - check GEMINI_MODEL in .env."
                case 500...599:
                    message = "Gemini server error (HTTP \(status))\(apiReason) - transient, try again."
                default:
                    message = "Gemini REST error (HTTP \(status))\(apiReason)."
                }
                completion(.failure(NSError(domain: "GeminiAPI", code: status, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let rawStr = String(data: data, encoding: .utf8) ?? "Unknown"
                completion(.failure(NSError(domain: "JustSpeak", code: -5, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response: \(rawStr)"])))
                return
            }

            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                completion(.failure(NSError(domain: "GeminiAPI", code: (errorObj["code"] as? Int) ?? -1, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }

            // API-metered usage rides on every generateContent response.
            var inputTokens: Int? = nil
            var outputTokens: Int? = nil
            if let usage = json["usageMetadata"] as? [String: Any] {
                inputTokens = usage["promptTokenCount"] as? Int
                outputTokens = usage["candidatesTokenCount"] as? Int
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first {
                if let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    // The REST path prompts a general-purpose model to transcribe; its documented
                    // failure mode is answering instead of transcribing. Gate before this text
                    // ever reaches insertion (Feature: RestValidationGate).
                    let cleanedText = RestValidationGate.clean(text)
                    if let reason = RestValidationGate.rejectionReason(cleanedText) {
                        let prefix = String(cleanedText.prefix(80))
                        Logger.warn("GATE", "REST result rejected (\(reason)): \(prefix)")
                        completion(.failure(NSError(domain: "JustSpeak", code: -7, userInfo: [NSLocalizedDescriptionKey: "REST result rejected by validation gate: \(reason)"])))
                    } else {
                        completion(.success((text: cleanedText, latencyMs: elapsedMs, inputTokens: inputTokens, outputTokens: outputTokens)))
                    }
                } else {
                    // Speech model returned empty transcription (e.g. silent or non-speech audio)
                    completion(.success((text: "", latencyMs: elapsedMs, inputTokens: inputTokens, outputTokens: outputTokens)))
                }
            } else {
                completion(.failure(NSError(domain: "JustSpeak", code: -6, userInfo: [NSLocalizedDescriptionKey: "Could not extract candidate text from response."])))
            }
        }
        
        task.resume()
    }

    /// Extracts a short retry hint from a 429: the `Retry-After` header (seconds), else the
    /// google.rpc.RetryInfo "retryDelay": "2s" detail in the response body. nil if neither parses.
    private static func retryDelaySeconds(from data: Data, response: HTTPURLResponse?) -> Double? {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
            return seconds
        }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        if let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) {
            let match = String(body[range])
            let digits = match.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "." })
            return Double(digits)
        }
        return nil
    }
}

