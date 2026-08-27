// MARK: - CLI Entry Point

let args = CommandLine.arguments
let config = Config.load()

if args.contains("--check-permissions") || args.contains("-p") {
    PermissionChecker.printDetailedStatus()
    exit(0)
}

if args.contains("--test-api") {
    Diagnostics.runApiTest(config: config)
    exit(0)
}

if args.contains("--test-audio") {
    Diagnostics.runAudioTest(config: config)
    exit(0)
}

if args.contains("--analyze") {
    var days = 30
    if let idx = args.firstIndex(of: "--days"), idx + 1 < args.count, let d = Int(args[idx + 1]), d > 0 {
        days = min(365, d)
    }
    VocabularyAnalyzer.run(config: config, days: days)
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print(
        """
        JustSpeak - Ultra-Low-Latency Voice Dictation & Text Polishing

        Usage:
          ./justspeak [options]
          make run

        Options:
          --check-permissions, -p   Run diagnostic permissions checker
          --test-audio              Test 3-second mic capture and AI transcription
          --test-api                Test Gemini API connection and latency
          --analyze [--days N]      Mine dictation history for vocabulary suggestions (default 30 days)
          --help, -h                Show this help message

        Configuration is managed via .env or environment variables.
        """)
    exit(0)
}

let app = JustSpeakApp(config: config)
app.start()
