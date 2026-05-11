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

        // Use the no-state variant so we can allocate a fresh whisper_state for
        // each transcription. Sharing one state across calls causes residual
        // KV-cache / detected-language to leak between runs (we observed the
        // second call returning English even with language="fr" explicitly set).
        guard let ctx = modelPath.withCString({ whisper_init_from_file_with_params_no_state($0, params) }) else {
            return nil
        }
        self.context = ctx
        self.modelSize = modelSize
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

        return try language.withCString { langPtr -> String in
            params.language = langPtr

            let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        throw TranscriberError.transcriptionFailed
                    }
                    defer { whisper_free_state(state) }

                    let result: Int32 = samples.withUnsafeBufferPointer { buf in
                        whisper_full_with_state(context, state, params, buf.baseAddress, Int32(buf.count))
                    }
                    if result != 0 {
                        throw TranscriberError.transcriptionFailed
                    }

                    let nSegments = whisper_full_n_segments_from_state(state)
                    var output = ""
                    for i in 0..<nSegments {
                        if let cstr = whisper_full_get_segment_text_from_state(state, i) {
                            output += String(cString: cstr)
                        }
                    }
                    return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "OpenWispr.WAVDecoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }
        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else {
            throw NSError(domain: "OpenWispr.WAVDecoder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PCM buffer missing float channel data"])
        }
        let count = Int(buffer.frameLength)

        // Recordings are written as 16kHz mono, but be defensive: average channels
        // if a buffer somehow arrives stereo, and verify sample rate.
        let channelCount = Int(processingFormat.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: count))
        }

        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let ch = channels[c]
            for i in 0..<count {
                mono[i] += ch[i]
            }
        }
        let inv = 1.0 / Float(channelCount)
        for i in 0..<count { mono[i] *= inv }
        return mono
    }
}
