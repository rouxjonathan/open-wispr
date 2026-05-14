import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var inputFormat: AVAudioFormat?
    private var isRecording = false
    private var currentOutputURL: URL?
    var preferredDeviceID: AudioDeviceID?

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
        if let deviceID = preferredDeviceID, deviceID != systemDefault {
            Logger.shared.log("recorder", "prewarm_setInputDevice " + logfmt([
                ("requested", deviceID),
                ("system_default", systemDefault),
            ]))
            setInputDevice(deviceID, on: engine)
        } else {
            Logger.shared.log("recorder", "prewarm_useDefault " + logfmt([
                ("preferred", preferredDeviceID.map(String.init) ?? "nil"),
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
        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.shared.log("recorder", "prewarm_done " + logfmt([
            ("elapsed_ms", elapsedMs),
            ("engine_running", engine.isRunning),
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
        audioEngine?.stop()
        audioEngine = nil
        inputFormat = nil
    }

    /// Re-prewarm with the current preferredDeviceID. Use after a config change.
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
        }

        guard let engine = audioEngine, let inputFmt = inputFormat else {
            Logger.shared.log("recorder", "startRecording_failed reason=engine_unavailable")
            throw NSError(
                domain: "OpenWispr.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine is not available"]
            )
        }

        let liveFormat = engine.inputNode.outputFormat(forBus: 0)
        Logger.shared.log("recorder", "startRecording_state " + logfmt([
            ("engine_running", engine.isRunning),
            ("cached_sample_rate", inputFmt.sampleRate),
            ("cached_channels", inputFmt.channelCount),
            ("live_sample_rate", liveFormat.sampleRate),
            ("live_channels", liveFormat.channelCount),
            ("did_reprewarm", didReprewarm),
        ]))

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

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: outputURL, settings: settings)
        } catch {
            Logger.shared.log("recorder", "startRecording_avfile_failed url=\(outputURL.path) err=\(error.localizedDescription)")
            throw error
        }

        guard let converter = AVAudioConverter(from: inputFmt, to: recordingFormat) else {
            Logger.shared.log("recorder", "startRecording_converter_failed in_sr=\(inputFmt.sampleRate) in_ch=\(inputFmt.channelCount)")
            throw NSError(
                domain: "OpenWispr.AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"]
            )
        }

        resetTapStats()

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) { [weak self] buffer, _ in
            guard let self = self else { return }

            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * 16000.0 / inputFmt.sampleRate
                )
            )!

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
                do {
                    try file.write(from: convertedBuffer)
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
            ("engine_running_after_stop", audioEngine?.isRunning ?? false),
        ]))

        return url
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
