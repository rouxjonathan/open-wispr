import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var inputFormat: AVAudioFormat?
    private var isRecording = false
    private var currentOutputURL: URL?
    /// The file the tap is writing into. Held here — rather than only captured
    /// by the tap closure — so stopRecording can release it deterministically.
    /// AVAudioFile writes the real RIFF and data chunk sizes into the header
    /// only when it deallocates, and CoreAudio can keep the tap closure alive
    /// past removeTap. Losing that race left a WAV holding every captured byte
    /// while advertising zero frames, which the transcriber read as silence.
    private var outputFile: AVAudioFile?
    /// Guards outputFile between the real-time tap thread and stopRecording.
    private let outputFileLock = NSLock()
    /// Stable UID for the user's preferred input device. nil means "follow system default".
    /// AudioDeviceIDs are reassigned on each boot, so we resolve UID → ID at prewarm time.
    var preferredDeviceUID: String?
    /// The CoreAudio device the live engine is actually bound to, captured at
    /// prewarm. AVAudioEngine binds its input node once, at creation, and never
    /// follows later system-default changes — so we compare this against the
    /// current target before each recording and rebuild when they diverge.
    private var boundDeviceID: AudioDeviceID?

    // Tap-callback aggregates for the current recording. Reset on each
    // startRecording, summarized at stopRecording.
    private var tapCallbacks: Int = 0
    private var tapInFrames: Int64 = 0
    private var tapOutFrames: Int64 = 0
    private var tapConverterErrors: Int = 0
    private var tapWriteErrors: Int = 0
    private var tapFirstCallbackAt: Date?
    private var tapLastCallbackAt: Date?
    private var tapPeak: Float = 0
    private var tapSumSquares: Double = 0
    private var tapSampleCount: Int64 = 0

    /// Allow external code to observe the live engine (for system-event
    /// instrumentation that reports `engine.isRunning`).
    var liveEngine: AVAudioEngine? { audioEngine }

    /// True between startRecording and stopRecording. Callers use it to defer
    /// an engine rebuild instead of yanking the tap out from under a dictation.
    var isCapturing: Bool { isRecording }

    /// The device we should be capturing from right now: the preferred one if
    /// it is currently plugged in, otherwise whatever CoreAudio reports as the
    /// system default input.
    private func currentTargetDeviceID() -> AudioDeviceID {
        if let uid = preferredDeviceUID, let deviceID = AudioDeviceManager.findDeviceID(byUID: uid) {
            return deviceID
        }
        return AudioDeviceManager.getDefaultInputDeviceID()
    }

    /// Bring the audio engine online and keep it running. Subsequent
    /// startRecording calls only need to install a tap, which is cheap;
    /// the ~600ms cost of engine.start() is paid once at app launch.
    func prewarm() {
        guard audioEngine == nil else {
            Logger.shared.log("recorder", "prewarm_skipped reason=already_warm")
            return
        }

        let t0 = Date()
        let engine = AVAudioEngine()

        let systemDefault = AudioDeviceManager.getDefaultInputDeviceID()
        var bound = systemDefault
        if let uid = preferredDeviceUID {
            if let deviceID = AudioDeviceManager.findDeviceID(byUID: uid) {
                bound = deviceID
                if deviceID != systemDefault {
                    Logger.shared.log("recorder", "prewarm_setInputDevice " + logfmt([
                        ("uid", uid),
                        ("resolved_id", deviceID),
                        ("system_default", systemDefault),
                    ]))
                    setInputDevice(deviceID, on: engine)
                } else {
                    Logger.shared.log("recorder", "prewarm_uid_matches_default " + logfmt([
                        ("uid", uid),
                        ("system_default", systemDefault),
                    ]))
                }
            } else {
                Logger.shared.log("recorder", "prewarm_uid_unresolved_fallback_default " + logfmt([
                    ("uid", uid),
                    ("system_default", systemDefault),
                ]))
            }
        } else {
            Logger.shared.log("recorder", "prewarm_useDefault " + logfmt([
                ("system_default", systemDefault),
            ]))
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        Logger.shared.log("recorder", "prewarm_inputFormat " + logfmt([
            ("sample_rate", format.sampleRate),
            ("channels", format.channelCount),
            ("common_format", format.commonFormat.rawValue),
        ]))

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Logger.shared.log("recorder", "prewarm_start_failed err=\(error.localizedDescription)")
            print("Audio engine prewarm error: \(error.localizedDescription)")
            return
        }

        audioEngine = engine
        inputFormat = format
        boundDeviceID = bound
        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.shared.log("recorder", "prewarm_done " + logfmt([
            ("elapsed_ms", elapsedMs),
            ("engine_running", engine.isRunning),
            ("bound_device", bound),
        ]))
    }

    /// Stop and release the engine. Call before changing input device or on shutdown.
    func teardown() {
        Logger.shared.log("recorder", "teardown " + logfmt([
            ("was_recording", isRecording),
            ("engine_running", audioEngine?.isRunning ?? false),
        ]))
        if isRecording {
            audioEngine?.inputNode.removeTap(onBus: 0)
            isRecording = false
            currentOutputURL = nil
        }
        closeOutputFile()
        audioEngine?.stop()
        audioEngine = nil
        inputFormat = nil
        boundDeviceID = nil
    }

    /// Re-prewarm with the current preferredDeviceUID. Use after a config change.
    func reload() {
        Logger.shared.log("recorder", "reload")
        teardown()
        prewarm()
    }

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else {
            Logger.shared.log("recorder", "startRecording_noop reason=already_recording")
            return
        }

        let t0 = Date()
        var didReprewarm = false
        if audioEngine == nil {
            Logger.shared.log("recorder", "startRecording_prewarm_needed")
            prewarm()
            didReprewarm = true
        } else if let bound = boundDeviceID {
            // The input node is welded to the device it was created with. If the
            // system default moved (AirPods connected, dock unplugged) the node
            // is now pointing at the wrong — possibly dead — hardware, and its
            // reported format is stale. Rebuild rather than record silence.
            let target = currentTargetDeviceID()
            if target != bound {
                Logger.shared.log("recorder", "startRecording_device_moved " + logfmt([
                    ("bound_device", bound),
                    ("target_device", target),
                ]))
                teardown()
                prewarm()
                didReprewarm = true
            }
        }

        guard let engine = audioEngine, let inputFmt = inputFormat else {
            Logger.shared.log("recorder", "startRecording_failed reason=engine_unavailable")
            throw NSError(
                domain: "OpenWispr.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine is not available"]
            )
        }

        // If the engine stopped silently between dictations (AirPods connect,
        // default device change, sleep/wake, App Nap), the tap would install
        // fine but receive zero buffers → empty WAV → silent failure. Restart
        // in place — Apple's recommended response to AVAudioEngineConfiguration
        // Change is engine.prepare() + start(), which is much cheaper than a
        // full teardown/prewarm and preserves the inputNode the tap will
        // attach to.
        var didRecover = false
        if !engine.isRunning {
            let tRecover = Date()
            engine.prepare()
            do {
                try engine.start()
                didRecover = true
                let elapsedMs = Int(Date().timeIntervalSince(tRecover) * 1000)
                Logger.shared.log("recorder", "startRecording_recovered " + logfmt([
                    ("elapsed_ms", elapsedMs),
                    ("engine_running", engine.isRunning),
                ]))
            } catch {
                Logger.shared.log("recorder", "startRecording_recover_failed err=\(error.localizedDescription)")
                // Fall through — installTap still works, the tap just won't
                // fire. The journal will show tap_callbacks=0 as before.
            }
        }

        let liveFormat = engine.inputNode.outputFormat(forBus: 0)
        Logger.shared.log("recorder", "startRecording_state " + logfmt([
            ("engine_running", engine.isRunning),
            ("cached_sample_rate", inputFmt.sampleRate),
            ("cached_channels", inputFmt.channelCount),
            ("live_sample_rate", liveFormat.sampleRate),
            ("live_channels", liveFormat.channelCount),
            ("bound_device", boundDeviceID ?? 0),
            ("did_reprewarm", didReprewarm),
            ("did_recover", didRecover),
        ]))

        guard liveFormat.sampleRate > 0, liveFormat.channelCount > 0 else {
            Logger.shared.log("recorder", "startRecording_failed reason=invalid_input_format " + logfmt([
                ("sample_rate", liveFormat.sampleRate),
                ("channels", liveFormat.channelCount),
            ]))
            throw NSError(
                domain: "OpenWispr.AudioRecorder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio input device reported an unusable format"]
            )
        }
        // The live format is the truth from here on; the cached one may predate
        // a device change.
        inputFormat = liveFormat

        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        // A recording that was never stopped would otherwise keep its header
        // unfinalized for good.
        closeOutputFile()

        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        } catch {
            Logger.shared.log("recorder", "startRecording_avfile_failed url=\(outputURL.path) err=\(error.localizedDescription)")
            throw error
        }

        resetTapStats()

        // Built lazily from the first buffer's own format, and rebuilt if that
        // format ever changes mid-recording. Deriving it from the buffer rather
        // than from a snapshot taken before installTap keeps the converter in
        // sync with whatever the hardware actually delivers.
        var converter: AVAudioConverter?

        // format: nil tells AVAudioEngine to use the input node's own format.
        // Passing an explicit format that disagrees with the hardware raises an
        // Objective-C exception that AppKit swallows mid-call, leaving the
        // recording half-started and silent.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }

            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: recordingFormat)
            }
            guard let converter = converter, buffer.frameLength > 0 else {
                self.tapConverterErrors += 1
                return
            }

            let capacity = AVAudioFrameCount(
                max(1.0, Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: capacity
            ) else {
                self.tapConverterErrors += 1
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            self.tapCallbacks += 1
            self.tapInFrames += Int64(buffer.frameLength)
            self.tapOutFrames += Int64(convertedBuffer.frameLength)
            if self.tapFirstCallbackAt == nil { self.tapFirstCallbackAt = Date() }
            self.tapLastCallbackAt = Date()
            if error != nil { self.tapConverterErrors += 1 }

            if let channelData = convertedBuffer.floatChannelData?[0] {
                let n = Int(convertedBuffer.frameLength)
                var sum: Double = 0
                var peak: Float = 0
                for i in 0..<n {
                    let v = channelData[i]
                    let a = v < 0 ? -v : v
                    if a > peak { peak = a }
                    sum += Double(v) * Double(v)
                }
                self.tapSumSquares += sum
                self.tapSampleCount += Int64(n)
                if peak > self.tapPeak { self.tapPeak = peak }
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                // Reaching the file through self, under the lock, keeps the
                // closure from holding the only strong reference to it: the
                // header can then be finalized the moment stopRecording says so.
                self.outputFileLock.lock()
                defer { self.outputFileLock.unlock() }
                do {
                    try self.outputFile?.write(from: convertedBuffer)
                } catch {
                    self.tapWriteErrors += 1
                }
            }
        }

        currentOutputURL = outputURL
        isRecording = true

        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.shared.log("recorder", "startRecording_done " + logfmt([
            ("elapsed_ms", elapsedMs),
            ("output_url", outputURL.path),
        ]))
    }

    func stopRecording() -> URL? {
        guard isRecording else {
            Logger.shared.log("recorder", "stopRecording_noop reason=not_recording")
            return nil
        }
        isRecording = false

        let url = currentOutputURL
        currentOutputURL = nil

        audioEngine?.inputNode.removeTap(onBus: 0)

        // Must happen before anything reads the file back: until the header is
        // finalized the WAV reports zero frames no matter how much audio it holds.
        let writtenFrames = closeOutputFile()
        var headerFrames: Int64 = -1
        if let path = url, let reader = try? AVAudioFile(forReading: path) {
            headerFrames = reader.length
        }
        if writtenFrames > 0 && headerFrames != writtenFrames {
            Logger.shared.log("recorder", "stopRecording_header_mismatch " + logfmt([
                ("written_frames", writtenFrames),
                ("header_frames", headerFrames),
            ]))
        }

        let rms: Double
        if tapSampleCount > 0 {
            rms = (tapSumSquares / Double(tapSampleCount)).squareRoot()
        } else {
            rms = 0
        }

        let firstAt = tapFirstCallbackAt
        let lastAt = tapLastCallbackAt
        let tapSpanMs: Int
        if let f = firstAt, let l = lastAt {
            tapSpanMs = Int(l.timeIntervalSince(f) * 1000)
        } else {
            tapSpanMs = 0
        }

        var fileSize: Int = -1
        if let path = url?.path,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int {
            fileSize = size
        }

        Logger.shared.log("recorder", "stopRecording_summary " + logfmt([
            ("tap_callbacks", tapCallbacks),
            ("tap_in_frames", tapInFrames),
            ("tap_out_frames", tapOutFrames),
            ("converter_errors", tapConverterErrors),
            ("write_errors", tapWriteErrors),
            ("tap_span_ms", tapSpanMs),
            ("peak", String(format: "%.5f", tapPeak)),
            ("rms", String(format: "%.5f", rms)),
            ("file_size_bytes", fileSize),
            ("written_frames", writtenFrames),
            ("header_frames", headerFrames),
            ("engine_running_after_stop", audioEngine?.isRunning ?? false),
        ]))

        return url
    }

    /// Release the tap's AVAudioFile so its deallocation writes the real RIFF
    /// and data chunk sizes into the WAV header. Safe to call with no recording
    /// in flight. Returns the frames the file reported while still open, or -1
    /// when there was no file.
    @discardableResult
    private func closeOutputFile() -> Int64 {
        outputFileLock.lock()
        let file = outputFile
        outputFile = nil
        outputFileLock.unlock()
        // Deallocating outside the lock matters: finalizing the header touches
        // the disk, and the tap runs on a real-time thread that should never
        // wait on that. ARC releases `file` here at the latest, so the header
        // is on disk before this returns.
        return file.map { Int64($0.length) } ?? -1
    }

    private func resetTapStats() {
        tapCallbacks = 0
        tapInFrames = 0
        tapOutFrames = 0
        tapConverterErrors = 0
        tapWriteErrors = 0
        tapFirstCallbackAt = nil
        tapLastCallbackAt = nil
        tapPeak = 0
        tapSumSquares = 0
        tapSampleCount = 0
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger.shared.log("recorder", "setInputDevice_no_audio_unit")
            print("Warning: could not access audio unit to set input device")
            return
        }

        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        Logger.shared.log("recorder", "setInputDevice_result " + logfmt([
            ("device_id", deviceID),
            ("status", status),
        ]))
        if status != noErr {
            print("Warning: failed to set audio input device (status: \(status))")
        }
    }
}
