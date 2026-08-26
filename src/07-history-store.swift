// MARK: - Dictation History (SQLite)

// SQLite's bind-text destructor macro (SQLITE_TRANSIENT = (sqlite3_destructor_type)-1) isn't
// exposed to Swift by the C header, so it's reconstructed here the standard way.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Records every dictation turn - success, empty, or error - as one row in a local SQLite DB
/// so usage can be analyzed later (cost per day, latency percentiles, word counts). All sqlite3
/// calls happen on `queue`; that serial queue is the thread-safety story, no lock needed.
final class TranscriptionHistoryStore {
    struct TurnRecord {
        var outcome: String
        var text: String?
        var charCount: Int
        var wordCount: Int
        var transport: String?
        var model: String?
        var isLiveRoute: Bool?
        var fallbackReason: String?
        var audioSeconds: Double?
        var firstTokenMs: Double?
        var roundtripMs: Double?
        var captureFinalizeMs: Double?
        var injectMs: Double?
        var totalMs: Double?
        var injected: Bool?
        var inputTokens: Int?
        var outputTokens: Int?
        var tokensMetered: Bool?
        var costUSD: Double?
        var languageCodes: String
        var smartMode: Bool
        var vadMode: String
        var error: String?
        // App that was frontmost at key-down - where the dictation was aimed.
        var appBundleId: String?
        var appName: String?
    }

    private let queue = DispatchQueue(label: "com.justspeak.history", qos: .utility)
    private var db: OpaquePointer?
    private var failed = false
    private let dbPath: String
    private let sessionId = UUID().uuidString
    private static let isoFormatter = ISO8601DateFormatter()

    var path: String { dbPath }

    init(config: Config) {
        let rawPath = config.historyDbPath.isEmpty ? "~/.justspeak/history.db" : config.historyDbPath
        self.dbPath = (rawPath as NSString).expandingTildeInPath
    }

    // Called on-queue from record(). No-ops once already open or once opening has failed.
    private func openIfNeeded() {
        guard db == nil, !failed else { return }

        let dir = (dbPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            failed = true
            Logger.warn("HISTORY", "Failed to create history directory \(dir): \(error.localizedDescription)")
            return
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite3_open_v2 error"
            failed = true
            Logger.warn("HISTORY", "Failed to open history DB at \(dbPath): \(msg)")
            if let handle = handle { sqlite3_close(handle) }
            return
        }
        chmod(dbPath, 0o600)

        if sqlite3_exec(opened, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000;", nil, nil, nil) != SQLITE_OK {
            failed = true
            Logger.warn("HISTORY", "Failed to set history DB pragmas: \(String(cString: sqlite3_errmsg(opened)))")
            sqlite3_close(opened)
            return
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS transcriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts_utc TEXT NOT NULL,
          ts_epoch REAL NOT NULL,
          session_id TEXT NOT NULL,
          outcome TEXT NOT NULL,
          text TEXT,
          char_count INTEGER NOT NULL DEFAULT 0,
          word_count INTEGER NOT NULL DEFAULT 0,
          transport TEXT,
          model TEXT,
          is_live_route INTEGER,
          fallback_reason TEXT,
          audio_seconds REAL,
          first_token_ms REAL,
          roundtrip_ms REAL,
          capture_finalize_ms REAL,
          inject_ms REAL,
          total_ms REAL,
          injected INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          tokens_metered INTEGER,
          cost_usd REAL,
          language_codes TEXT,
          smart_mode INTEGER,
          vad_mode TEXT,
          error TEXT,
          app_bundle_id TEXT,
          app_name TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_transcriptions_ts ON transcriptions(ts_epoch);
        CREATE INDEX IF NOT EXISTS idx_transcriptions_session ON transcriptions(session_id);
        """
        if sqlite3_exec(opened, schema, nil, nil, nil) != SQLITE_OK {
            failed = true
            Logger.warn("HISTORY", "Failed to create history schema: \(String(cString: sqlite3_errmsg(opened)))")
            sqlite3_close(opened)
            return
        }

        // Columns added after the table first shipped. CREATE TABLE IF NOT EXISTS won't touch
        // an existing DB, so each new column is a best-effort ALTER whose "duplicate column"
        // failure on an already-migrated DB is expected and deliberately ignored.
        for migration in [
            "ALTER TABLE transcriptions ADD COLUMN app_bundle_id TEXT",
            "ALTER TABLE transcriptions ADD COLUMN app_name TEXT"
        ] {
            sqlite3_exec(opened, migration, nil, nil, nil)
        }

        db = opened
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value = value {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindBool(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Bool?) {
        if let value = value {
            sqlite3_bind_int(stmt, idx, value ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    func record(_ r: TurnRecord) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.openIfNeeded()
            guard !self.failed, let db = self.db else { return }

            let sql = """
            INSERT INTO transcriptions (
              ts_utc, ts_epoch, session_id, outcome, text, char_count, word_count,
              transport, model, is_live_route, fallback_reason, audio_seconds,
              first_token_ms, roundtrip_ms, capture_finalize_ms, inject_ms, total_ms,
              injected, input_tokens, output_tokens, tokens_metered, cost_usd,
              language_codes, smart_mode, vad_mode, error, app_bundle_id, app_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                self.failed = true
                Logger.warn("HISTORY", "Failed to prepare history insert: \(String(cString: sqlite3_errmsg(db)))")
                sqlite3_finalize(stmt)
                return
            }

            let now = Date()
            self.bindText(stmt, 1, TranscriptionHistoryStore.isoFormatter.string(from: now))
            self.bindDouble(stmt, 2, now.timeIntervalSince1970)
            self.bindText(stmt, 3, self.sessionId)
            self.bindText(stmt, 4, r.outcome)
            self.bindText(stmt, 5, r.text)
            self.bindInt(stmt, 6, r.charCount)
            self.bindInt(stmt, 7, r.wordCount)
            self.bindText(stmt, 8, r.transport)
            self.bindText(stmt, 9, r.model)
            self.bindBool(stmt, 10, r.isLiveRoute)
            self.bindText(stmt, 11, r.fallbackReason)
            self.bindDouble(stmt, 12, r.audioSeconds)
            self.bindDouble(stmt, 13, r.firstTokenMs)
            self.bindDouble(stmt, 14, r.roundtripMs)
            self.bindDouble(stmt, 15, r.captureFinalizeMs)
            self.bindDouble(stmt, 16, r.injectMs)
            self.bindDouble(stmt, 17, r.totalMs)
            self.bindBool(stmt, 18, r.injected)
            self.bindInt(stmt, 19, r.inputTokens)
            self.bindInt(stmt, 20, r.outputTokens)
            self.bindBool(stmt, 21, r.tokensMetered)
            self.bindDouble(stmt, 22, r.costUSD)
            self.bindText(stmt, 23, r.languageCodes)
            self.bindBool(stmt, 24, r.smartMode)
            self.bindText(stmt, 25, r.vadMode)
            self.bindText(stmt, 26, r.error)
            self.bindText(stmt, 27, r.appBundleId)
            self.bindText(stmt, 28, r.appName)

            if sqlite3_step(stmt) != SQLITE_DONE {
                self.failed = true
                Logger.warn("HISTORY", "Failed to insert history row: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }
    }

    func close() {
        queue.sync {
            guard let db = self.db else { return }
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            sqlite3_close(db)
            self.db = nil
        }
    }
}

