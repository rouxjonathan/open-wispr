import Foundation

public struct Recording {
    public let url: URL
    public let date: Date
}

public class RecordingStore {
    public static var recordingsDir = Config.configDir.appendingPathComponent("recordings")
    public static var debugRecordingsDir = Config.configDir.appendingPathComponent("debug-recordings")
    public static let debugMaxRecordings = 5

    static let filePrefix = "recording-"
    static let fileExtension = "wav"
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func ensureDirectory() {
        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            fputs("Warning: could not create recordings directory: \(error.localizedDescription)\n", stderr)
        }
    }

    public static func tempRecordingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("open-wispr-recording.wav")
    }

    public static func newRecordingURL() -> URL {
        ensureDirectory()
        let timestamp = dateFormatter.string(from: Date())
        let unique = String(UUID().uuidString.prefix(8))
        let filename = "\(filePrefix)\(timestamp)-\(unique).\(fileExtension)"
        return recordingsDir.appendingPathComponent(filename)
    }

    public static func listRecordings() -> [Recording] {
        ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == fileExtension && $0.lastPathComponent.hasPrefix(filePrefix) }
            .compactMap { url -> Recording? in
                let name = url.deletingPathExtension().lastPathComponent
                let dateString = String(name.dropFirst(filePrefix.count))
                let datePart = String(dateString.prefix(17))
                guard let date = dateFormatter.date(from: datePart) else { return nil }
                return Recording(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    public static func prune(maxCount: Int) {
        let recordings = listRecordings()
        guard recordings.count > maxCount else { return }

        let toRemove = recordings.suffix(from: maxCount)
        for recording in toRemove {
            do {
                try FileManager.default.removeItem(at: recording.url)
            } catch {
                fputs("Warning: could not remove old recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    public static func deleteAllRecordings() {
        for recording in listRecordings() {
            do {
                try FileManager.default.removeItem(at: recording.url)
            } catch {
                fputs("Warning: could not remove recording \(recording.url.path): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    public static func ensureDebugDirectory() {
        try? FileManager.default.createDirectory(at: debugRecordingsDir, withIntermediateDirectories: true)
    }

    /// Copy a recording into the rolling debug-recordings folder and prune to
    /// `debugMaxRecordings`. Independent of the user's `maxRecordings` setting
    /// so we always have the last few WAVs to listen to when diagnosing a
    /// dropped dictation. The dictation ID is embedded in the filename so the
    /// WAV can be matched back to its entries in the journal. Failures are
    /// logged, never propagated.
    @discardableResult
    public static func archiveForDebug(_ source: URL, id: String) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: debugRecordingsDir, withIntermediateDirectories: true)
        } catch {
            Logger.shared.log("recorder", "debug_archive_mkdir_failed id=\(id) err=\(error.localizedDescription)")
            return nil
        }

        let timestamp = dateFormatter.string(from: Date())
        let dest = debugRecordingsDir.appendingPathComponent("debug-\(timestamp)-\(id).\(fileExtension)")
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            Logger.shared.log("recorder", "debug_archive_copy_failed id=\(id) src=\(source.path) err=\(error.localizedDescription)")
            return nil
        }

        pruneDebug()
        return dest
    }

    private static func pruneDebug() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: debugRecordingsDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        let sorted = files
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
        guard sorted.count > debugMaxRecordings else { return }
        for url in sorted.suffix(from: debugMaxRecordings) {
            try? fm.removeItem(at: url)
        }
    }
}
