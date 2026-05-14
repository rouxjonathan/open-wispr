import Foundation

/// Append-only text journal for diagnosing dictation pipeline issues.
/// Thread-safe (serial queue), with size-based rotation at 5 MB (1 backup kept).
/// Output: ~/.config/open-wispr/journal.log
public final class Logger {
    public static let shared = Logger()

    private let queue = DispatchQueue(label: "open-wispr.logger", qos: .utility)
    private let formatter: DateFormatter
    private var handle: FileHandle?
    private var currentSize: Int = 0
    private let sessionID: String

    public static let maxSize: Int = 5 * 1024 * 1024

    public static var logFile: URL {
        Config.configDir.appendingPathComponent("journal.log")
    }

    public static var logFileBackup: URL {
        Config.configDir.appendingPathComponent("journal.log.1")
    }

    private init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        formatter = f
        sessionID = String(format: "%05d", getpid())
        openFile()
        log("session", "start pid=\(getpid()) version=\(OpenWispr.version)")
    }

    /// Log one event. `tag` identifies the pipeline layer (e.g. "hotkey",
    /// "recorder", "tap", "wav", "whisper", "insert", "system"). `msg` is the
    /// free-form payload; prefer `key=value` pairs separated by spaces.
    public func log(_ tag: String, _ msg: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let line = "\(self.formatter.string(from: Date())) [\(self.sessionID)] [\(tag)] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.handle?.write(data)
            self.currentSize += data.count
            if self.currentSize > Logger.maxSize {
                self.rotate()
            }
        }
    }

    /// Force a flush. Useful before sensitive operations or on shutdown.
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// Write a horizontal divider with no timestamp. Used to visually separate
    /// dictation sessions in the journal so consecutive blocks are easy to scan.
    public func separator() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let line = "\n" + String(repeating: "-", count: 100) + "\n"
            guard let data = line.data(using: .utf8) else { return }
            self.handle?.write(data)
            self.currentSize += data.count
        }
    }

    private func openFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Logger.logFile.path) {
            fm.createFile(atPath: Logger.logFile.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Logger.logFile)
        _ = try? handle?.seekToEnd()
        if let attrs = try? fm.attributesOfItem(atPath: Logger.logFile.path),
           let size = attrs[.size] as? Int {
            currentSize = size
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: Logger.logFileBackup)
        try? fm.moveItem(at: Logger.logFile, to: Logger.logFileBackup)
        currentSize = 0
        openFile()
    }
}

/// Format helpers so call sites stay short. Returns "k1=v1 k2=v2 ...".
public func logfmt(_ pairs: [(String, Any)]) -> String {
    pairs.map { key, value in
        let s = String(describing: value)
        if s.contains(" ") || s.contains("=") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(escaped)\""
        }
        return "\(key)=\(s)"
    }.joined(separator: " ")
}
