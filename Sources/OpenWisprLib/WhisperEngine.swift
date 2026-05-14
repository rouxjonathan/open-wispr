import AVFoundation
import CWhisper
import Foundation

/// In-process whisper.cpp wrapper. Loads the model once and keeps it resident
/// so each transcription pays only the encode/decode cost, not the ~600ms
/// model-load + ~500ms process-spawn that whisper-cli incurs per invocation.
final class WhisperEngine {
    private let context: OpaquePointer
    let modelSize: String

    /// Loads Metal / BLAS / CPU backend plugins (.so files) the first time
    /// any WhisperEngine is constructed. whisper-cli does this implicitly,
    /// but as a library consumer we must call it ourselves or model load
    /// aborts with `GGML_ASSERT(device) failed`. Also routes whisper's
    /// chatty internal logs (one block per inference) to a noop, otherwise
    /// they print to stdout/stderr on every dictation.
    private static let backendsLoaded: Bool = {
        let noopLog: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in }
        whisper_log_set(noopLog, nil)
        ggml_log_set(noopLog, nil)
        ggml_backend_load_all()
        return true
    }()

    init?(modelPath: String, modelSize: String) {
        _ = WhisperEngine.backendsLoaded

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        let t0 = Date()
        Logger.shared.log("whisper", "init_start " + logfmt([
            ("model_path", modelPath),
            ("model_size", modelSize),
            ("use_gpu", params.use_gpu),
            ("flash_attn", params.flash_attn),
        ]))

        // Use the no-state variant so we can allocate a fresh whisper_state for
        // each transcription. Sharing one state across calls causes residual
        // KV-cache / detected-language to leak between runs (we observed the
        // second call returning English even with language="fr" explicitly set).
        guard let ctx = modelPath.withCString({ whisper_init_from_file_with_params_no_state($0, params) }) else {
            Logger.shared.log("whisper", "init_failed model_size=\(modelSize)")
            return nil
        }
        self.context = ctx
        self.modelSize = modelSize
        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.shared.log("whisper", "init_done " + logfmt([
            ("elapsed_ms", elapsedMs),
            ("model_size", modelSize),
        ]))
    }

    deinit {
        whisper_free(context)
    }

    /// Run whisper end-to-end on float32 PCM mono samples at 16kHz.
    /// `language` should be a 2-letter ISO code or "auto".
    func transcribe(
        samples: [Float],
        language: String,
        prompt: String?,
        suppressRegex: String?
    ) throws -> String {
        // Match whisper-cli's defaults: beam-size 5, best-of 5. Picking GREEDY
        // would be faster but produces measurably worse French transcripts
        // (dropped words). User explicitly asked to keep decoding quality.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.single_segment = false
        params.suppress_blank = true
        params.no_context = true
        params.translate = false

        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log("whisper", "transcribe_start " + logfmt([
            ("samples", samples.count),
            ("seconds", String(format: "%.2f", Double(samples.count) / 16000.0)),
            ("language", language),
            ("prompt_len", trimmedPrompt?.count ?? 0),
            ("suppress_regex_len", suppressRegex?.count ?? 0),
        ]))
        let t0 = Date()

        return try language.withCString { langPtr -> String in
            params.language = langPtr

            let promptCString: ContiguousArray<CChar>? = (trimmedPrompt?.isEmpty == false)
                ? ContiguousArray(trimmedPrompt!.utf8CString)
                : nil
            let regexCString: ContiguousArray<CChar>? = (suppressRegex?.isEmpty == false)
                ? ContiguousArray(suppressRegex!.utf8CString)
                : nil

            return try promptCString.withOptionalUnsafeBufferPointer { promptBuf in
                try regexCString.withOptionalUnsafeBufferPointer { regexBuf in
                    params.initial_prompt = promptBuf?.baseAddress
                    params.suppress_regex = regexBuf?.baseAddress

                    guard let state = whisper_init_state(context) else {
                        Logger.shared.log("whisper", "transcribe_init_state_failed")
                        throw TranscriberError.transcriptionFailed
                    }
                    defer { whisper_free_state(state) }

                    let result: Int32 = samples.withUnsafeBufferPointer { buf in
                        whisper_full_with_state(context, state, params, buf.baseAddress, Int32(buf.count))
                    }
                    if result != 0 {
                        Logger.shared.log("whisper", "transcribe_failed code=\(result)")
                        throw TranscriberError.transcriptionFailed
                    }

                    let nSegments = whisper_full_n_segments_from_state(state)
                    var output = ""
                    for i in 0..<nSegments {
                        if let cstr = whisper_full_get_segment_text_from_state(state, i) {
                            output += String(cString: cstr)
                        }
                    }
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
                    let preview = trimmed.prefix(200)
                    Logger.shared.log("whisper", "transcribe_done " + logfmt([
                        ("elapsed_ms", elapsedMs),
                        ("n_segments", nSegments),
                        ("raw_len", trimmed.count),
                        ("raw_preview", preview),
                    ]))
                    return trimmed
                }
            }
        }
    }
}

private extension Optional where Wrapped == ContiguousArray<CChar> {
    func withOptionalUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<CChar>?) throws -> R) rethrows -> R {
        switch self {
        case .some(let array):
            return try array.withUnsafeBufferPointer { try body($0) }
        case .none:
            return try body(nil)
        }
    }
}

/// Decode a 16kHz mono WAV (PCM16 or float32) into the float32 PCM samples
/// whisper.cpp expects. Returns samples in [-1.0, 1.0].
enum WAVDecoder {
    static func loadAsFloat32(url: URL) throws -> [Float] {
        var fileSize: Int = -1
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            fileSize = size
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Logger.shared.log("wav", "open_failed url=\(url.path) size=\(fileSize) err=\(error.localizedDescription)")
            throw error
        }
        let processingFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        Logger.shared.log("wav", "open " + logfmt([
            ("file_size", fileSize),
            ("frame_count", file.length),
            ("sample_rate", processingFormat.sampleRate),
            ("channels", processingFormat.channelCount),
            ("common_format", processingFormat.commonFormat.rawValue),
        ]))
        guard frameCount > 0 else {
            Logger.shared.log("wav", "empty_file")
            return []
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            Logger.shared.log("wav", "pcm_buffer_alloc_failed")
            throw NSError(domain: "OpenWispr.WAVDecoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }
        do {
            try file.read(into: buffer)
        } catch {
            Logger.shared.log("wav", "read_failed err=\(error.localizedDescription)")
            throw error
        }

        guard let channels = buffer.floatChannelData else {
            Logger.shared.log("wav", "no_float_channel_data")
            throw NSError(domain: "OpenWispr.WAVDecoder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PCM buffer missing float channel data"])
        }
        let count = Int(buffer.frameLength)
        let channelCount = Int(processingFormat.channelCount)

        let result: [Float]
        if channelCount == 1 {
            result = Array(UnsafeBufferPointer(start: channels[0], count: count))
        } else {
            var mono = [Float](repeating: 0, count: count)
            for c in 0..<channelCount {
                let ch = channels[c]
                for i in 0..<count {
                    mono[i] += ch[i]
                }
            }
            let inv = 1.0 / Float(channelCount)
            for i in 0..<count { mono[i] *= inv }
            result = mono
        }

        var peak: Float = 0
        var sum: Double = 0
        for v in result {
            let a = v < 0 ? -v : v
            if a > peak { peak = a }
            sum += Double(v) * Double(v)
        }
        let rms = result.isEmpty ? 0 : (sum / Double(result.count)).squareRoot()
        Logger.shared.log("wav", "decoded " + logfmt([
            ("samples", result.count),
            ("peak", String(format: "%.5f", peak)),
            ("rms", String(format: "%.5f", rms)),
        ]))
        return result
    }
}
