@preconcurrency import AVFAudio
import Foundation

@available(macOS 26.0, *)
final class AppleSpeechAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * ratio) + 32
        let capacity = AVAudioFrameCount(max(1, estimatedFrames))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw VoiceTranscriptionError.audioInputUnavailable
        }
        let inputBox = ConverterInputBox(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputBox.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputBox.wasSupplied = true
            inputStatus.pointee = .haveData
            return inputBox.buffer
        }
        if status == .error {
            throw VoiceTranscriptionError.recognitionFailed(
                conversionError?.localizedDescription ?? "マイク音声の形式を変換できませんでした"
            )
        }
        return output
    }
}

@available(macOS 26.0, *)
private final class ConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
