import Foundation

public class Transcriber {
    private let modelSize: String
    private let language: String
    public var spokenPunctuation: Bool = false
    public var prompt: String?

    /// In-process whisper engine. Created lazily on first transcribe so model
    /// load happens in the background (caller can prewarm by calling
    /// `prewarmEngine()` after init). If init fails (e.g. libwhisper missing),
    /// we transparently fall back to spawning whisper-cli.
    private var engine: WhisperEngine?
    private var engineInitTried = false
    private let engineLock = NSLock()

    public init(modelSize: String = "base.en", language: String = "en") {
        self.modelSize = modelSize
        self.language = language
    }

    /// Pre-load the model into memory. Safe to call multiple times.
    /// Call from a background queue at app startup or after a model change.
    public func prewarmEngine() {
        _ = ensureEngine()
    }

    private func ensureEngine() -> WhisperEngine? {
        engineLock.lock()
        defer { engineLock.unlock() }

        if let engine = engine { return engine }
        if engineInitTried { return nil }
        engineInitTried = true

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            Logger.shared.log("transcriber", "ensure_engine_no_model model_size=\(modelSize)")
            return nil
        }
        let started = Date()
        guard let engine = WhisperEngine(modelPath: modelPath, modelSize: modelSize) else {
            Logger.shared.log("transcriber", "ensure_engine_fallback_subprocess model_size=\(modelSize)")
            fputs("whisper engine: in-process init failed, will fall back to whisper-cli subprocess\n", Foundation.stderr)
            return nil
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        print("whisper engine: model loaded in \(elapsed)ms (\(modelSize))")
        self.engine = engine
        return engine
    }

    public func transcribe(audioURL: URL) throws -> String {
        let t0 = Date()
        Logger.shared.log("transcriber", "transcribe_enter " + logfmt([
            ("url", audioURL.path),
            ("language", language),
            ("model_size", modelSize),
            ("prompt_len", prompt?.count ?? 0),
            ("spoken_punctuation", spokenPunctuation),
        ]))
        do {
            let text: String
            if let engine = ensureEngine() {
                Logger.shared.log("transcriber", "branch=in_process")
                text = try transcribeInProcess(engine: engine, audioURL: audioURL)
            } else {
                Logger.shared.log("transcriber", "branch=subprocess")
                text = try transcribeViaSubprocess(audioURL: audioURL)
            }
            let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.shared.log("transcriber", "transcribe_exit " + logfmt([
                ("elapsed_ms", elapsedMs),
                ("text_len", text.count),
                ("text_is_empty", text.isEmpty),
            ]))
            return text
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.shared.log("transcriber", "transcribe_error " + logfmt([
                ("elapsed_ms", elapsedMs),
                ("err", error.localizedDescription),
            ]))
            throw error
        }
    }

    private func transcribeInProcess(engine: WhisperEngine, audioURL: URL) throws -> String {
        let samples = try WAVDecoder.loadAsFloat32(url: audioURL)
        let raw = try engine.transcribe(
            samples: samples,
            language: language,
            prompt: prompt,
            suppressRegex: spokenPunctuation ? "[,\\.\\?!;:\\-—]" : nil
        )
        let stripped = Transcriber.stripWhisperMarkers(raw)
        Logger.shared.log("transcriber", "after_strip_markers " + logfmt([
            ("raw_len", raw.count),
            ("stripped_len", stripped.count),
        ]))
        return stripped
    }

    private func transcribeViaSubprocess(audioURL: URL) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw TranscriberError.modelNotFound(modelSize)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "--no-timestamps",
            "-nt",
        ]
        if spokenPunctuation {
            args += ["--suppress-regex", "[,\\.\\?!;:\\-—]"]
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var stderrData = Data()
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrThread.start()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while !stderrThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        process.waitUntilExit()

        let output = Transcriber.stripWhisperMarkers(
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    private static let knownMarkers: Set<String> = [
        "BLANK_AUDIO", "blank_audio",
        "Music", "MUSIC", "music",
        "Applause", "APPLAUSE", "applause",
        "Laughter", "LAUGHTER", "laughter",
        "silence", "Silence", "SILENCE",
        "SOUND", "Sound", "sound",
        "NOISE", "Noise", "noise",
        "INAUDIBLE", "inaudible",
    ]

    private static let markerRegex = try! NSRegularExpression(
        pattern: "[\\[\\(]\\s*([^\\]\\)]+?)\\s*[\\]\\)]"
    )

    public static func stripWhisperMarkers(_ text: String) -> String {
        let nsText = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let inner = nsText.substring(with: innerRange)
            if knownMarkers.contains(inner) {
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func findWhisperBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        let candidates = [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: open-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
