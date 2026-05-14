import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManager: HotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var isPressed = false
    var isReady = false
    public var lastTranscription: String?
    private var systemObservers: SystemObservers?
    private var lastHotkeyDownAt: Date?
    private var currentDictationID: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.log("lifecycle", "applicationDidFinishLaunching")
        statusBar = StatusBarController()
        recorder = AudioRecorder()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    private func setup() {
        do {
            try setupInner()
        } catch {
            print("Fatal setup error: \(error.localizedDescription)")
        }
    }

    private func setupInner() throws {
        config = Config.load()
        inserter = TextInserter()
        recorder.preferredDeviceID = config.audioInputDeviceID
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            RecordingStore.deleteAllRecordings()
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false
        transcriber.prompt = config.prompt

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.onConfigChange = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
            self.statusBar.buildMenu()
        }

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        if Permissions.didUpgrade() {
            print("Accessibility: upgrade detected, resetting permissions...")
            Permissions.resetAccessibility()
            Thread.sleep(forTimeInterval: 1)
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted")
            Permissions.openAccessibilitySettings()
            print("Waiting for Accessibility permission...")
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 0.5)
            }
            print("Accessibility: granted")
        } else {
            print("Accessibility: granted")
        }

        if !Transcriber.modelExists(modelSize: config.modelSize) {
            DispatchQueue.main.async {
                self.statusBar.state = .downloading
                self.statusBar.updateDownloadProgress("Downloading \(self.config.modelSize) model...")
            }
            print("Downloading \(config.modelSize) model...")
            try ModelDownloader.download(modelSize: config.modelSize) { [weak self] percent in
                DispatchQueue.main.async {
                    let pct = Int(percent)
                    self?.statusBar.updateDownloadProgress("Downloading \(self?.config.modelSize ?? "") model... \(pct)%", percent: percent)
                }
            }
            DispatchQueue.main.async {
                self.statusBar.updateDownloadProgress(nil)
            }
        }

        if let modelPath = Transcriber.findModel(modelSize: config.modelSize) {
            let modelURL = URL(fileURLWithPath: modelPath)
            if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                let msg = "Model file is corrupted. Re-download with: open-wispr download-model \(config.modelSize)"
                print("Error: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
                return
            }
        }

        recorder.prewarm()

        // Load the whisper model into memory now so the first dictation pays
        // only the encode/decode cost, not the ~600ms model load.
        transcriber.prewarmEngine()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let observers = SystemObservers()
            observers.start(currentEngine: self.recorder.liveEngine)
            self.systemObservers = observers
            self.startListening()
        }
    }

    private func startListening() {
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )

        hotkeyManager?.start(
            onKeyDown: { [weak self] in
                self?.handleKeyDown()
            },
            onKeyUp: { [weak self] in
                self?.handleKeyUp()
            }
        )

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("open-wispr v\(OpenWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
    }

    public func reloadConfig() {
        let newConfig = Config.load()
        applyConfigChange(newConfig)
    }

    func applyConfigChange(_ newConfig: Config) {
        guard isReady else { return }
        let wasDownloading: Bool
        if case .downloading = statusBar.state { wasDownloading = true } else { wasDownloading = false }
        let deviceChanged = recorder.preferredDeviceID != newConfig.audioInputDeviceID
        Logger.shared.log("config", "applyConfigChange " + logfmt([
            ("device_changed", deviceChanged),
            ("new_device", newConfig.audioInputDeviceID.map(String.init) ?? "nil"),
            ("new_model", newConfig.modelSize),
            ("new_language", newConfig.language),
        ]))
        config = newConfig
        recorder.preferredDeviceID = config.audioInputDeviceID
        if deviceChanged {
            recorder.reload()
            systemObservers?.updateEngine(recorder.liveEngine)
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false
        transcriber.prompt = config.prompt
        inserter = TextInserter()

        // Reload the whisper model in the background — it can be hundreds of MB.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcriber.prewarmEngine()
        }

        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )

        if !wasDownloading && !Transcriber.modelExists(modelSize: config.modelSize) {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress("Downloading \(config.modelSize) model...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try ModelDownloader.download(modelSize: newConfig.modelSize) { percent in
                        DispatchQueue.main.async {
                            let pct = Int(percent)
                            self?.statusBar.updateDownloadProgress("Downloading \(newConfig.modelSize) model... \(pct)%", percent: percent)
                        }
                    }
                    DispatchQueue.main.async {
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("Error downloading model: \(error.localizedDescription)")
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                }
            }
        }

        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("Config updated: lang=\(config.language) model=\(config.modelSize) hotkey=\(hotkeyDesc)")
    }

    private func handleKeyDown() {
        let isToggle = config?.toggleMode?.value ?? false
        Logger.shared.log("hotkey", "down " + logfmt([
            ("ready", isReady),
            ("pressed", isPressed),
            ("toggle", isToggle),
        ]))
        guard isReady else { return }

        if isToggle {
            if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart()
            }
        } else {
            guard !isPressed else { return }
            handleRecordingStart()
        }
    }

    private func handleKeyUp() {
        let isToggle = config?.toggleMode?.value ?? false
        Logger.shared.log("hotkey", "up " + logfmt([
            ("ready", isReady),
            ("pressed", isPressed),
            ("toggle", isToggle),
        ]))
        if isToggle { return }
        handleRecordingStop()
    }

    private func handleRecordingStart() {
        guard !isPressed else { return }
        isPressed = true
        lastHotkeyDownAt = Date()
        let id = String(UUID().uuidString.prefix(8)).uppercased()
        currentDictationID = id
        Logger.shared.separator()
        let isTemp = Config.effectiveMaxRecordings(config.maxRecordings) == 0
        Logger.shared.log("recording", "start_enter " + logfmt([
            ("id", id),
            ("temp_mode", isTemp),
        ]))
        statusBar.state = .recording
        do {
            let outputURL: URL
            if isTemp {
                outputURL = RecordingStore.tempRecordingURL()
            } else {
                outputURL = RecordingStore.newRecordingURL()
            }
            try recorder.startRecording(to: outputURL)
            Logger.shared.log("recording", "start_ok " + logfmt([
                ("id", id),
                ("url", outputURL.path),
            ]))
        } catch {
            Logger.shared.log("recording", "start_error " + logfmt([
                ("id", id),
                ("err", error.localizedDescription),
            ]))
            print("Error: \(error.localizedDescription)")
            isPressed = false
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false
        let id = currentDictationID ?? "UNKNOWN"
        let downAt = lastHotkeyDownAt
        let holdMs: Int = downAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        Logger.shared.log("recording", "stop_enter " + logfmt([
            ("id", id),
            ("hold_ms", holdMs),
        ]))

        guard let audioURL = recorder.stopRecording() else {
            Logger.shared.log("recording", "stop_no_url " + logfmt([
                ("id", id),
                ("reason", "recorder_returned_nil"),
            ]))
            statusBar.state = .idle
            return
        }

        // Archive a copy independently of the user's maxRecordings setting so we
        // always have the last 5 raw WAVs to listen back when diagnosing.
        if let archived = RecordingStore.archiveForDebug(audioURL, id: id) {
            Logger.shared.log("recorder", "debug_archived " + logfmt([
                ("id", id),
                ("wav", archived.lastPathComponent),
            ]))
        }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            defer {
                if maxRecordings == 0 {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let punct = self.config.spokenPunctuation?.value ?? false
                let afterPunct = punct ? TextPostProcessor.process(raw) : raw
                let text = TextPostProcessor.applyReplacements(afterPunct, replacements: Config.normalizedReplacements(self.config.replacements))
                Logger.shared.log("postprocess", "applied " + logfmt([
                    ("punct_mode", punct),
                    ("after_punct_len", afterPunct.count),
                    ("final_len", text.count),
                    ("final_is_empty", text.isEmpty),
                ]))
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        Logger.shared.log("flow", "insert_branch text_len=\(text.count)")
                        self.inserter.insert(text: text)
                    } else {
                        Logger.shared.log("flow", "empty_branch reason=empty_text_after_postprocess")
                    }
                    self.statusBar.state = .idle
                    Logger.shared.log("state", "-> idle")
                    self.statusBar.buildMenu()
                }
            } catch {
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    Logger.shared.log("flow", "error_branch err=\(error.localizedDescription)")
                    print("Error: \(error.localizedDescription)")
                    self.statusBar.state = .error(error.localizedDescription)
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if case .error = self.statusBar.state {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            }
        }
    }

    public func reprocess(audioURL: URL) {
        guard case .idle = statusBar.state else { return }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                var text = (self.config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
                text = TextPostProcessor.applyReplacements(text, replacements: Config.normalizedReplacements(self.config.replacements))
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.statusBar.state = .copiedToClipboard
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                }
            }
        }
    }
}
